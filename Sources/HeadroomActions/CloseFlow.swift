// CloseFlow — the UI-independent decisions and texts around a close (SPEC §6.3, §7.2, §7.3):
//   decide()        undo-first: execute at once, or show the sheet (always under ⌥ for busy/leftover/unregistered)
//   SheetModel      the confirm sheet's title, grouped items, background checkbox and buttons
//   ToastModel      "✓ Closed 2 tabs, 3 sessions · freeing…  Undo ⌘Z" plus the extra lines
//   SelectionSummary the footer ("5 selected — 2 tabs, 3 sessions · 1 needs a look (audible) · frees ≈3.4 GB")
// The App renders these; the CLI uses decide() and the sheet text for its y/N prompt.

import Foundation
import HeadroomContracts

public enum CloseDecision: Sendable, Equatable {
    /// Nothing closable; the message explains why.
    case nothing(String)
    /// No confirm reason (or ⌥ and nothing mandatory): close at once, then show the Undo toast.
    case execute
    /// Show the sheet. `mandatoryNote` is set when ⌥ was held but the sheet is mandatory.
    case sheet(mandatoryNote: String?)
}

public enum CloseFlow {
    /// `skipSheet` = ⌥ (Close Now).
    public static func decide(_ plan: ClosePlan, skipSheet: Bool) -> CloseDecision {
        if plan.isEmpty {
            let n = plan.locked.count
            return .nothing(n == 0 ? "Nothing selected" : "\(Fmt.plural(n, "selected row")) can't be closed")
        }
        if skipSheet {
            if plan.sheetMandatory {
                return .sheet(mandatoryNote: "Busy sessions, leftovers and unregistered claude processes always ask first.")
            }
            return .execute
        }
        return plan.needsSheet ? .sheet(mandatoryNote: nil) : .execute
    }

    /// "2 tabs, 3 sessions, 1 leftover"
    public static func countText(_ ids: [ItemID]) -> String {
        let tabs = ids.filter { $0.kind == .tab }.count
        let sessions = ids.filter { $0.kind == .session }.count
        let leftovers = ids.filter { $0.kind == .leftover }.count
        let other = ids.count - tabs - sessions - leftovers
        var parts: [String] = []
        if tabs > 0 { parts.append(Fmt.plural(tabs, "tab")) }
        if sessions > 0 { parts.append(Fmt.plural(sessions, "session")) }
        if leftovers > 0 { parts.append(Fmt.plural(leftovers, "leftover")) }
        if other > 0 { parts.append(Fmt.plural(other, "item")) }
        return parts.joined(separator: ", ")
    }

    /// Context-only notes (§7.3): shown in the sheet and Peek, never a reason on their own.
    public static func context(_ id: ItemID, _ w: WorldSnapshot) -> [String] {
        switch id {
        case .session(let k):
            guard let s = w.claude.sessions.first(where: { $0.key == k }) else { return [] }
            var out: [String] = []
            if s.remoteControl { out.append("Remote Control is on") }
            if let b = s.branch, b != "main" && b != "master" { out.append("branch \(b)") }
            return out
        case let .chromeTab(b, t):
            guard let tab = w.chrome.tab(TabRef(browserPid: b, tabId: t)) else { return [] }
            return tab.incognito ? ["incognito (may not be restorable)"] : []
        default: return []
        }
    }
}

// MARK: - Sheet

public struct SheetLine: Sendable, Hashable {
    public let id: ItemID
    public let title: String
    public let bytes: Bytes
    public let reasons: [String]
    public let context: [String]
    public let busy: Bool
    /// A tab whose memory is unknown: show "—", not "0 MB".
    public var unknownBytes: Bool = false
    /// "412 MB", or "—" when unknown.
    public var bytesText: String { unknownBytes ? "—" : ByteFormat.short(bytes) }
}

public struct SheetGroup: Sendable, Hashable {
    public let heading: String
    public let lines: [SheetLine]
}

public struct SheetModel: Sendable {
    public enum Button: Sendable, Hashable {
        case cancel
        /// Closes everything, busy sessions included.
        case closeAll(Int)
        /// Default when busy sessions are present.
        case skipBusy(Int)
        case close(Int)
        public var title: String {
            switch self {
            case .cancel: "Cancel"
            case .closeAll(let n): "Close All \(n)"
            case .skipBusy(let n): "Skip Busy — Close \(n)"
            case .close(let n): "Close \(n)"
            }
        }
    }

    public let title: String
    public let groups: [SheetGroup]
    public let backgroundUnits: [LinkedUnit]
    public let checkboxText: String?
    public let buttons: [Button]
    /// The Return-key button.
    public let defaultButton: Button
    public let lockedNote: String?
    public let mandatoryNote: String?
    public let footnote: String?

