// `headroom undo [--last | <id>] [--list] [--dry-run] [--json]`
//
// Restores from the Recently Closed store that the app and the CLI share (closed.jsonl, last 7 days):
// tabs reopen (sessions.restore, else by URL), sessions resume with `claude --resume` in a new tmux window or
// Rex tab, where they ran.
// Leftovers cannot be undone.
//
//   undo | undo --last     the newest close batch that still has something restorable
//   undo <id>              a record id (or a unique prefix of at least 6 characters), a batch id,
//                          or an item id such as session:41194:1790590080 (its newest record)
//   undo --list            show Recently Closed with record ids
//
// In dry run (HEADROOM_DRY_RUN=1) closes are kept in memory only, so a later `headroom undo` process
// has nothing to restore; that is expected.

import Foundation
import HeadroomContracts
import HeadroomActions

struct RecordResultJSON: Codable, Sendable {
    let recordId: String
    let itemId: String
    let kind: String
    let title: String
    /// done | dryRun | failed: <why> | notUndoable (leftovers) | …
    let outcome: String
    /// Leftovers: the command to restart it by hand (additive).
    var argv: [String]? = nil
}

struct UndoResultJSON: Codable, Sendable {
    let schema: Int
    let command: String
    /// "restored" | "partial" | "nothing"
    let status: String
    let dryRun: Bool
    let message: String?
    let results: [RecordResultJSON]
    /// Notes for the user (additive; omitted when there are none): a session resumed in a new Rex session that
    /// Rex.app could not be asked to show.
    var notes: [String]? = nil
}

struct RecentJSON: Codable, Sendable {
    let schema: Int
    let records: [ClosedRecord]
}

enum UndoCommand {
    static func run(_ a: ParsedArgs, _ ctx: HeadroomContext, _ io: CLIIO) async -> Int32 {
        let json = a.has("json")
        let recent = await ctx.executor.recentlyClosed()
        let home = ctx.env.home

        if a.has("list") {
            if json { return JSONOut.write(RecentJSON(schema: ListSnapshot.currentSchema, records: recent), io) }
            if recent.isEmpty {
                io.out(ctx.env.dryRun ? "Recently Closed is empty (dry-run closes are not saved)." : "Recently Closed is empty.")
                return Exit.ok
            }
            let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
            io.out("\(Text.col("CLOSED", 10)) \(Text.col("RECORD", 10)) \(Text.col("KIND", 8)) \(Text.rcol("MEM", 8))  TITLE")
            for r in recent {
                let where_ = r.url ?? r.cwd.map { Text.tilde($0, home: home) } ?? ""
                let undo = r.restorable ? "" : "  (can't undo)"
                io.out("\(Text.col(f.string(from: r.closedAt), 10)) \(Text.col(String(r.id.prefix(8)), 10)) \(Text.col(r.kind, 8)) \(Text.rcol(ByteFormat.short(r.bytes), 8))  \(Text.trunc(r.title, 50))  \(Text.trunc(where_, 50))\(undo)")
            }
            return Exit.ok
        }

        guard a.positionals.count <= 1, !(a.has("last") && !a.positionals.isEmpty) else {
            io.err("headroom undo: give either --last or one id")
            return Exit.error
        }

        let picked: [ClosedRecord]
        do throws(CLIError) {
            picked = try select(a.positionals.first, from: recent)
        } catch {
            if json {
                _ = JSONOut.write(UndoResultJSON(schema: ListSnapshot.currentSchema, command: "undo", status: "nothing",
                                                 dryRun: ctx.env.dryRun, message: error.message, results: []), io)
            } else {
                io.err(error.message)
            }
            return error.code
        }

        let outcomes = await ctx.executor.undo(picked)
        // A batch can mix restorable items with leftovers (which never come back). The status and the exit
        // code are about the restorable ones; leftovers are reported as notUndoable with their command.
        let results = picked.map { r in
            r.restorable
                ? RecordResultJSON(recordId: r.id, itemId: r.itemId, kind: r.kind, title: r.title,
                                   outcome: outcomes[r]?.name ?? "skipped")
                : RecordResultJSON(recordId: r.id, itemId: r.itemId, kind: r.kind, title: r.title,
                                   outcome: "notUndoable", argv: r.argv)
        }
        let restorable = picked.filter(\.restorable)
        let ok = !restorable.isEmpty && restorable.allSatisfy { outcomes[$0] == .done || outcomes[$0] == .dryRun }
        let anyOK = restorable.contains { outcomes[$0] == .done || outcomes[$0] == .dryRun }
        // A new Rex session Rex.app could not be asked to show. Only a session this undo reopened (.done) can have
        // set the notes, so a run without one never prints an older note.
        let notes = restorable.contains { $0.kind == "session" && outcomes[$0] == .done }
            ? ((ctx.world as? LiveWorld)?.reopenNotes ?? []) : []
        if json {
            let r = UndoResultJSON(schema: ListSnapshot.currentSchema, command: "undo",
                                   status: ok ? "restored" : anyOK ? "partial" : "nothing",
                                   dryRun: ctx.env.dryRun, message: nil, results: results,
                                   notes: notes.isEmpty ? nil : notes)
            let c = JSONOut.write(r, io)
            return c == Exit.ok ? (ok ? Exit.ok : Exit.error) : c
        }
        let verb = ctx.env.dryRun ? "Dry run: would restore" : "Restored"
        let n = restorable.filter { outcomes[$0] == .done || outcomes[$0] == .dryRun }.count
        io.out("\(verb) \(n) of \(Text.plural(restorable.count, "item")):")
        for (r, res) in zip(picked, results) {
            guard r.restorable else {
                let cmd = r.argv.map { "; restart by hand: " + $0.joined(separator: " ") } ?? ""
                io.out("  – \(Text.col(r.kind, 8)) \(Text.col("not undoable", 30)) \(Text.trunc(r.title, 60))\(cmd)")
                continue
            }
            let mark = (outcomes[r] == .done || outcomes[r] == .dryRun) ? "✓" : "✗"
            io.out("  \(mark) \(Text.col(r.kind, 8)) \(Text.col(res.outcome, 30)) \(Text.trunc(r.title, 60))")
        }
        for n in notes { io.out(n) }
        if picked.contains(where: { $0.kind == "session" }) && !ctx.env.dryRun {
            io.out("Sessions reopen in a new tmux window or Rex tab with claude --resume (an unsent draft is lost).")
        }
        return ok ? Exit.ok : Exit.error
    }

