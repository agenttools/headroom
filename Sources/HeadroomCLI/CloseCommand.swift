// `headroom close <ids…> [--dry-run] [--yes] [--force-confirm [--include-busy]] [--keep-background] [--json]`
//
// Same Planner + CloseCoordinator + Signaller as the app (through ActionExecutor), so every §7.4 safety
// check applies. The CLI is all-or-nothing: if any id is locked, unknown, or needs confirmation without
// --force-confirm, nothing is closed and the exit code is 2.
//
//   locked (Chrome itself, launcher, changed pid, child process, unknown id) → always refused
//   confirm (anything the app's sheet would ask about)                       → refused without --force-confirm
//   --force-confirm                                                          → like the sheet's "Skip Busy":
//        busy sessions are never closed by it; a plan with a busy session is refused (exit 2) unless
//        --include-busy is also given (the sheet's "Close All"). `suggest` never prints --include-busy.
//   no --yes: TTY → y/N prompt; not a TTY → print the plan, exit 2
//   after the y/N prompt the plan is made again from a fresh snapshot; anything newly locked, gone or with a
//   new confirm reason (e.g. the session became busy while the prompt waited) → nothing closed, exit 2
//   --dry-run → full pipeline, nothing closed or signalled, no prompt
//   HEADROOM_DRY_RUN=1 → nothing closed or signalled, but the same prompts and refusals as a real close

import Foundation
import HeadroomContracts
import HeadroomActions

// MARK: JSON (docs/cli.md "close --json")

struct PlanItemJSON: Codable, Sendable {
    let id: ItemID
    let kind: String
    let title: String
    let bytes: Bytes
    /// "none" | "confirm"
    let protection: String
    let reasons: [ReasonJSON]
}

/// Same shape as ReasonJSON ({code, text}).
struct CodeText: Codable, Sendable {
    let code: String
    let text: String
}

struct LockedJSON: Codable, Sendable {
    let id: String
    let reason: CodeText
    /// false when the id is not in the current snapshot at all (already closed, or a stale id).
    let found: Bool
}

struct PlanJSON: Codable, Sendable {
    let items: [PlanItemJSON]
    let locked: [LockedJSON]
    let estimateBytes: Bytes
    /// Tabs whose memory is unknown (not in estimateBytes, which is then a lower bound). Additive.
    var estimateUnknownTabs: Int = 0
    let stopBackground: Bool
    let backgroundCommands: [String]
}

struct ItemResultJSON: Codable, Sendable {
    let id: ItemID
    /// Outcome name: done | alreadyGone | changedSkipped | stayedOpen | stillAlive | dryRun | failed: <why>
    let outcome: String
}

struct CloseResultJSON: Codable, Sendable {
    let schema: Int
    let command: String
    /// "closed" | "partial" | "refused" | "needsConfirmation" | "cancelled"
    let status: String
    let dryRun: Bool
    let mock: Bool
    let message: String?
    let plan: PlanJSON
    let results: [ItemResultJSON]
    /// Sessions or process groups that did not exit (the app offers Force Quit).
    let needsForce: [ItemID]
    /// What went into Recently Closed (`headroom undo <id>`). Empty in dry run.
    let records: [ClosedRecord]
}

