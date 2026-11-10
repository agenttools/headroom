// Mock world + executor for UI development, `headroom --mock` and tests.
// The executor never touches a process or Chrome: every outcome is .dryRun.

import Foundation
import HeadroomContracts

public final class MockState: @unchecked Sendable {
    private let lock = NSLock()
    private var closed: Set<ItemID> = []
    private var records: [ClosedRecord] = []
    public init() {}

    func close(_ ids: [ItemID], records new: [ClosedRecord]) {
        lock.lock(); defer { lock.unlock() }
        closed.formUnion(ids); records.insert(contentsOf: new, at: 0)
    }
    func reopen(_ r: [ClosedRecord]) {
        lock.lock(); defer { lock.unlock() }
        for rec in r { if let id = ItemID(string: rec.itemId) { closed.remove(id) } }
        let ids = Set(r.map(\.id)); records.removeAll { ids.contains($0.id) }
    }
    var closedIDs: Set<ItemID> { lock.lock(); defer { lock.unlock() }; return closed }
    var recent: [ClosedRecord] { lock.lock(); defer { lock.unlock() }; return records }
}

public struct MockWorldProvider: WorldProvider {
    public let state: MockState
    /// Simulated Chrome data source (HEADROOM_MOCK_CHROME=helper|processesOnly|appleScript|waiting|notRunning|stale),
    /// so the first-run card and the inline empty/error states can be exercised without Chrome.
    public let chromeMode: String
    /// HEADROOM_MOCK_JITTER=1: tab footprints change on every snapshot (exercises the sort freeze).
    public let jitter: Bool
    public init(state: MockState = MockState(), chromeMode: String = "helper", jitter: Bool = false) {
        self.state = state; self.chromeMode = chromeMode; self.jitter = jitter
    }

    static func jittered(_ w: WorldSnapshot) -> WorldSnapshot {
        var c = w.chrome
        for i in c.tabs.indices where c.tabs[i].display != nil {
            c.tabs[i].display = Bytes.mb(Double.random(in: 40...900))
        }
        return WorldSnapshot(system: w.system, chrome: c, claude: w.claude, ownership: w.ownership,
                             selfBytes: w.selfBytes, helperBytes: w.helperBytes, at: w.at, isMock: true)
    }

    public func snapshot() async -> WorldSnapshot {
        var w = Self.applyChromeMode(MockWorld.snapshot(now: Date()), chromeMode)
        if jitter { w = Self.jittered(w) }
        let gone = state.closedIDs
        guard !gone.isEmpty else { return w }
        var chrome = w.chrome
        chrome.tabs.removeAll { gone.contains($0.itemID) }
        for i in chrome.windows.indices {
            let b = chrome.windows[i].browserPid
            chrome.windows[i].tabIds.removeAll { gone.contains(.chromeTab(browserPid: b, tabId: $0)) }
        }
        chrome.windows.removeAll { $0.tabIds.isEmpty }
        var claude = w.claude
        claude.sessions.removeAll { gone.contains($0.itemID) }
        claude.leftovers.removeAll { gone.contains($0.id) }
        return WorldSnapshot(system: w.system, chrome: chrome, claude: claude, ownership: w.ownership,
                             selfBytes: w.selfBytes, helperBytes: w.helperBytes, at: w.at, isMock: true)
    }
}

extension MockWorldProvider {
    static func applyChromeMode(_ w: WorldSnapshot, _ mode: String) -> WorldSnapshot {
        var c = w.chrome
        switch mode {
        case "processesOnly":
            c.source = .processesOnly; c.tabs = []; c.windows = []
        case "appleScript":
            c.source = .appleScript
            for i in c.tabs.indices { c.tabs[i].display = nil; c.tabs[i].sharedWith = 0 }
            c.perTabUnavailable = "Per-tab memory needs the helper extension"
        case "waiting":
            c.source = .waiting; c.tabs = []; c.windows = []
        case "notRunning":
            c = .notRunning
        case "stale":
            c.staleSince = w.at.addingTimeInterval(-40)
        default:
            return w
        }
        return WorldSnapshot(system: w.system, chrome: c, claude: w.claude, ownership: w.ownership,
                             selfBytes: w.selfBytes, helperBytes: mode == "helper" ? w.helperBytes : nil, at: w.at,
                             isMock: true)
    }
}