    public init(plan p: ClosePlan, mandatoryNote: String? = nil, dryRun: Bool = false) {
        let w = p.world
        let busyN = PlanMath.busyCount(p)
        let n = p.items.count
        let all = PlanMath.estimate(p.items, w, stopBackground: p.stopBackground)
        let unknown = PlanMath.unknownTabs(p.items, w)
        title = "Close \(Fmt.plural(n, "item")) and free \(PlanMath.estimateText(all, unknown: unknown, approx: "about "))?"
        var groups: [SheetGroup] = []
        let order: [(ItemKind, String)] = [(.session, "Claude sessions"), (.tab, "Chrome tabs"), (.leftover, "Leftovers")]
        for (kind, heading) in order {
            let lines = p.items.filter { $0.id.kind == kind }.map { i in
                var l = SheetLine(id: i.id, title: i.title, bytes: i.bytes,
                                  reasons: i.protection.reasons.map(\.text), context: CloseFlow.context(i.id, w),
                                  busy: PlanMath.isBusy(i))
                l.unknownBytes = PlanMath.unknownTabs([i], w) > 0
                return l
            }
            if !lines.isEmpty { groups.append(SheetGroup(heading: heading, lines: lines)) }
        }
        self.groups = groups
        let units = p.items.flatMap { i -> [LinkedUnit] in
            guard case .session(let k) = i.id else { return [] }
            return w.claude.sessions.first { $0.key == k }?.background ?? []
        }
        backgroundUnits = units
        if units.isEmpty {
            checkboxText = nil
        } else {
            let bytes = units.reduce(0) { $0 + $1.footprint }
            let what = units.count == 1 ? "(\(units[0].command), \(ByteFormat.short(bytes)))" : "(\(ByteFormat.short(bytes)))"
            checkboxText = "Also stop \(Fmt.plural(units.count, "background process", "background processes")) \(units.count == 1 ? "it" : "they") started \(what)"
        }
        if busyN > 0 {
            let skip = Button.skipBusy(n - busyN)
            buttons = n - busyN > 0 ? [.cancel, .closeAll(n), skip] : [.cancel, .closeAll(n)]
            defaultButton = n - busyN > 0 ? skip : .cancel
        } else {
            buttons = [.cancel, .close(n)]
            defaultButton = .close(n)
        }
        lockedNote = p.locked.isEmpty ? nil : "\(Fmt.plural(p.locked.count, "selected row")) can't be closed and will be skipped."
        self.mandatoryNote = mandatoryNote
        var foot: [String] = []
        if p.items.contains(where: { $0.id.kind == .leftover }) { foot.append("Leftovers cannot be undone.") }
        if p.items.contains(where: { $0.id.kind == .session }) {
            foot.append("Undo reopens sessions with claude --resume; an unsent draft in the prompt box is lost.")
        }
        if dryRun { foot.append("Dry run: nothing will actually be closed.") }
        footnote = foot.isEmpty ? nil : foot.joined(separator: " ")
    }

    /// Applies a button to the plan (skipBusy / stopBackground). nil = cancel.
    public static func apply(_ b: Button, to plan: ClosePlan, stopBackground: Bool) -> ClosePlan? {
        var p = plan
        p.stopBackground = stopBackground
        switch b {
        case .cancel: return nil
        case .closeAll: p.skipBusy = false
        case .skipBusy, .close: p.skipBusy = true
        }
        return p
    }
}

// MARK: - Toast

public struct ToastLine: Sendable, Hashable {
    public enum Action: Sendable, Hashable { case jump(ItemID), forceQuit([ItemID]) }
    public let text: String
    public let action: Action?
    public init(text: String, action: Action? = nil) { self.text = text; self.action = action }
    public var actionTitle: String? {
        switch action { case .jump: "Jump"; case .forceQuit: "Force Quit"; case nil: nil }
    }
}

public struct ToastModel: Sendable {
    public var headline: String
    public var lines: [ToastLine]
    public var undoable: Bool
    /// Section total before the close (for "X freed (measured)").
    public var baseline: Bytes

    public init(headline: String, lines: [ToastLine] = [], undoable: Bool = false, baseline: Bytes = 0) {
        self.headline = headline; self.lines = lines; self.undoable = undoable; self.baseline = baseline
    }

