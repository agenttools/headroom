// Planner — SPEC §7.3 protection levels and §7.4 step 1 (plan). Pure: no I/O, no AppKit.
// Shared unchanged by the App and the CLI.
//
// Row protections (protections(_:)):
//   locked   Chrome itself + sub-rows, "Other Chrome instances", the session that launched Headroom,
//            rows that fail revalidation (pidMismatch), and every child/background process row.
//   confirm  sessions: busy / unknown status, active < 10 min, visible/current tmux pane or visible Rex pane
//            (a Rex pane whose place is unknown counts as visible), not in tmux or Rex,
//            has background, no transcript, cwd missing, unregistered;
//            tabs: audible, pinned;  leftovers: always.
// Selection-dependent reasons (plan(_:_:)):
//   emptiesWindow(n)   the selection closes every tab of a window with more than 5 tabs
//   closesAllWindows   the selection closes every normal (non-incognito) window of a browser
//   manyItems          more than 15 closable items

import Foundation
import HeadroomContracts

public struct Planner: Sendable {
    public var recentActivityWindow: TimeInterval = 10 * 60
    public var manyItemsThreshold = 15
    /// A window with more than this many tabs asks before the selection empties it.
    public var emptiesWindowThreshold = 5
    /// Pids that count as "the session that launched Headroom": env CLAUDE_PID and Headroom's own
    /// ancestors (so a claude that started Headroom from its terminal is locked).
    public var launcherPids: Set<Int32> = []
    /// Revalidation. Returns false when (pid, startSec) no longer matches a live process; such rows are
    /// locked(.pidMismatch). nil = trust the snapshot (mock, tests).
    public var isAlive: (@Sendable (ProcKey) -> Bool)?

    public init(launcherPids: Set<Int32> = [], isAlive: (@Sendable (ProcKey) -> Bool)? = nil) {
        self.launcherPids = launcherPids
        self.isAlive = isAlive
    }

    /// Reason used for child and background process rows (tool shells, MCP servers, dev servers a live
    /// session owns). Close the session instead.
    public static let childProcessReason: Reason = .childProcess

    // MARK: Row protections

    public func protections(_ w: WorldSnapshot, now: Date = Date()) -> [ItemID: Protection] {
        var out: [ItemID: Protection] = [:]
        for t in w.chrome.tabs { out[t.itemID] = tabProtection(t) }
        for win in w.chrome.windows { out[win.itemID] = Protection.none }
        let browserPids = Set(w.ownership.mainBrowsers.map(\.key.pid) + w.chrome.tabs.map(\.browserPid))
        for b in browserPids {
            for k in ChromeOverheadKind.allCases {
                out[.chromeOverhead(browserPid: b, kind: k.rawValue)] = .locked(.chromeCore)
            }
        }
        for s in w.claude.sessions {
            out[s.itemID] = sessionProtection(s, now: now)
            for u in s.children + s.background { out[u.itemID] = .locked(Self.childProcessReason) }
        }
        for l in w.claude.leftovers {
            if let alive = isAlive, !alive(l.unit.root) {
                out[l.id] = .locked(.pidMismatch)
            } else {
                out[l.id] = .confirm([.leftover])
            }
        }
        return out
    }

    public func tabProtection(_ t: ChromeTab) -> Protection {
        var r: [Reason] = []
        if t.audible { r.append(.audible) }
        if t.pinned { r.append(.pinned) }
        return r.isEmpty ? Protection.none : .confirm(r)
    }

    public func sessionProtection(_ s: ClaudeSession, now: Date) -> Protection {
        if s.isLauncher || launcherPids.contains(s.key.pid) { return .locked(.launcher) }
        if let alive = isAlive, !alive(s.key) { return .locked(.pidMismatch) }
        var r: [Reason] = []
        if s.busy {
            r.append(.busy(nil))
        } else if !s.unregistered, s.status.isEmpty || s.status == "unknown" {
            r.append(.busy("status unknown"))
        }
        if !s.busy, let since = s.idleSince, now.timeIntervalSince(since) < recentActivityWindow {
            r.append(.recentActivity)
        }
        // Never close what the user is looking at: tmux visible or current, Rex visible (Rex has no "current", and
        // an unplaced Rex pane is visible: unknown means protected).
        if s.onScreen { r.append(.visiblePane) }
        if !s.inMultiplexer { r.append(.notInTmux) }
        if !s.background.isEmpty { r.append(.hasBackground(s.background.count, s.backgroundBytes)) }
        if !s.hasTranscript && !s.unregistered { r.append(.noTranscript) }
        if !s.cwdExists { r.append(.cwdMissing) }
        if s.unregistered { r.append(.unregistered) }
        return r.isEmpty ? Protection.none : .confirm(r)
    }