    /// nil → the newest batch with something restorable.
    static func select(_ key: String?, from recent: [ClosedRecord]) throws(CLIError) -> [ClosedRecord] {
        guard let key else {
            guard let batch = recent.first(where: \.restorable)?.batchId else {
                throw CLIError(recent.isEmpty ? "Nothing to undo: Recently Closed is empty."
                                              : "Nothing to undo: the recent closes cannot be undone (leftovers).")
            }
            return recent.filter { $0.batchId == batch }
        }
        if let r = recent.first(where: { $0.id == key }) { return try restorable([r]) }
        let batch = recent.filter { $0.batchId == key }
        if !batch.isEmpty { return try restorable(batch) }
        if let id = ItemID(string: key) {
            guard let r = recent.first(where: { $0.itemId == id.stringValue }) else {
                throw CLIError("Nothing in Recently Closed for \(key).")
            }
            return try restorable([r])
        }
        if key.count >= 6 {
            let m = recent.filter { $0.id.lowercased().hasPrefix(key.lowercased()) }
            if m.count == 1 { return try restorable(m) }
            if m.count > 1 { throw CLIError("\(key) matches \(m.count) records; give more characters.") }
        }
        throw CLIError("No Recently Closed record \(key) (see `headroom undo --list`).")
    }

    private static func restorable(_ r: [ClosedRecord]) throws(CLIError) -> [ClosedRecord] {
        if r.contains(where: \.restorable) { return r }
        throw CLIError(r.allSatisfy { $0.kind == "leftover" }
                       ? "Leftovers cannot be undone. Restart it by hand: \(r.first?.argv?.joined(separator: " ") ?? "")"
                       : "That record cannot be restored.")
    }
}