    public init(records: [ClosedRecord], outcomes: [ItemID: Outcome], needsForce: [ItemID], dryRun: Bool,
                baseline: Bytes) {
        let closedIDs = records.compactMap { ItemID(string: $0.itemId) }
        let what = CloseFlow.countText(closedIDs)
        if closedIDs.isEmpty {
            headline = "Nothing was closed"
        } else if dryRun {
            headline = "✓ Dry run: would close \(what)"
        } else {
            headline = "✓ Closed \(what) · freeing…"
        }
        var lines: [ToastLine] = []
        let changed = outcomes.filter { $0.value == .changedSkipped }.map(\.key)
        if !changed.isEmpty {
            let tabs = changed.filter { $0.kind == .tab }.count
            let noun = tabs == changed.count ? Fmt.plural(changed.count, "tab") : Fmt.plural(changed.count, "item")
            lines.append(ToastLine(text: "\(noun) changed since you selected \(changed.count == 1 ? "it" : "them") — skipped", action: nil))
        }
        for id in outcomes.filter({ $0.value == .stayedOpen }).map(\.key).sorted() {
            lines.append(ToastLine(text: "1 tab asked to stay open", action: .jump(id)))
        }
        let force = needsForce.sorted()
        if !force.isEmpty {
            let sessions = force.filter { $0.kind == .session }.count
            let text = sessions == force.count
                ? "\(Fmt.plural(sessions, "session")) didn't quit"
                : "\(Fmt.plural(force.count, "process group", "process groups")) didn't stop"
            lines.append(ToastLine(text: text, action: .forceQuit(force)))
        }
        let failed = outcomes.compactMap { k, v -> String? in if case .failed(let s) = v { "\(k.kind.rawValue): \(s)" } else { nil } }
        if !failed.isEmpty {
            lines.append(ToastLine(text: "\(Fmt.plural(failed.count, "item")) failed — \(failed.sorted().first!)", action: nil))
        }
        if closedIDs.contains(where: { $0.kind == .leftover }) {
            lines.append(ToastLine(text: "Leftovers stopped (not undoable)", action: nil))
        }
        if records.contains(where: { $0.kind == "tab" && $0.incognito == true }) {
            lines.append(ToastLine(text: "Incognito tabs may not be restorable", action: nil))
        }
        self.lines = lines
        undoable = records.contains(where: \.restorable)
        self.baseline = baseline
    }

    /// Replaces "freeing…" with the measured drop.
    public mutating func measured(_ freed: Bytes) {
        headline = headline.replacingOccurrences(of: "freeing…", with: "\(ByteFormat.short(freed)) freed (measured)")
    }
}

// MARK: - Footer

public enum SelectionSummary {
    /// Footer line for the current selection.
    public static func text(selected: [Row], plan: ClosePlan?) -> String {
        guard !selected.isEmpty else { return "" }
        var ids: [ItemID] = []
        var nonItems = 0
        for r in selected { if let i = r.item { ids.append(i) } else { nonItems += 1 } }
        var parts: [String] = []
        let counted = CloseFlow.countText(ids.filter { $0.kind != .process && $0.kind != .overhead && $0.kind != .window })
        let windows = ids.filter { $0.kind == .window }.count
        var head = "\(selected.count) selected"
        var kinds: [String] = []
        if windows > 0 { kinds.append(Fmt.plural(windows, "window")) }
        if !counted.isEmpty { kinds.append(counted) }
        if !kinds.isEmpty { head += " — " + kinds.joined(separator: ", ") }
        parts.append(head)
        if let p = plan {
            let confirm = p.items.filter { !$0.protection.reasons.isEmpty }
            if !confirm.isEmpty {
                // Name the most important reason in the selection.
                let priority = ["busy", "leftover", "unregistered", "audible", "visiblePane", "recentActivity",
                                "hasBackground", "notInTmux", "noTranscript", "cwdMissing", "pinned", "emptiesWindow",
                                "closesAllWindows", "manyItems"]
                let all = confirm.flatMap(\.protection.reasons)
                let first = all.min { (priority.firstIndex(of: $0.code) ?? 99) < (priority.firstIndex(of: $1.code) ?? 99) }!
                let short: String
                switch first {
                case .busy: short = "busy"
                case .audible: short = "audible"
                case .pinned: short = "pinned"
                case .leftover: short = "leftover"
                case .visiblePane: short = "visible pane"
                case .recentActivity: short = "recently active"
                case .notInTmux: short = "not in tmux or Rex"
                case .hasBackground: short = "has background"
                default: short = first.code
                }
                parts.append("\(confirm.count) need\(confirm.count == 1 ? "s" : "") a look (\(short))")
            }
            let lockedCount = p.locked.count
            if lockedCount > 0 || nonItems > 0 {
                let n = lockedCount + nonItems
                parts.append("\(Fmt.plural(n, "row")) can't be closed")
            }
            if !p.items.isEmpty {
                parts.append("frees " + PlanMath.estimateText(p.estimate, unknown: PlanMath.unknownTabs(p.items, p.world)))
            }
        }
        return parts.joined(separator: " · ")
    }
}