enum CloseCommand {
    static func run(_ a: ParsedArgs, _ ctx: HeadroomContext, _ io: CLIIO) async -> Int32 {
        let json = a.has("json")
        guard !a.positionals.isEmpty else {
            io.err("headroom close: give at least one id (see `headroom list` or `headroom suggest`)")
            return Exit.error
        }
        var ids: [ItemID] = []
        for s in a.positionals {
            guard let id = ItemID(string: s) else {
                io.err("headroom close: not a Headroom id: \(s)  (formats: tab:<pid>:<tabId>, window:<pid>:<windowId>, session:<pid>:<start>, leftover:<pgid>:<start>)")
                return Exit.error
            }
            ids.append(id)
        }
        let env = ctx.env
        let world = await ctx.world.snapshot()
        var plan = ctx.executor.plan(Set(ids), world)
        plan.stopBackground = !a.has("keep-background")
        let force = a.has("force-confirm")
        let includeBusy = a.has("include-busy")
        // --force-confirm answers the sheet with "Skip Busy"; only --include-busy means "Close All".
        plan.skipBusy = !(force && includeBusy)

        let known = knownIDs(world)
        var pj = planJSON(plan, known: known)
        func finish(_ status: String, _ message: String?, _ code: Int32, results: [ItemResultJSON] = [],
                    needsForce: [ItemID] = [], records: [ClosedRecord] = []) -> Int32 {
            if json {
                let r = CloseResultJSON(schema: ListSnapshot.currentSchema, command: "close", status: status,
                                        dryRun: env.dryRun, mock: ctx.isMock, message: message, plan: pj,
                                        results: results, needsForce: needsForce, records: records)
                let c = JSONOut.write(r, io)
                return c == Exit.ok ? code : c
            }
            if let message { if code == Exit.ok { io.out(message) } else { io.err(message) } }
            return code
        }

        // 1. Locked: always refused.
        if !plan.locked.isEmpty {
            if !json {
                io.err("Refused: \(Text.plural(plan.locked.count, "item")) can't be closed:")
                for l in pj.locked { io.err("  \(Text.col(l.id, 30)) \(l.reason.text)") }
                io.err("Nothing was closed. Remove these ids (run `headroom list` for current ids) and try again.")
            }
            return finish("refused", json ? "\(Text.plural(plan.locked.count, "item")) can't be closed; nothing was closed" : nil,
                          Exit.refused)
        }
        if plan.isEmpty { return finish("refused", "Nothing to close.", Exit.refused) }

        // 2. Confirm-needing items: refused without --force-confirm.
        if plan.needsSheet && !force {
            let n = plan.items.filter { !$0.protection.reasons.isEmpty }.count
            if !json {
                printPlan(plan, env: env, io: io, toErr: true)
                io.err("")
                io.err("Refused: \(Text.plural(n, "item")) need\(n == 1 ? "s" : "") confirmation (the app would ask first). Nothing was closed.")
                io.err("Check the reasons above, then re-run with --force-confirm.")
            }
            return finish("needsConfirmation",
                          json ? "\(Text.plural(n, "item")) need confirmation; re-run with --force-confirm" : nil,
                          Exit.refused)
        }

        // 2b. Busy sessions: --force-confirm never closes one mid-turn; that needs --include-busy as well.
        let busy = plan.items.filter(PlanMath.isBusy)
        if force && !includeBusy && !busy.isEmpty {
            if !json {
                io.err("Refused: \(Text.plural(busy.count, "session")) \(busy.count == 1 ? "is" : "are") busy (mid-turn): "
                       + busy.map(\.id.stringValue).joined(separator: " "))
                io.err("Nothing was closed. Wait until \(busy.count == 1 ? "it is" : "they are") idle, or add --include-busy to close \(busy.count == 1 ? "it" : "them") anyway.")
            }
            return finish("needsConfirmation",
                          json ? "\(Text.plural(busy.count, "session")) busy; nothing was closed (add --include-busy to close busy sessions)" : nil,
                          Exit.refused)
        }

        // 3. Ask (unless --yes or dry run).
        if !json { printPlan(plan, env: env, io: io, toErr: false) }
        // HEADROOM_DRY_RUN=1 keeps the same interaction as a real close (as the app's sheet does);
        // only an explicit --dry-run preview skips the question.
        if !a.has("dry-run") && !a.has("yes") {
            if io.stdinIsTTY && !json {
                io.prompt("Close \(Text.plural(plan.items.count, "item")) and free \(PlanMath.effectiveEstimateText(plan, approx: "about "))? [y/N] ")
                let answer = io.readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                guard answer == "y" || answer == "yes" else {
                    return finish("cancelled", "Cancelled. Nothing was closed.", Exit.refused)
                }
                // The prompt may have waited a long time: plan again from a fresh snapshot, and refuse if
                // anything changed that the user did not see (newly locked or gone, a new confirm reason).
                let world2 = await ctx.world.snapshot()
                var fresh = ctx.executor.plan(Set(ids), world2)
                fresh.stopBackground = plan.stopBackground
                fresh.skipBusy = plan.skipBusy
                let changes = Self.changes(from: plan, to: fresh)
                if !changes.isEmpty {
                    io.err("Refused: things changed while waiting for your answer. Nothing was closed:")
                    for c in changes { io.err("  " + c) }
                    return finish("needsConfirmation", nil, Exit.refused)
                }
                plan = fresh
                pj = planJSON(plan, known: knownIDs(world2))
            } else {
                return finish("needsConfirmation",
                              "Not a terminal and no --yes: nothing was closed. Re-run with --yes to close.",
                              Exit.refused)
            }
        }

        // 4. Execute through the shared CloseCoordinator.
        var outcomes: [ItemID: Outcome] = [:]
        var needsForce: [ItemID] = []
        var records: [ClosedRecord] = []
        for await e in ctx.executor.execute(plan) {
            switch e {
            case let .progress(id, o): outcomes[id] = o
            case let .needsForce(ids): needsForce += ids
            case let .finished(r): records = r
            }
        }
        let planIDs = Set(plan.items.map(\.id))
        // Plus anything else the coordinator reported, e.g. a background process it could not stop.
        let extra = outcomes.keys.filter { !planIDs.contains($0) }.sorted()
        let results = plan.items.map { ItemResultJSON(id: $0.id, outcome: outcomes[$0.id]?.name ?? "skipped") }
            + extra.map { ItemResultJSON(id: $0, outcome: outcomes[$0]!.name) }
        let allOK = plan.items.allSatisfy { outcomes[$0.id]?.isClosed == true } && needsForce.isEmpty
        let status = allOK ? "closed" : "partial"
        if !json {
            let toast = ToastModel(records: records, outcomes: outcomes, needsForce: needsForce,
                                   dryRun: env.dryRun, baseline: 0)
            io.out("")
            io.out(toast.headline.replacingOccurrences(of: " · freeing…", with: ""))
            for i in plan.items {
                let o = outcomes[i.id]
                let mark = o?.isClosed == true ? "✓" : "✗"
                io.out("  \(mark) \(Text.col(i.id.stringValue, 30)) \(Text.col(o?.name ?? "skipped", 14)) \(Text.trunc(i.title, 50))")
            }
            for id in extra { io.out("  ! \(Text.col(id.stringValue, 30)) \(outcomes[id]!.name)") }
            for l in toast.lines { io.out("  " + l.text) }
            if !needsForce.isEmpty {
                io.out("  Still running: \(needsForce.map(\.stringValue).joined(separator: " ")) (use Force Quit in the app, or check them with `headroom list`)")
            }
            if ctx.isMock {
                io.out("Mock: nothing was closed or signalled.")
            } else if env.dryRun {
                io.out("Dry run: nothing was closed or signalled (logged to actions.jsonl as dryRun).")
            } else if toast.undoable {
                io.out("Undo: headroom undo --last")
            }
        }
        return finish(status, nil, allOK ? Exit.ok : Exit.error, results: results, needsForce: needsForce,
                      records: env.dryRun ? [] : records)
    }