    // MARK: Plan

    /// Expands window rows to their tabs, de-duplicates, drops locked rows into `locked`, adds the
    /// selection-dependent reasons and computes the freed() estimate.
    public func plan(_ sel: Set<ItemID>, _ w: WorldSnapshot, now: Date = Date()) -> ClosePlan {
        let prot = protections(w, now: now)
        let ids = expand(sel, w)

        var items: [PlanItem] = []
        var locked: [LockedItem] = []
        for id in ids {
            let p = prot[id] ?? .locked(.pidMismatch)          // unknown or vanished row
            if case .locked(let r) = p { locked.append(LockedItem(id: id, reason: r)); continue }
            switch id {
            case let .chromeTab(b, t):
                guard let tab = w.chrome.tab(TabRef(browserPid: b, tabId: t)) else {
                    locked.append(LockedItem(id: id, reason: .pidMismatch)); continue
                }
                items.append(PlanItem(id: id, protection: p, bytes: tab.display ?? 0, title: tab.title))
            case .session(let k):
                guard let s = w.claude.sessions.first(where: { $0.key == k }) else {
                    locked.append(LockedItem(id: id, reason: .pidMismatch)); continue
                }
                items.append(PlanItem(id: id, protection: p, bytes: s.total, title: s.title))
            case .leftover:
                guard let l = w.claude.leftovers.first(where: { $0.id == id }) else {
                    locked.append(LockedItem(id: id, reason: .pidMismatch)); continue
                }
                items.append(PlanItem(id: id, protection: p, bytes: l.unit.footprint,
                                      title: l.sessionTitle.map { "\(l.unit.command) (\($0))" } ?? l.unit.command))
            case .process:
                locked.append(LockedItem(id: id, reason: Self.childProcessReason))
            case .chromeOverhead, .chromeWindow:
                locked.append(LockedItem(id: id, reason: .chromeCore))
            }
        }

        // Selection-dependent tab reasons.
        let closingTabs = Set(items.compactMap { i -> TabRef? in
            if case let .chromeTab(b, t) = i.id { return TabRef(browserPid: b, tabId: t) } else { return nil }
        })
        var extra: [ItemID: [Reason]] = [:]
        if !closingTabs.isEmpty {
            let byBrowser = Dictionary(grouping: w.chrome.windows, by: \.browserPid)
            for (b, wins) in byBrowser {
                var emptied: [ChromeWindow] = []
                for win in wins {
                    let refs = win.tabIds.map { TabRef(browserPid: b, tabId: $0) }
                    guard !refs.isEmpty, refs.allSatisfy(closingTabs.contains) else { continue }
                    emptied.append(win)
                    if refs.count > emptiesWindowThreshold {
                        for r in refs { extra[r.itemID, default: []].append(.emptiesWindow(refs.count)) }
                    }
                }
                let normal = wins.filter { !$0.incognito && !$0.tabIds.isEmpty }
                let emptiedNormal = emptied.filter { !$0.incognito }
                if !normal.isEmpty, emptiedNormal.count == normal.count {
                    for win in emptiedNormal {
                        for t in win.tabIds { extra[.chromeTab(browserPid: b, tabId: t), default: []].append(.closesAllWindows) }
                    }
                }
            }
        }
        let many = items.count > manyItemsThreshold
        if many || !extra.isEmpty {
            items = items.map { i in
                var r = i.protection.reasons + (extra[i.id] ?? [])
                if many { r.append(.manyItems) }
                return r.isEmpty ? i : PlanItem(id: i.id, protection: .confirm(r), bytes: i.bytes, title: i.title)
            }
        }
        return ClosePlan(items: items, locked: locked, estimate: PlanMath.estimate(items, w), world: w)
    }

