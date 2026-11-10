// `headroom suggest` rules engine (docs/DECISIONS.md "CLI"). Pure: no I/O.
//
// All tunable numbers live in SuggestTuning. The rules only pick candidates; the Planner (the same one the
// app and `headroom close` use) has the last word on protection, so a "safe" suggestion is always something
// `headroom close` accepts without --force-confirm.
//
//   sessions   idle > 2 h, not busy (or status unknown), not the visible/current pane, no background
//              processes → "safe". If the Planner still wants confirmation (not in tmux, no transcript,
//              cwd missing, unregistered) → "confirm" with that reason.
//   leftovers  always "confirm" (safe to stop, but they cannot be undone, so they always ask).
//   tabs       not active, not audible, not pinned, not incognito, not already asleep, and either heavy
//              (≥ 300 MB) or unused for more than 1 h → "safe".
//   locked     never suggested.
//   batch      the "safe" set is re-planned as one close; anything the plan flags (a window of more than
//              5 tabs emptied, every window closed) becomes "confirm". At most 15 items stay "safe"
//              (the Planner asks above 15); the rest become "confirm" with a note to run a second batch.

import Foundation
import HeadroomContracts

public enum SuggestTuning {
    /// A session must be idle longer than this to be suggested.
    public static let sessionIdle: TimeInterval = 2 * 3600
    /// A tab at or above this fair-share footprint counts as heavy.
    public static let tabHeavy: Bytes = .mb(300)
    /// A tab not accessed for longer than this counts as unused.
    public static let tabUnused: TimeInterval = 3600
    /// Most "safe" items in one suggested close (the Planner adds `manyItems` above 15).
    public static let maxSafeBatch = 15
    /// `--ask` timeout for `claude -p`.
    public static let askTimeout: TimeInterval = 90
}

struct SuggestRules {
    var sessionIdle = SuggestTuning.sessionIdle
    var tabHeavy = SuggestTuning.tabHeavy
    var tabUnused = SuggestTuning.tabUnused
    var maxSafeBatch = SuggestTuning.maxSafeBatch

    typealias PlanFn = (Set<ItemID>, WorldSnapshot) -> ClosePlan

    /// Ranked suggestions: "safe" first, then "confirm", each by bytes descending.
    /// `minBytes` > 0 drops smaller candidates, and candidates whose size is unknown.
    func suggest(_ w: WorldSnapshot, protections: [ItemID: Protection], plan: PlanFn,
                 minBytes: Bytes = 0, now: Date = Date()) -> [Suggestion] {
        var out: [Suggestion] = []
        out += sessions(w, protections, now: now)
        out += leftovers(w, protections, now: now)
        out += tabs(w, protections, now: now)
        if minBytes > 0 {
            let unknown = Set(w.chrome.tabs.filter { $0.display == nil }.map(\.itemID))
            out = out.filter { $0.bytes >= minBytes && !unknown.contains($0.id) }
        }
        return Self.enforceBatch(out, w, plan: plan, maxSafe: maxSafeBatch)
    }

    // MARK: Sessions

    func sessions(_ w: WorldSnapshot, _ prot: [ItemID: Protection], now: Date) -> [Suggestion] {
        w.claude.sessions.compactMap { s in
            let p = prot[s.itemID] ?? .none
            if p.isLocked || s.isLauncher { return nil }
            if s.busy || p.reasons.contains(where: Self.isBusy) { return nil }
            guard let since = s.idleSince else { return nil }
            let idle = now.timeIntervalSince(since)
            guard idle > sessionIdle else { return nil }
            if let t = s.tmux, t.visible || t.current { return nil }
            guard s.background.isEmpty else { return nil }

            var why = ["idle \(Self.age(idle))", "not busy"]
            why.append(s.tmux != nil ? "not on screen" : "not in tmux")
            why.append("no background processes")
            if s.remoteControl { why.append("Remote Control is on") }
            let confirm = p.reasons
            if !confirm.isEmpty {
                return Suggestion(id: s.itemID, verdict: .confirm,
                                  reason: why.joined(separator: ", ") + "; asks first: "
                                      + confirm.map(\.text).joined(separator: "; "),
                                  bytes: s.total, title: s.title)
            }
            return Suggestion(id: s.itemID, verdict: .safe,
                              reason: why.joined(separator: ", ") + "; Undo resumes it in tmux",
                              bytes: s.total, title: s.title)
        }
    }

    // MARK: Leftovers

    func leftovers(_ w: WorldSnapshot, _ prot: [ItemID: Protection], now: Date) -> [Suggestion] {
        w.claude.leftovers.compactMap { l in
            let p = prot[l.id] ?? .confirm([.leftover])
            if p.isLocked { return nil }
            var from = "its Claude session (pid \(l.deadClaudePid)"
            if let t = l.sessionTitle { from += ", “\(t)”" }
            from += ") has ended"
            let age = Self.age(now.timeIntervalSince(l.startedAt))
            return Suggestion(id: l.id, verdict: .confirm,
                              reason: "leftover `\(l.unit.command)` running \(age); \(from); safe to stop, but it cannot be undone",
                              bytes: l.unit.footprint, title: l.sessionTitle ?? l.unit.command)
        }
    }

