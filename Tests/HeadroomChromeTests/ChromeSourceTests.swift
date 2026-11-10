// ChromeSource end to end with fake hosts on a scratch socket and a synthetic process table.
// The AppleScript fallback is disabled (jxa: nil), so nothing here can reach Google Chrome.
import Darwin
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomChrome

/// A SysKit over a fixed table (HeadroomCore's StaticSysKit is not visible to this test target).
struct TableSys: SysKit {
    let table: ProcessTable
    let argv: [Int32: [String]]
    func scan() -> ProcessTable { table }
    func args(_ k: ProcKey) -> ProcArgs? { argv[k.pid].map { ProcArgs(argv: $0) } }
    func cwd(_ pid: Int32) -> String? { nil }
    func systemMemory() -> SystemMemory { .zero }
    func isAlive(_ k: ProcKey) -> Bool { table.byPid[k.pid]?.key == k }
}

/// Browser 4242 with renderers client 5 (100 MB) and 6 (40 MB), plus GPU and an extension renderer.
struct World {
    static let b: Int32 = 4242
    let table: ProcessTable
    let sys: TableSys
    let own: OwnershipMap
    init(browserPath: String = KnownPaths.chromeExecutable, owned: Bool = true) {
        func s(_ pid: Int32, _ ppid: Int32, _ mb: Bytes) -> ProcSample {
            ProcSample(key: ProcKey(pid: pid, startSec: 500), ppid: ppid, pgid: pid, path: browserPath, footprint: mb * MB, rss: 0)
        }
        table = ProcessTable(samples: [s(Self.b, 1, 300), s(4243, Self.b, 200), s(4244, Self.b, 100), s(4245, Self.b, 40), s(4246, Self.b, 30)])
        sys = TableSys(table: table, argv: [
            Self.b: [browserPath], 4243: ["h", "--type=gpu-process"], 4244: ["h", "--type=renderer", "--renderer-client-id=5"],
            4245: ["h", "--type=renderer", "--renderer-client-id=6"], 4246: ["h", "--type=renderer", "--extension-process"],
        ])
        if owned {
            own = OwnershipMap(owner: Dictionary(uniqueKeysWithValues: table.byPid.keys.map { ($0, Owner.chrome(browserPid: Self.b)) }),
                               browsers: [BrowserInstance(key: ProcKey(pid: Self.b, startSec: 500), isMain: true, userDataDir: nil, headless: false)])
        } else {
            own = .empty
        }
    }
}

let twoTabs = #"""
{"t":"snapshot","req":REQ,"at":0,"windows":[{"id":1,"focused":true,"incognito":false,"type":"normal","state":"normal"}],
 "tabs":[{"id":10,"windowId":1,"index":0,"title":"A","url":"https://a.test/","active":true,"pinned":false,"incognito":false,"audible":true,"discarded":false,"lastAccessed":1790000000000,"frames":[{"frameId":0,"parentFrameId":-1,"processId":5,"documentLifecycle":"active"}]},
         {"id":11,"windowId":1,"index":1,"title":"B","url":"https://b.test/","active":false,"pinned":true,"incognito":false,"frames":[{"frameId":0,"parentFrameId":-1,"processId":6}]}]}