public final class MockExecutor: ActionExecutor, PeekProvider, @unchecked Sendable {
    public let state: MockState
    public let env: HeadroomEnv
    let planner = Planner()
    public init(state: MockState = MockState(), env: HeadroomEnv = .current) { self.state = state; self.env = env }

    public func protections(_ w: WorldSnapshot) -> [ItemID: Protection] { planner.protections(w) }
    public func plan(_ sel: Set<ItemID>, _ w: WorldSnapshot) -> ClosePlan { planner.plan(sel, w) }

    public func execute(_ p: ClosePlan) -> AsyncStream<ActionEvent> {
        let state = self.state
        return AsyncStream { c in
            let batch = UUID().uuidString
            var recs: [ClosedRecord] = []
            for item in p.items {
                if p.skipBusy, item.protection.reasons.contains(where: { if case .busy = $0 { true } else { false } }) {
                    continue
                }
                c.yield(.progress(item.id, .dryRun))
                recs.append(Self.record(item, p.world, batch: batch))
            }
            state.close(recs.compactMap { ItemID(string: $0.itemId) }, records: recs)
            c.yield(.finished(recs))
            c.finish()
        }
    }

    static func record(_ item: PlanItem, _ w: WorldSnapshot, batch: String) -> ClosedRecord {
        var r = ClosedRecord(batchId: batch, kind: item.id.kind.rawValue, itemId: item.id.stringValue,
                             closedAt: Date(), title: item.title, bytes: item.bytes, source: "mock")
        switch item.id {
        case let .chromeTab(b, t):
            if let tab = w.chrome.tab(TabRef(browserPid: b, tabId: t)) {
                r.url = tab.incognito ? nil : tab.url; r.browserPid = b; r.windowId = tab.windowId
                r.index = tab.index; r.incognito = tab.incognito
            }
        case .session(let k):
            if let s = w.claude.sessions.first(where: { $0.key == k }) {
                r.sessionId = s.sessionId; r.cwd = s.cwd; r.tmuxSession = s.tmux?.session
            }
        case .leftover:
            if let l = w.claude.leftovers.first(where: { $0.id == item.id }) { r.argv = l.unit.argv; r.cwd = l.unit.cwd }
        default: break
        }
        return r
    }

    public func forceQuit(_ ids: [ItemID]) async {}
    public func sleep(_ tabs: [ItemID]) async -> [ItemID: Outcome] {
        Dictionary(uniqueKeysWithValues: tabs.map { ($0, Outcome.dryRun) })
    }
    public func undo(_ r: [ClosedRecord]) async -> [ClosedRecord: Outcome] {
        let ok = r.filter(\.restorable)
        state.reopen(ok)
        return Dictionary(uniqueKeysWithValues: r.map { ($0, $0.restorable ? Outcome.dryRun : .failed("not restorable")) })
    }
    public func jump(_ id: ItemID) async {}
    public func recentlyClosed() async -> [ClosedRecord] { state.recent }

    // PeekProvider: canned output, never runs tmux or lsof.
    public func capturePane(_ paneId: String) async -> String? {
        """
        ⏺ Done. The ledger sync now rounds half-even and the tests pass.

        ✻ Worked for 3m 12s

        ╭──────────────────────────────────────────────╮
        │ >                                            │
        ╰──────────────────────────────────────────────╯
          ? for shortcuts                (mock pane \(paneId))
        """
    }
    public func listeningPorts(_ pids: [Int32]) async -> [String] {
        pids.prefix(1).map { "node    \($0) jappleseed   23u  IPv4 0x0  0t0  TCP 127.0.0.1:3217 (LISTEN)" }
    }
}