    /// Window rows → their tabs (in index order); everything else kept; de-duplicated, stable order.
    public func expand(_ sel: Set<ItemID>, _ w: WorldSnapshot) -> [ItemID] {
        var ids: [ItemID] = []
        var seen: Set<ItemID> = []
        for id in sel.sorted() {
            if case let .chromeWindow(b, wid) = id {
                let tabs = w.chrome.tabs.filter { $0.browserPid == b && $0.windowId == wid }.sorted { $0.index < $1.index }
                if tabs.isEmpty { if seen.insert(id).inserted { ids.append(id) } }
                for t in tabs where seen.insert(t.itemID).inserted { ids.append(t.itemID) }
            } else if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }
}

/// Estimates shared by the sheet, the footer and the CLI.
public enum PlanMath {
    /// freed(tabs) + Σ session totals + Σ leftover footprints.
    public static func estimate(_ items: [PlanItem], _ w: WorldSnapshot, stopBackground: Bool = true) -> Bytes {
        var tabs: Set<TabRef> = []
        var other: Bytes = 0
        for i in items {
            switch i.id {
            case let .chromeTab(b, t): tabs.insert(TabRef(browserPid: b, tabId: t))
            case .session(let k):
                if let s = w.claude.sessions.first(where: { $0.key == k }) {
                    other += stopBackground ? s.total : s.total - s.backgroundBytes
                } else { other += i.bytes }
            default: other += i.bytes
            }
        }
        return w.chrome.freed(tabs) + other
    }

    public static func isBusy(_ i: PlanItem) -> Bool {
        i.protection.reasons.contains { if case .busy = $0 { true } else { false } }
    }

    /// The items `execute` will act on, given the sheet's choices.
    public static func effectiveItems(_ p: ClosePlan) -> [PlanItem] {
        p.skipBusy ? p.items.filter { !isBusy($0) } : p.items
    }

    public static func effectiveEstimate(_ p: ClosePlan) -> Bytes {
        estimate(effectiveItems(p), p.world, stopBackground: p.stopBackground)
    }

    /// Background units the "Also stop N background processes" checkbox covers.
    public static func backgroundUnits(_ p: ClosePlan) -> [LinkedUnit] {
        effectiveItems(p).flatMap { i -> [LinkedUnit] in
            guard case .session(let k) = i.id else { return [] }
            return p.world.claude.sessions.first { $0.key == k }?.background ?? []
        }
    }

    public static func busyCount(_ p: ClosePlan) -> Int { p.items.filter(isBusy).count }

    /// Tabs whose memory is unknown (AppleScript list, no helper, degraded join, unmatched frames). Their bytes
    /// are not in `estimate`, which is then a lower bound.
    public static func unknownTabs(_ items: [PlanItem], _ w: WorldSnapshot) -> Int {
        items.filter { i in
            guard case let .chromeTab(b, t) = i.id, let tab = w.chrome.tab(TabRef(browserPid: b, tabId: t)) else { return false }
            return tab.display == nil && !tab.discarded
        }.count
    }

    public static func effectiveUnknown(_ p: ClosePlan) -> Int { unknownTabs(effectiveItems(p), p.world) }

    /// "≈1.2 GB", "≥1.2 GB + 3 tabs of unknown size", or "an unknown amount" when nothing is known.
    public static func estimateText(_ bytes: Bytes, unknown: Int, approx: String = "≈") -> String {
        if unknown == 0 { return approx + ByteFormat.short(bytes) }
        let tabs = unknown == 1 ? "1 tab" : "\(unknown) tabs"
        if bytes == 0 { return "an unknown amount (\(tabs) of unknown size)" }
        return "≥\(ByteFormat.short(bytes)) + \(tabs) of unknown size"
    }

    public static func effectiveEstimateText(_ p: ClosePlan, approx: String = "≈") -> String {
        estimateText(effectiveEstimate(p), unknown: effectiveUnknown(p), approx: approx)
    }
}
