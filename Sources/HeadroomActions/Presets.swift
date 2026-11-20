// Select ▾ presets (SPEC §7.2). They only select; there is no Select & Close.

import Foundation
import HeadroomContracts

public enum SelectPreset: Sendable, Hashable {
    /// Idle sessions older than the interval. Excludes busy, on screen (visible or current tmux pane, visible or
    /// unplaced Rex pane), not in tmux or Rex, no transcript, cwd missing, background-owning, unregistered and
    /// launcher sessions (and anything locked).
    case idleSessions(TimeInterval)
    case tmuxSession(String)
    case tabsOver(Bytes)
    case sessionsOver(Bytes)
    /// Keeps the one with the most recent lastAccessed.
    case duplicateTabs
    /// Tabs on the same site(s) as the given tabs.
    case sameSite([ItemID])
    /// Tabs in windows that are not focused.
    case backgroundWindows
    case allLeftovers
    /// Sessions in one Rex session, keyed by its full id (labels need not be unique); `label` is the menu title.
    case rexSession(id: String, label: String)

    public static let idleIntervals: [(String, TimeInterval)] = [
        ("30m", 1800), ("1h", 3600), ("2h", 7200), ("6h", 21_600), ("1d", 86_400),
    ]

    public var title: String {
        switch self {
        case .idleSessions(let t):
            let label = Self.idleIntervals.first { $0.1 == t }?.0 ?? Fmt.age(t)
            return "Idle sessions older than \(label)"
        case .tmuxSession(let s): return s
        case .tabsOver(let b): return "Tabs over \(ByteFormat.short(b))"
        case .sessionsOver(let b): return "Sessions over \(ByteFormat.short(b))"
        case .duplicateTabs: return "Duplicate tabs"
        case .sameSite: return "Tabs on the same site as the selection"
        case .backgroundWindows: return "Tabs in background windows"
        case .allLeftovers: return "All leftovers"
        case .rexSession(_, let label): return label
        }
    }

    public func ids(_ w: WorldSnapshot, protections: [ItemID: Protection], now: Date = Date()) -> [ItemID] {
        func locked(_ id: ItemID) -> Bool { protections[id]?.isLocked ?? false }
        switch self {
        case .idleSessions(let t):
            return w.claude.sessions.filter { s in
                guard !s.busy, !s.isLauncher, !s.unregistered, s.hasTranscript, s.cwdExists, s.background.isEmpty,
                      s.inMultiplexer, !s.onScreen, !locked(s.itemID),
                      let since = s.idleSince else { return false }
                return now.timeIntervalSince(since) > t
            }.map(\.itemID)
        case .tmuxSession(let name):
            return w.claude.sessions.filter { $0.tmux?.session == name && !locked($0.itemID) }.map(\.itemID)
        case .tabsOver(let b):
            return w.chrome.tabs.filter { ($0.display ?? 0) > b && !locked($0.itemID) }.map(\.itemID)
        case .sessionsOver(let b):
            return w.claude.sessions.filter { $0.total > b && !locked($0.itemID) }.map(\.itemID)
        case .duplicateTabs:
            let groups = Dictionary(grouping: w.chrome.tabs.filter { !$0.incognito }) { Self.normalize($0.url) }
            return groups.values.filter { $0.count > 1 }.flatMap { g -> [ItemID] in
                let keep = g.max { ($0.active ? Date.distantFuture : $0.lastAccessed ?? .distantPast)
                                 < ($1.active ? Date.distantFuture : $1.lastAccessed ?? .distantPast) }
                return g.filter { $0.ref != keep?.ref }.map(\.itemID)
            }
        case .sameSite(let sel):
            let hosts = Set(sel.compactMap { id -> String? in
                guard case let .chromeTab(b, t) = id else { return nil }
                return w.chrome.tab(TabRef(browserPid: b, tabId: t))?.host
            }.filter { !$0.isEmpty })
            return w.chrome.tabs.filter { hosts.contains($0.host) }.map(\.itemID)
        case .backgroundWindows:
            let bg = Set(w.chrome.windows.filter { !$0.focused }.map { "\($0.browserPid):\($0.id)" })
            return w.chrome.tabs.filter { bg.contains("\($0.browserPid):\($0.windowId)") }.map(\.itemID)
        case .allLeftovers:
            return w.claude.leftovers.map(\.id)
        case .rexSession(let id, _):
            return w.claude.sessions.filter { $0.rex?.sessionId == id && !locked($0.itemID) }.map(\.itemID)
        }
    }

    /// The menu's live "(count · GB)" suffix.
    public func summary(_ w: WorldSnapshot, protections: [ItemID: Protection], now: Date = Date()) -> (count: Int, bytes: Bytes) {
        let ids = ids(w, protections: protections, now: now)
        let plan = Planner().plan(Set(ids), w, now: now)
        return (ids.count, plan.estimate)
    }

    static func normalize(_ url: String) -> String {
        var u = url
        if let hash = u.firstIndex(of: "#") { u = String(u[..<hash]) }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }
}