    /// Kinds the rules could not evaluate. The tab rule needs per-tab memory or a last-used time; the
    /// AppleScript list (always the case while the app holds the helper connection) has neither.
    static func skipped(_ w: WorldSnapshot) -> [SuggestSkip] {
        let src = w.chrome.source.name
        let evaluable = w.chrome.tabs.filter { !$0.discarded }.contains { $0.display != nil || $0.lastAccessed != nil }
        switch w.chrome.source {
        case .notRunning: return []
        case .processesOnly, .waiting:
            return [SuggestSkip(kind: "tab", reason: "no tab list (Chrome source: \(src)); set up the helper extension or allow Chrome control")]
        default:
            guard !w.chrome.tabs.isEmpty, !evaluable else { return [] }
            return [SuggestSkip(kind: "tab", reason: "per-tab memory and last-used times need the helper extension (Chrome source: \(src): the helper is not connected to the CLI, because it is not set up or because the running app holds the connection)")]
        }
    }

    // MARK: Tabs

    func tabs(_ w: WorldSnapshot, _ prot: [ItemID: Protection], now: Date) -> [Suggestion] {
        w.chrome.tabs.compactMap { t in
            let p = prot[t.itemID] ?? .none
            if p.isLocked || t.active || t.audible || t.pinned || t.incognito || t.discarded { return nil }
            let heavy = (t.display ?? 0) >= tabHeavy
            let unusedFor = t.lastAccessed.map { now.timeIntervalSince($0) }
            let unused = (unusedFor ?? 0) > tabUnused
            guard heavy || unused else { return nil }
            var why: [String] = []
            if let b = t.display { why.append(heavy ? "heavy (\(ByteFormat.short(b)))" : ByteFormat.short(b)) }
            else { why.append("memory unknown (per-tab memory needs the helper extension)") }
            if let u = unusedFor { why.append("last used \(Self.age(u)) ago") }
            why.append("not active, pinned or playing audio")
            if t.sharedWith > 0 {
                why.append("shares a renderer with \(Text.plural(t.sharedWith, "other tab")), so closing it alone frees less")
            }
            let confirm = p.reasons
            if !confirm.isEmpty {
                return Suggestion(id: t.itemID, verdict: .confirm,
                                  reason: why.joined(separator: ", ") + "; asks first: " + confirm.map(\.text).joined(separator: "; "),
                                  bytes: t.display ?? 0, title: t.title)
            }
            return Suggestion(id: t.itemID, verdict: .safe,
                              reason: why.joined(separator: ", ") + "; Undo reopens it",
                              bytes: t.display ?? 0, title: t.title)
        }
    }

    // MARK: Batch check (shared with --ask validation)

    /// Caps the "safe" set at `maxSafe`, re-plans it as one close, and downgrades anything the plan says
    /// needs confirmation. Returns the list ranked safe → confirm → keep, bytes descending.
    static func enforceBatch(_ input: [Suggestion], _ w: WorldSnapshot, plan: PlanFn,
                             maxSafe: Int = SuggestTuning.maxSafeBatch) -> [Suggestion] {
        var list = rank(input)
        let safeIdx = list.indices.filter { list[$0].verdict == .safe }
        for i in safeIdx.dropFirst(maxSafe) {
            let s = list[i]
            list[i] = Suggestion(id: s.id, verdict: .confirm,
                                 reason: s.reason + "; over the \(maxSafe)-item batch: close the first batch, then run suggest again",
                                 bytes: s.bytes, title: s.title)
        }
        let safe = Set(list.filter { $0.verdict == .safe }.map(\.id))
        if !safe.isEmpty {
            let p = plan(safe, w)
            let extra = Dictionary(p.items.map { ($0.id, $0.protection.reasons) }, uniquingKeysWith: { a, _ in a })
            let locked = Set(p.locked.map(\.id))
            list = list.compactMap { s in
                guard s.verdict == .safe else { return s }
                if locked.contains(s.id) { return nil }
                guard let r = extra[s.id], !r.isEmpty else { return s }
                return Suggestion(id: s.id, verdict: .confirm,
                                  reason: s.reason + "; asks first: " + r.map(\.text).joined(separator: "; "),
                                  bytes: s.bytes, title: s.title)
            }
        }
        return rank(list)
    }

    static func rank(_ s: [Suggestion]) -> [Suggestion] {
        func order(_ v: Verdict) -> Int { switch v { case .safe: 0; case .confirm: 1; case .keep: 2 } }
        return s.sorted {
            (order($0.verdict), $1.bytes, $0.id.stringValue) < (order($1.verdict), $0.bytes, $1.id.stringValue)
        }
    }

    static func isBusy(_ r: Reason) -> Bool { if case .busy = r { true } else { false } }

    /// "45m", "6h", "30h", "3d"
    static func age(_ t: TimeInterval) -> String { Text.age(Int(max(0, t))) }
}