"""#.replacingOccurrences(of: "\n", with: "")

func makeEnv(_ s: Scratch, dryRun: Bool = false) -> HeadroomEnv {
    HeadroomEnv(environment: ["HOME": s.path + "/home", "HEADROOM_SUPPORT_DIR": s.path, "HEADROOM_DRY_RUN": dryRun ? "1" : "0"])
}

func source(_ env: HeadroomEnv, timeout: TimeInterval = 1) -> ChromeSource {
    var o = ChromeSource.Options(); o.initialHostWait = 0
    var bo = ChromeBridge.Options(); bo.requestTimeout = timeout
    return ChromeSource(env: env, options: o, jxa: nil, bridge: ChromeBridge(env: env, options: bo))
}

/// A fake helper for browser 4242: answers snapshots with `twoTabs`, records every request.
final class FakeHelper: @unchecked Sendable {
    let host: FakeHost
    let log = LockedBox<[[String: Any]]>([])
    var replies: @Sendable (String, Int, [String: Any]) -> String?
    init?(_ socket: String, browserPid: Int32 = World.b, replies: @escaping @Sendable (String, Int, [String: Any]) -> String? = { _, _, _ in nil }) {
        guard let h = FakeHost.connect(socket) else { return nil }
        host = h
        self.replies = replies
        h.sendLine(hostLine(browserPid: browserPid))
        h.sendLine(helloLine)
        let log = self.log
        let custom = replies
        h.serve { t, req, o in
            log.set(log.get() + [o])
            guard let req else { return nil }
            if let r = custom(t, req, o) { return r }
            if t == "snapshot" { return twoTabs.replacingOccurrences(of: "REQ", with: String(req)) }
            return nil
        }
    }
    func close() { host.close() }
    func sent(_ t: String) -> [[String: Any]] { log.get().filter { $0["t"] as? String == t } }
}

struct NoHelper: Error {}
func helper(_ h: FakeHelper?) throws -> FakeHelper { guard let h else { throw NoHelper() }; return h }

@Suite(.serialized) struct ChromeSourceTests {
    @Test func notRunningWithoutBrowsers() async {
        let s = Scratch(); defer { s.cleanup() }
        let src = source(makeEnv(s)); defer { src.stop() }
        let snap = await src.snapshot(.empty, .empty, TableSys(table: .empty, argv: [:]))
        #expect(snap.source == .notRunning && snap.tabs.isEmpty && snap.total == 0)
    }

    @Test func processesOnlyWithoutHelperOrPermission() async {
        let s = Scratch(); defer { s.cleanup() }
        let src = source(makeEnv(s)); defer { src.stop() }
        let w = World()
        let snap = await src.snapshot(w.table, w.own, w.sys)
        #expect(snap.source == .processesOnly)
        #expect(snap.total == (300 + 200 + 100 + 40 + 30) * MB)
        #expect(snap.overheadTotal == (300 + 200 + 30) * MB)
        #expect(snap.tabs.isEmpty)
    }

    @Test func waitingWhenManifestInstalledAndBridgeJustStarted() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let env = makeEnv(s)
        try HostManifest(env: env).write(hostPath: "/bin/cat", extensionId: String(repeating: "a", count: 32))
        let src = source(env); defer { src.stop() }
        let w = World()
        #expect(await src.snapshot(w.table, w.own, w.sys).source == .waiting)
    }

    @Test func helperSnapshotAttributesPerTab() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let src = source(makeEnv(s)); defer { src.stop() }
        _ = await src.hosts()  // starts the bridge
        let h = try helper(FakeHelper(src.env.socketPath)); defer { h.close() }
        #expect(await until { src.helperConnected })
        let hosts = await src.hosts()
        #expect(hosts.count == 1 && hosts[0].browserPid == World.b)
        let w = World()
        let snap = await src.snapshot(w.table, w.own, w.sys)
        #expect(snap.source == .helper(profiles: 1))
        #expect(snap.tabs.count == 2 && snap.windows.count == 1 && snap.windows[0].tabIds == [10, 11])
        let a = try #require(snap.tab(TabRef(browserPid: World.b, tabId: 10)))
        #expect(a.display == 100 * MB && a.audible && a.active && a.host == "a.test")
        #expect(a.lastAccessed == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(snap.tab(TabRef(browserPid: World.b, tabId: 11))?.pinned == true)
        #expect(snap.tabs.reduce(0) { $0 + ($1.display ?? 0) } + snap.overheadTotal == snap.total)
        #expect(snap.staleSince == nil && snap.perTabUnavailable == nil)
    }

    @Test func hostNamedBrowserUnknownToOwnershipIsCounted() async throws {
        // Chrome for Testing: not a Google Chrome path, so Ownership leaves it unowned; the host names it.
        let s = Scratch(); defer { s.cleanup() }
        let src = source(makeEnv(s)); defer { src.stop() }
        _ = await src.hosts()
        let h = try helper(FakeHelper(src.env.socketPath)); defer { h.close() }
        #expect(await until { src.helperConnected })
        let w = World(browserPath: "/x/Google Chrome for Testing", owned: false)
        let snap = await src.snapshot(w.table, w.own, w.sys)
        #expect(snap.source == .helper(profiles: 1) && snap.total == 670 * MB)
        #expect(snap.tabs.first { $0.id == 10 }?.display == 100 * MB)
    }

    @Test func staleDataAfterDisconnectThenDropped() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let env = makeEnv(s)
        var o = ChromeSource.Options(); o.initialHostWait = 0; o.staleLimit = 0.6
        let src = ChromeSource(env: env, options: o, jxa: nil); defer { src.stop() }
        _ = await src.hosts()
        let h = try helper(FakeHelper(env.socketPath))
        #expect(await until { src.helperConnected })
        let w = World()
        #expect(await src.snapshot(w.table, w.own, w.sys).staleSince == nil)
        h.close()
        #expect(await until { src.bridge.connections().isEmpty })
        let stale = await src.snapshot(w.table, w.own, w.sys)
        #expect(stale.source == .helper(profiles: 1) && stale.tabs.count == 2 && stale.staleSince != nil)
        try await Task.sleep(for: .milliseconds(700))
        let later = await src.snapshot(w.table, w.own, w.sys)
        #expect(later.tabs.isEmpty && later.source == .processesOnly)
    }

    @Test func closeRoutesToHelperAndKeepsRestoreIds() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let src = source(makeEnv(s)); defer { src.stop() }
        _ = await src.hosts()
        let h = try helper(FakeHelper(src.env.socketPath, replies: { t, req, o in
            guard t == "close" else { return nil }
            let tabs = o["tabs"] as? [[String: Any]] ?? []
            var res: [String: String] = [:]
            for x in tabs {
                let id = x["id"] as! Int, url = x["url"] as! String
                res[String(id)] = id == 10 ? (url == "https://a.test/" ? "done" : "changedSkipped") : id == 11 ? "failed:beforeunload" : "gone"
            }
            let body = try! JSONSerialization.data(withJSONObject: ["t": "result", "req": req, "results": res, "restore": ["10": "sess-10"]])
            return String(data: body, encoding: .utf8)
        }))
        defer { h.close() }
        #expect(await until { src.helperConnected })
        let w = World()
        _ = await src.snapshot(w.table, w.own, w.sys)
        let out = await src.close([TabCloseRequest(browserPid: World.b, id: 10, expectedURL: "https://a.test/"),
                                   TabCloseRequest(browserPid: World.b, id: 11, expectedURL: "https://b.test/"),
                                   TabCloseRequest(browserPid: World.b, id: 99, expectedURL: "https://z.test/"),
                                   TabCloseRequest(browserPid: 777, id: 1, expectedURL: "https://q.test/")])
        #expect(out[.chromeTab(browserPid: World.b, tabId: 10)] == .done)
        #expect(out[.chromeTab(browserPid: World.b, tabId: 11)] == .failed("beforeunload"))
        #expect(out[.chromeTab(browserPid: World.b, tabId: 99)] == .alreadyGone)
        #expect(out[.chromeTab(browserPid: 777, tabId: 1)] == .failed("Chrome is not connected"))
        let sent = h.sent("close")
        #expect(sent.count == 1)
        #expect((sent[0]["tabs"] as? [[String: Any]])?.count == 3)
        #expect(src.restoreId(for: "tab:4242:10") == "sess-10")
        // Persisted for a later process (e.g. `headroom undo` after `headroom close`); no URLs in the file.
        let file = try String(contentsOfFile: s.path + "/chrome-restore.json", encoding: .utf8)
        #expect(file.contains("sess-10") && !file.contains("a.test"))
        let src2 = source(makeEnv(s)); defer { src2.stop() }
        #expect(src2.restoreId(for: "tab:4242:10") == "sess-10")

        // A changed URL is skipped by the helper.
        let o2 = await src.close([TabCloseRequest(browserPid: World.b, id: 10, expectedURL: "https://moved.test/")])
        #expect(o2[.chromeTab(browserPid: World.b, tabId: 10)] == .changedSkipped)
    }

    @Test func dryRunSendsNothing() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let src = source(makeEnv(s, dryRun: true)); defer { src.stop() }
        _ = await src.hosts()
        let h = try helper(FakeHelper(src.env.socketPath)); defer { h.close() }
        #expect(await until { src.helperConnected })
        let id = ItemID.chromeTab(browserPid: World.b, tabId: 10)
        #expect(await src.close([TabCloseRequest(browserPid: World.b, id: 10, expectedURL: "https://a.test/")])[id] == .dryRun)
        #expect(await src.discard([id])[id] == .dryRun)
        #expect(await src.activateTab(id) == .dryRun)
        let rec = ClosedRecord(batchId: "b", kind: "tab", itemId: id.stringValue, closedAt: Date(), title: "A", bytes: 0,
                               url: "https://a.test/", browserPid: World.b)
        #expect(await src.restore([rec])[rec] == .dryRun)
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.sent("close").isEmpty && h.sent("discard").isEmpty && h.sent("activate").isEmpty && h.sent("restore").isEmpty)
    }

    @Test func discardActivateRestoreSetMode() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let src = source(makeEnv(s)); defer { src.stop() }
        _ = await src.hosts()
        let h = try helper(FakeHelper(src.env.socketPath, replies: { t, req, o in
            switch t {
            case "discard": return #"{"t":"result","req":\#(req),"results":{"11":"done"}}"#
            case "activate": return #"{"t":"result","req":\#(req),"results":{"\#(o["tabId"] as! Int)":"gone"}}"#
            case "restore":
                return #"{"t":"result","req":\#(req),"restored":[{"url":"https://a.test/","newTabId":30,"via":"sessions"},{"url":"https://c.test/","newTabId":null,"via":"failed","error":"x"}]}"#
            default: return nil
            }
        }))
        defer { h.close() }
        #expect(await until { src.helperConnected })
        let w = World()
        _ = await src.snapshot(w.table, w.own, w.sys)
        let t11 = ItemID.chromeTab(browserPid: World.b, tabId: 11)
        #expect(await src.discard([t11])[t11] == .done)
        #expect(await src.discard([.session(ProcKey(pid: 1, startSec: 1))])[.session(ProcKey(pid: 1, startSec: 1))] == .failed("not a tab"))
        // Activate carries the window id from the last snapshot; "gone" maps to alreadyGone (no app activation).
        #expect(await src.activateTab(.chromeTab(browserPid: World.b, tabId: 10)) == .alreadyGone)
        #expect(h.sent("activate").first?["windowId"] as? Int == 1)
        let r1 = ClosedRecord(batchId: "b", kind: "tab", itemId: "tab:4242:10", closedAt: Date(), title: "A", bytes: 0,
                              url: "https://a.test/", browserPid: World.b, windowId: 1, index: 0, chromeSessionId: "sess-10")
        let r2 = ClosedRecord(batchId: "b", kind: "tab", itemId: "tab:4242:12", closedAt: Date(), title: "C", bytes: 0,
                              url: "https://c.test/", browserPid: 1, windowId: 1, index: 2)
        let r3 = ClosedRecord(batchId: "b", kind: "session", itemId: "session:1:1", closedAt: Date(), title: "s", bytes: 0)
        let res = await src.restore([r1, r2, r3])
        #expect(res[r1] == .done)
        #expect(res[r2] == .failed("Chrome could not reopen the tab"))
        #expect(res[r3] == .failed("not a restorable tab"))
        let items = h.sent("restore").first?["items"] as? [[String: Any]] ?? []
        #expect(items.count == 2 && items[0]["sessionId"] as? String == "sess-10" && items[0]["windowId"] as? Int == 1)
        await src.setMode("on-demand")
        await src.setMode("bogus")
        #expect(await until { h.sent("setMode").count == 1 })
        #expect(h.sent("setMode").first?["mode"] as? String == "on-demand")
    }

    @Test func helperTimeoutFailsTheTabs() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let src = source(makeEnv(s), timeout: 0.3); defer { src.stop() }
        _ = await src.hosts()
        let h = try helper(FakeHelper(src.env.socketPath, replies: { t, _, _ in t == "close" ? "" : nil }))
        defer { h.close() }
        #expect(await until { src.helperConnected })
        let out = await src.close([TabCloseRequest(browserPid: World.b, id: 10, expectedURL: "https://a.test/")])
        #expect(out[.chromeTab(browserPid: World.b, tabId: 10)] == .failed("Chrome helper did not answer in time"))
    }

    @Test func errorReplyFailsEveryTab() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let src = source(makeEnv(s)); defer { src.stop() }
        _ = await src.hosts()
        let h = try helper(FakeHelper(src.env.socketPath, replies: { t, req, _ in
            t == "close" ? #"{"t":"result","req":\#(req),"error":"boom"}"# : nil
        }))
        defer { h.close() }
        #expect(await until { src.helperConnected })
        let out = await src.close([TabCloseRequest(browserPid: World.b, id: 10, expectedURL: "u"), TabCloseRequest(browserPid: World.b, id: 11, expectedURL: "v")])
        #expect(out.values.allSatisfy { $0 == .failed("boom") } && out.count == 2)
    }

    @Test func twoProfilesMergeAndRouteByProfile() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let src = source(makeEnv(s)); defer { src.stop() }
        _ = await src.hosts()
        let p1 = try helper(FakeHelper(src.env.socketPath)); defer { p1.close() }
        let p2 = try helper(FakeHelper(src.env.socketPath, replies: { t, req, _ in
            switch t {
            case "snapshot":
                return #"{"t":"snapshot","req":\#(req),"at":0,"windows":[{"id":2,"focused":false,"incognito":false}],"tabs":[{"id":20,"windowId":2,"index":0,"title":"P2","url":"https://p2.test/","active":true,"pinned":false,"incognito":false,"frames":[{"frameId":0,"parentFrameId":-1,"processId":5}]}]}"#
            case "discard": return #"{"t":"result","req":\#(req),"results":{"20":"done"}}"#
            default: return nil
            }
        }))
        defer { p2.close() }
        #expect(await until { src.bridge.connections().filter { $0.ext != nil }.count == 2 })
        let w = World()
        let snap = await src.snapshot(w.table, w.own, w.sys)
        #expect(snap.source == .helper(profiles: 2))
        #expect(Set(snap.tabs.map(\.id)) == [10, 11, 20] && snap.windows.count == 2)
        // Renderer 5 is shared by tab 10 (profile 1) and tab 20 (profile 2): fair share 50/50.
        #expect(snap.tabs.first { $0.id == 20 }?.display == 50 * MB && snap.tabs.first { $0.id == 20 }?.sharedWith == 1)
        let t20 = ItemID.chromeTab(browserPid: World.b, tabId: 20)
        #expect(await src.discard([t20])[t20] == .done)
        #expect(p1.sent("discard").isEmpty && p2.sent("discard").count == 1)
    }
}
