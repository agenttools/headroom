// Human output for `list` and `suggest` (compact tables). Agents should use --json instead.

import Foundation
import HeadroomContracts

enum ListTable {
    static func render(_ s: ListSnapshot, kind: ListKind, env: HeadroomEnv, io: CLIIO) {
        let sys = s.system
        var head = "Memory \(gb(sys.usedBytes)) of \(gb(sys.totalBytes)) used · pressure \(sys.pressure)"
        head += " · swap \(gb(sys.swapUsedBytes)) of \(gb(sys.swapTotalBytes))"
        head += " · Headroom \(ByteFormat.short(s.totals.headroomBytes))"
        if s.mock { head += " · MOCK" }
        if s.dryRun { head += " · DRY RUN" }
        io.out(head)

        let width = io.stdoutIsTTY ? io.columns : Int.max
        func section(_ kind: String, _ title: String, _ note: String?) {
            let rows = s.items.filter { $0.kind == kind }
            io.out("")
            io.out(title + (note.map { "  ·  " + $0 } ?? ""))
            if rows.isEmpty { io.out("  (none)"); return }
            io.out(fit("  " + Text.col("ID", 28) + " " + Text.rcol("MEM", 8) + " " + Text.rcol("IDLE", 5) + "  "
                       + Text.col("STATUS", 10) + " " + Text.col("PROTECT", 8) + " " + Text.col("TITLE", 42) + " WHERE",
                       width))
            for r in rows { io.out(fit(line(r, home: env.home), width)) }
        }
        let t = s.totals
        if kind.includes(.tab) {
            var note = "\(ByteFormat.short(t.chromeBytes)) in all, Chrome itself \(ByteFormat.short(t.chromeOverheadBytes))"
            note += " · source \(t.chromeSource)"
            if let why = t.chromePerTabUnavailable { note += " · " + why }
            if let why = t.chromeHelperNote { note += " · " + why }
            section("tab", "CHROME TABS", note)
        }
        if kind.includes(.session) {
            var note = ByteFormat.short(t.sessionsBytes)
            if t.staleSessionFiles > 0 { note += " · \(Text.plural(t.staleSessionFiles, "stale session file")) hidden" }
            section("session", "CLAUDE SESSIONS", note)
        }
        if kind.includes(.leftover) {
            section("leftover", "LEFTOVERS", ByteFormat.short(t.leftoversBytes) + " · their Claude session has ended")
        }
    }

    static func line(_ r: ListItem, home: String) -> String {
        let prot = r.protection == "none" ? "" : r.protection
        var whereText = ""
        switch r.kind {
        case "tab":
            whereText = r.incognito == true ? "incognito" : (r.url.flatMap { URL(string: $0)?.host } ?? r.url ?? "")
        case "session":
            // tmux "hub:3.1", Rex "rex foundry:2.1" (ListItem.tmux stays tmux-only), else "not in tmux or Rex".
            whereText = (r.tmux ?? r.rex.map { "rex " + $0 } ?? ClaudeSession.notPlacedLabel)
                + (r.cwd.map { "  " + Text.tilde($0, home: home) } ?? "")
        default:
            whereText = r.cwd.map { Text.tilde($0, home: home) } ?? ""
        }
        let codes = r.reasons.map(\.code)
        let why = codes.isEmpty ? "" : "  (" + codes.joined(separator: ", ") + ")"
        let title = r.kind == "leftover" && r.command != nil && r.command != r.title ? "\(r.command!) — \(r.title)" : r.title
        return "  " + Text.col(r.id, 28) + " " + Text.rcol(Text.bytes(r.bytes), 8) + " "
            + Text.rcol(Text.age(r.kind == "leftover" ? r.runningSeconds : r.idleSeconds), 5) + "  " + Text.col(r.status, 10) + " " + Text.col(prot, 8) + " "
            + Text.col(Text.oneLine(title), 42) + " " + whereText + why
    }

    static func fit(_ s: String, _ width: Int) -> String { s.count > width ? String(s.prefix(width - 1)) + "…" : s }

    static func gb(_ b: Bytes) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
}

enum SuggestText {
    static func render(_ r: SuggestReport, world: WorldSnapshot, header: String, warnings: [String], io: CLIIO,
                       prose: String? = nil, safeEstimate: Bytes? = nil) {
        let safe = r.suggestions.filter { $0.verdict == .safe }
        let confirm = r.suggestions.filter { $0.verdict == .confirm }
        let keep = r.suggestions.filter { $0.verdict == .keep }
        var head = header
        head += " · \(safe.count) safe"
        if !safe.isEmpty { head += " (≈\(ByteFormat.short(safeEstimate ?? r.safeBytes)))" }
        head += " · \(confirm.count) to confirm"
        if !keep.isEmpty { head += " · \(keep.count) keep" }
        if world.isMock { head += " · MOCK" }
        io.out(head)

        let skippedTabs = r.skipped?.contains { $0.kind == "tab" } ?? false
        for s in r.skipped ?? [] { io.out("Not checked: \(s.kind)s: \(s.reason)") }
        if r.suggestions.isEmpty {
            io.out("")
            io.out("Nothing to suggest: no sessions idle over \(Text.age(Int(SuggestTuning.sessionIdle)))"
                   + (skippedTabs ? "" : ", no heavy or unused tabs") + ", no leftovers.")
        }
        func group(_ title: String, _ items: [Suggestion]) {
            guard !items.isEmpty else { return }
            io.out("")
            io.out(title)
            for s in items {
                io.out("  \(Text.col(s.id.stringValue, 28)) \(Text.rcol(ByteFormat.short(s.bytes), 8))  \(Text.trunc(Text.oneLine(s.title ?? ""), 60))")
                io.out("      \(s.reason)")
            }
        }
        group("SAFE: Undo can bring these back", safe)
        group("CONFIRM: look first; closing needs --force-confirm", confirm)
        group("KEEP", keep)

        if let p = prose?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            io.out("")
            io.out("Claude's notes:")
            for l in p.split(separator: "\n", omittingEmptySubsequences: false) { io.out("  " + l) }
        }
        if !warnings.isEmpty {
            io.out("")
            io.out("Headroom checked Claude's answer against the snapshot:")
            for w in warnings { io.out("  - " + w) }
        }
        if let cmd = r.closeCommand {
            io.out("")
            io.out("Close the safe ones:")
            io.out("  " + cmd)
        }
        if let cmd = r.confirmCommand {
            io.out("")
            io.out(r.closeCommand == nil ? "After checking them:" : "Then, after checking:")
            io.out("  " + cmd)
        }
    }
}