    /// The sheet as text (SheetModel), on stdout or stderr.
    static func printPlan(_ p: ClosePlan, env: HeadroomEnv, io: CLIIO, toErr: Bool) {
        let say: (String) -> Void = { toErr ? io.err($0) : io.out($0) }
        let sheet = SheetModel(plan: p, dryRun: env.dryRun)
        say(sheet.title)
        for g in sheet.groups {
            say("  \(g.heading)")
            for l in g.lines {
                say("    \(Text.col(l.id.stringValue, 30)) \(Text.rcol(l.bytesText, 8))  \(Text.trunc(l.title, 60))")
                for r in l.reasons { say("        ! \(r)") }
                for c in l.context { say("        · \(c)") }
            }
        }
        if let cb = sheet.checkboxText {
            say("  [\(p.stopBackground ? "x" : " ")] \(cb)\(p.stopBackground ? "" : " (--keep-background)")")
            for u in sheet.backgroundUnits {
                say("        pgid \(u.pgid): \(Text.trunc(u.command, 60)) (\(ByteFormat.short(u.footprint)))")
            }
        }
        if let n = sheet.lockedNote { say("  " + n) }
        if let f = sheet.footnote { say("  " + f) }
    }

    /// What differs between the plan the user answered and a fresh one: ids now locked or gone, and confirm
    /// reasons that were not shown. Empty = safe to run the fresh plan.
    static func changes(from old: ClosePlan, to new: ClosePlan) -> [String] {
        var out: [String] = []
        let oldLocked = Set(old.locked.map(\.id))
        for l in new.locked where !oldLocked.contains(l.id) {
            out.append("\(l.id.stringValue): \(l.reason.text)")
        }
        let oldItems = Dictionary(old.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in new.items {
            let seen = Set(oldItems[i.id]?.protection.reasons.map(\.code) ?? [])
            let added = i.protection.reasons.filter { !seen.contains($0.code) }
            if !added.isEmpty { out.append("\(i.id.stringValue): now \(added.map(\.text).joined(separator: "; "))") }
        }
        return out
    }

    static func knownIDs(_ w: WorldSnapshot) -> Set<ItemID> {
        var s = Set(w.chrome.tabs.map(\.itemID) + w.chrome.windows.map(\.itemID) + w.claude.sessions.map(\.itemID)
                    + w.claude.leftovers.map(\.id))
        for x in w.claude.sessions { for u in x.children + x.background { s.insert(u.itemID) } }
        for b in Set(w.chrome.tabs.map(\.browserPid) + w.ownership.mainBrowsers.map(\.key.pid)) {
            for k in ChromeOverheadKind.allCases { s.insert(.chromeOverhead(browserPid: b, kind: k.rawValue)) }
        }
        return s
    }

    static func planJSON(_ p: ClosePlan, known: Set<ItemID>) -> PlanJSON {
        var j = PlanJSON(
            items: p.items.map {
                PlanItemJSON(id: $0.id, kind: $0.id.kind.rawValue, title: $0.title, bytes: $0.bytes,
                             protection: $0.protection.level, reasons: $0.protection.reasons.map(ReasonJSON.init))
            },
            locked: p.locked.map { l in
                let found = known.contains(l.id)
                return LockedJSON(id: l.id.stringValue,
                                  reason: CodeText(code: found ? l.reason.code : "notFound",
                                                   text: found ? l.reason.text : "not found (already closed, or a stale id)"),
                                  found: found)
            },
            estimateBytes: PlanMath.effectiveEstimate(p), stopBackground: p.stopBackground,
            backgroundCommands: p.stopBackground ? PlanMath.backgroundUnits(p).map(\.command) : [])
        j.estimateUnknownTabs = PlanMath.effectiveUnknown(p)
        return j
    }
}
