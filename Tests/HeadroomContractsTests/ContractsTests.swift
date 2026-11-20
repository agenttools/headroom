import Foundation
import Testing
@testable import HeadroomContracts

@Suite struct ItemIDCodec {
    static let samples: [ItemID] = [
        .chromeTab(browserPid: 812, tabId: 1_101_007),
        .chromeWindow(browserPid: 812, windowId: 1_100_001),
        .chromeOverhead(browserPid: 812, kind: "gpu"),
        .session(ProcKey(pid: 41321, startSec: 1_790_699_333)),
        .leftover(pgid: 7164, leaderStartSec: 1_790_600_000),
        .process(ProcKey(pid: 85291, startSec: 1_790_699_300)),
    ]

    @Test(arguments: samples) func roundTrip(_ id: ItemID) throws {
        #expect(ItemID(string: id.stringValue) == id)
        let data = try JSONEncoder().encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(id.stringValue)\"")
        #expect(try JSONDecoder().decode(ItemID.self, from: data) == id)
    }

    @Test func documentedFormats() {
        #expect(ItemID.chromeTab(browserPid: 812, tabId: 5).stringValue == "tab:812:5")
        #expect(ItemID.session(ProcKey(pid: 1, startSec: 2)).stringValue == "session:1:2")
        #expect(ItemID.leftover(pgid: 3, leaderStartSec: 4).stringValue == "leftover:3:4")
        #expect(ItemID.process(ProcKey(pid: 5, startSec: 6)).stringValue == "proc:5:6")
    }

    @Test(arguments: ["", "tab", "tab:1", "tab:x:1", "tab:1:x", "nope:1:2", "overhead:1:bogus", "session:1:2:3"])
    func rejectsGarbage(_ s: String) { #expect(ItemID(string: s) == nil) }

    @Test func dictionaryKeyedByItemIDEncodesAsObject() throws {
        let d: [ItemID: Outcome] = [.chromeTab(browserPid: 1, tabId: 2): .done]
        let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        #expect(json.contains("\"tab:1:2\""))
    }
}

@Suite struct MockWorldTests {
    let now = Date(timeIntervalSince1970: 1_790_786_000)

    @Test func realisticRowCounts() {
        let w = MockWorld.snapshot(now: now)
        #expect((7...25).contains(w.chrome.tabs.count))
        #expect(w.claude.sessions.count == 23)                  // 20 in tmux or neither + 3 in Rex
        #expect(w.claude.leftovers.count == 3)
        let rows = w.chrome.tabs.count + w.claude.sessions.count + w.claude.leftovers.count
        #expect((35...45).contains(rows))
        #expect(w.claude.sessions.filter(\.isLauncher).count == 1)
        #expect(w.claude.sessions.contains { $0.background.contains(where: \.isAutomationBrowser) })
        let tmuxSessions = Set(w.claude.sessions.compactMap { $0.tmux?.session })
        #expect(tmuxSessions.isSuperset(of: ["quote-composer", "oakfield-ledger", "hub"]))
    }

    @Test func idsStableAcrossSnapshots() {
        let a = MockWorld.snapshot(now: now), b = MockWorld.snapshot(now: now.addingTimeInterval(3600))
        #expect(a.chrome.tabs.map(\.itemID) == b.chrome.tabs.map(\.itemID))
        #expect(a.claude.sessions.map(\.itemID) == b.claude.sessions.map(\.itemID))
    }

    @Test func chromeSectionAddsUp() {
        let c = MockWorld.snapshot(now: now).chrome
        let tabs = c.tabs.reduce(0) { $0 + ($1.display ?? 0) }
        let diff = Int64(c.total) - Int64(tabs + c.overheadTotal)
        #expect(abs(diff) < 1024 * 16, "fair-share tab rows + Chrome itself ≈ section total")
        let linear = c.tabs.filter { $0.host == "linear.app" }
        #expect(linear.count == 2 && linear.allSatisfy { $0.sharedWith == 1 })
        // Closing one Linear tab frees nothing from the shared renderer; closing both frees it.
        #expect(c.freed([linear[0].ref]) == 0)
        #expect(c.freed(Set(linear.map(\.ref))) == .mb(280))
    }

    @Test func noPidInTwoBuckets() {
        let w = MockWorld.snapshot(now: now)
        var seen: Set<Int32> = []
        for s in w.claude.sessions {
            for u in s.children + s.background { for m in u.members { #expect(seen.insert(m.pid).inserted) } }
        }
        for l in w.claude.leftovers { for m in l.unit.members { #expect(seen.insert(m.pid).inserted) } }
        for m in seen { #expect(w.ownership.owner[m] != nil) }
    }

    @Test func worldEncodes() throws {
        let data = try HeadroomJSON.encoder().encode(MockWorld.snapshot(now: now))
        let back = try HeadroomJSON.decoder().decode(WorldSnapshot.self, from: data)
        #expect(back.claude.sessions.count == 23)
        #expect(back.claude.sessions.map(\.rex) == MockWorld.snapshot(now: now).claude.sessions.map(\.rex))
    }

    @Test func rexRows() {
        let w = MockWorld.snapshot(now: now)
        let inRex = w.claude.sessions.filter { $0.rex != nil }
        #expect(inRex.map(\.title) == ["rex release notes", "rex docs pass", "rex billing spike"])
        #expect(inRex.allSatisfy { $0.tmux == nil && $0.inMultiplexer && $0.rex!.placed })
        #expect(inRex.filter(\.onScreen).map(\.title) == ["rex docs pass"])
        #expect(w.claude.sessions.filter { !$0.inMultiplexer }.map(\.title) == ["newsletter draft"])
        #expect(!w.claude.sessions.contains { $0.tmux != nil && $0.rex != nil })
        let docs = inRex[1]
        #expect(docs.itemID.stringValue == "session:43037:1790691540")
        #expect(docs.rex?.label == "foundry:2.1" && docs.rex?.windowLabel == "api reference")
        #expect(docs.placeLabel == "rex foundry:2.1")
        #expect(inRex.map(\.itemID.stringValue)
                == ["session:42940:1790693400", "session:43037:1790691540", "session:43134:1790694480"])
        #expect(inRex[0].busy && !inRex[2].busy)
        #expect(Set(inRex.map { $0.rex!.sessionId }).count == 2)       // foundry ×2, studio ×1
        #expect(inRex[2].rex?.sessionId == "session:0190aaaa-0000-7000-8000-000000000002")
        #expect(inRex[2].rex?.sessionLabel == "studio")
    }
}

@Suite struct CLIModelTests {
    @Test func listSnapshotJSON() throws {
        let now = Date(timeIntervalSince1970: 1_790_786_000)
        let w = MockWorld.snapshot(now: now)
        let launcher = w.claude.sessions.first(where: \.isLauncher)!
        let snap = ListSnapshot(world: w, protections: [launcher.itemID: .locked(.launcher)], dryRun: true, now: now)
        #expect(snap.items.count == w.chrome.tabs.count + 26)   // 23 sessions + 3 leftovers
        #expect(snap.items.first!.bytes! >= snap.items.last!.bytes ?? 0)
        let data = try HeadroomJSON.encoder().encode(snap)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["schema"] as? Int == 1)
        let items = obj["items"] as! [[String: Any]]
        let l = items.first { $0["id"] as? String == launcher.itemID.stringValue }!
        #expect(l["protection"] as? String == "locked")
        #expect((l["reasons"] as? [[String: String]])?.first?["code"] == "launcher")
        #expect(!items.contains { ($0["incognito"] as? Bool) == true && $0["url"] != nil })
        let tabsOnly = ListSnapshot(world: w, protections: [:], kind: .tabs, dryRun: true, now: now)
        #expect(tabsOnly.items.allSatisfy { $0.kind == "tab" })
    }

    @Test func listItemCarriesRexLocation() throws {
        let now = Date(timeIntervalSince1970: 1_790_786_000)
        let w = MockWorld.snapshot(now: now)
        let snap = ListSnapshot(world: w, protections: [:], kind: .sessions, dryRun: true, now: now)
        let docs = try #require(snap.items.first { $0.title == "rex docs pass" })
        #expect(docs.rex == "foundry:2.1" && docs.tmux == nil)
        let hub = try #require(snap.items.first { $0.title == "map directions" })
        #expect(hub.tmux == "hub:5.0" && hub.rex == nil)
        // `rex` is omitted (not null) when nil, so old consumers see the same keys for tmux rows.
        let items = (try JSONSerialization.jsonObject(with: HeadroomJSON.encoder().encode(snap)) as! [String: Any])["items"]
            as! [[String: Any]]
        let docsJSON = items.first { $0["title"] as? String == "rex docs pass" }!
        #expect(docsJSON["rex"] as? String == "foundry:2.1" && docsJSON["tmux"] == nil)
        #expect(items.first { $0["title"] as? String == "map directions" }!.keys.contains("rex") == false)
    }

    @Test func suggestReport() throws {
        let s = [Suggestion(id: .session(ProcKey(pid: 1, startSec: 2)), verdict: .safe, reason: "idle 6h", bytes: 10),
                 Suggestion(id: .leftover(pgid: 3, leaderStartSec: 4), verdict: .confirm, reason: "leftover", bytes: 5)]
        let r = SuggestReport(generatedAt: Date(), suggestions: s)
        #expect(r.safeBytes == 10)
        #expect(r.closeCommand == "headroom close session:1:2")
        #expect(r.confirmCommand == "headroom close --force-confirm leftover:3:4")
        let json = String(decoding: try HeadroomJSON.encoder().encode(r), as: UTF8.self)
        #expect(json.contains("\"id\" : \"session:1:2\""))
        #expect(json.contains("\"verdict\" : \"safe\""))
    }

    @Test func reasonCodesUnique() {
        let all: [Reason] = [.busy(nil), .recentActivity, .visiblePane, .notInTmux, .hasBackground(1, 1),
                             .noTranscript, .cwdMissing, .unregistered, .audible, .pinned, .emptiesWindow(6),
                             .closesAllWindows, .leftover, .manyItems, .launcher, .pidMismatch, .chromeCore, .childProcess]
        #expect(Set(all.map(\.code)).count == all.count)
    }

    @Test func multiplexerReasonsKeepTheirCodes() {
        // Codes are frozen (docs/cli.md); only the texts now name Rex too.
        #expect(Reason.visiblePane.code == "visiblePane" && Reason.notInTmux.code == "notInTmux")
        #expect(Reason.visiblePane.text == "visible or current tmux pane, or visible Rex pane")
        #expect(Reason.notInTmux.text == "not in tmux or Rex (Undo cannot put it back where it ran)")
        #expect(Reason.notInTmux.text.contains("not in tmux"))
    }
}

@Suite struct EnvTests {
    @Test func seams() {
        let e = HeadroomEnv(environment: [
            "HOME": "/tmp/h", "HEADROOM_DRY_RUN": "1", "HEADROOM_CLAUDE_DIR": "/tmp/c",
            "HEADROOM_TMUX_SOCKET": "headroom-test", "HEADROOM_CLAUDE_VERSIONS_GLOB": "/tmp/*/fake/*",
            "CLAUDE_PID": "123",
        ])
        #expect(e.dryRun && !e.mock)
        #expect(e.sessionsDir == "/tmp/c/sessions")
        #expect(e.supportDir == "/tmp/h/Library/Application Support/Headroom")
        #expect(e.socketPath.hasSuffix("/Headroom/run/app.sock"))
        #expect(e.tmuxBaseArgs == ["-L", "headroom-test"])
        #expect(e.isClaudeBinary(path: "/Users/x/.local/share/claude/versions/2.1.285"))
        #expect(e.isClaudeBinary(path: "/tmp/s/fake/9.9.9"))
        #expect(!e.isClaudeBinary(path: "/bin/sleep"))
        #expect(e.launcherClaudePid == 123)
    }

    @Test func rexSeams() {
        let d = HeadroomEnv(environment: ["HOME": "/nonexistent"])
        #expect(d.rexBaseArgs == ["--autostart=false"])               // never start a server
        #expect(d.rexServer == nil)
        #expect(d.rexPath == "/nonexistent/.local/bin/rex")          // a test HOME never finds the real binary
        let s = HeadroomEnv(environment: ["HOME": "/nonexistent", "HEADROOM_REX_SERVER": "unix:///tmp/hrx/s.sock"])
        #expect(s.rexBaseArgs == ["--autostart=false", "-S", "unix:///tmp/hrx/s.sock"])
        let p = HeadroomEnv(environment: ["HOME": "/nonexistent", "HEADROOM_REX": "/x/rex", "HEADROOM_REX_SERVER": ""])
        #expect(p.rexPath == "/x/rex" && p.rexServer == nil)         // empty = unset, like every other seam
        // The memberwise init resolves a nil rexPath the same way.
        let m = HeadroomEnv(home: "/nonexistent", claudeDir: "/c", supportDir: "/s", tmuxPath: "/t", tmuxSocket: nil,
                            dryRun: true, mock: false, claudeVersionsGlobs: [], launcherClaudePid: nil)
        #expect(m.rexPath == "/nonexistent/.local/bin/rex" && m.rexServer == nil)
    }

    @Test func rexCandidatesOnlyUseApplicationsForTheAccountHome() {
        let home = KnownPaths.accountHome
        #expect(!home.isEmpty)
        let c = KnownPaths.rexCandidates(home: home)
        #expect(c.count == 3)
        #expect(c[0] == home + "/.local/bin/rex")
        #expect(c[1].hasPrefix("/Applications/Rex.app/") && c[2].hasPrefix("/Applications/Rex Beta.app/"))
        #expect(c.allSatisfy { $0.hasSuffix("/rex") })
        #expect(KnownPaths.rexCandidates(home: home + "/").count == 3)            // standardized
        #expect(KnownPaths.rexCandidates(home: "/tmp/h") == ["/tmp/h/.local/bin/rex"])
        #expect(KnownPaths.defaultRexPath(home: "/tmp/h") == "/tmp/h/.local/bin/rex")
        #expect(KnownPaths.rexAppBundleId == "com.superlogical.rex")
    }
}

@Suite struct RexContractTests {
    let placed = RexLoc(blockId: "block:0190aaaa-0000-7000-8000-000000000315", sessionId: "session:0190aaaa-0000-7000-8000-000000000001",
                        sessionLabel: "foundry", windowId: "window:0190aaaa-0000-7000-8000-000000000215",
                        windowLabel: "api reference", windowIndex: 2, paneIndex: 1, visible: true)

    @Test func labels() {
        #expect(placed.label == "foundry:2.1" && placed.placed && placed.sessionName == "foundry")
        #expect(placed.shortBlockId == "000315")
        let unplaced = RexLoc(blockId: "block:x", sessionId: "session:0190aaaa-0000-7000-8000-000000abc123",
                              sessionLabel: "foundry", visible: true)
        #expect(unplaced.label == "foundry:?" && !unplaced.placed)
        let nameless = RexLoc(blockId: "block:x", sessionId: "session:0190aaaa-0000-7000-8000-000000abc123",
                              sessionLabel: "", windowIndex: 3, paneIndex: 2, visible: false)
        #expect(nameless.sessionName == "…abc123" && nameless.label == "…abc123:3.2")
        let halfPlaced = RexLoc(blockId: "block:x", sessionId: "session:s", sessionLabel: "a", windowIndex: 1, visible: false)
        #expect(!halfPlaced.placed && halfPlaced.label == "a:?")
    }

    func session(tmux: TmuxLoc? = nil, rex: RexLoc? = nil) -> ClaudeSession {
        ClaudeSession(key: ProcKey(pid: 10, startSec: 20), sessionId: "s", cwd: "/w", title: "t", project: "w",
                      startedAt: Date(timeIntervalSince1970: 20), tmux: tmux, rex: rex, selfFootprint: 1)
    }

    @Test func helpers() {
        let tmuxVisible = session(tmux: TmuxLoc(paneId: "%1", session: "hub", windowName: "w", windowIndex: 3,
                                                paneIndex: 1, visible: true, current: false))
        #expect(tmuxVisible.inMultiplexer && tmuxVisible.onScreen && tmuxVisible.placeLabel == "hub:3.1")
        let tmuxCurrent = session(tmux: TmuxLoc(paneId: "%1", session: "hub", windowName: "w", windowIndex: 3,
                                                paneIndex: 1, visible: false, current: true))
        #expect(tmuxCurrent.onScreen)
        let tmuxHidden = session(tmux: TmuxLoc(paneId: "%1", session: "hub", windowName: "w", windowIndex: 3, paneIndex: 1))
        #expect(tmuxHidden.inMultiplexer && !tmuxHidden.onScreen)
        let rexVisible = session(rex: placed)
        #expect(rexVisible.inMultiplexer && rexVisible.onScreen && rexVisible.placeLabel == "rex foundry:2.1")
        let rexHidden = session(rex: RexLoc(blockId: "block:x", sessionId: "session:s", sessionLabel: "studio",
                                            windowId: "window:w", windowLabel: "x", windowIndex: 1, paneIndex: 2,
                                            visible: false))
        #expect(rexHidden.inMultiplexer && !rexHidden.onScreen && rexHidden.placeLabel == "rex studio:1.2")
        let neither = session()
        #expect(!neither.inMultiplexer && !neither.onScreen && neither.placeLabel == nil)
        #expect(ClaudeSession.notPlacedLabel == "not in tmux or Rex")
    }

    @Test func sessionWithoutRexKeyStillDecodes() throws {
        let s = session(rex: placed)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        #expect(obj["rex"] != nil)
        #expect((obj["rex"] as? [String: Any])?["label"] == nil)                  // computed, not encoded
        #expect(try JSONDecoder().decode(ClaudeSession.self, from: JSONEncoder().encode(s)).rex == placed)
        obj["rex"] = nil                                                           // as written before Rex support
        let old = try JSONDecoder().decode(ClaudeSession.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.rex == nil && old.sessionId == "s")
        // nil optionals of an unplaced loc are omitted.
        let unplaced = RexLoc(blockId: "block:x", sessionId: "session:s", sessionLabel: "", visible: true)
        let u = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unplaced)) as! [String: Any]
        #expect(Set(u.keys) == ["blockId", "sessionId", "sessionLabel", "visible"])
    }

    @Test func closedRecordRexFields() throws {
        // A closed.jsonl line written before Rex support.
        let line = #"{"batchId":"b1","bytes":367001600,"closedAt":"2026-11-18T09:00:00Z","cwd":"/Users/t/work","id":"r1","itemId":"session:41000:1790690000","kind":"session","sessionId":"c5d50000-0000-4000-8000-000000001000","source":"cli","title":"map directions","tmuxSession":"hub"}"#
        let old = try HeadroomJSON.decoder().decode(ClosedRecord.self, from: Data(line.utf8))
        #expect(old.tmuxSession == "hub" && old.rexSessionId == nil && old.rexSessionLabel == nil && old.restorable)
        let new = ClosedRecord(batchId: "b2", kind: "session", itemId: "session:43134:1790694480",
                               closedAt: Date(timeIntervalSince1970: 1_790_700_000), title: "rex billing spike",
                               bytes: 1, sessionId: "sid", cwd: "/w",
                               rexSessionId: "session:0190aaaa-0000-7000-8000-000000000002", rexSessionLabel: "studio")
        let data = try HeadroomJSON.encoder(pretty: false).encode(new)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""rexSessionId":"session:0190aaaa-0000-7000-8000-000000000002""#))
        #expect(json.contains(#""rexSessionLabel":"studio""#) && !json.contains("tmuxSession"))
        let back = try HeadroomJSON.decoder().decode(ClosedRecord.self, from: data)
        #expect(back == new && back.restorable)
    }
}

@Suite struct PlanFlags {
    @Test func sheetMandatory() {
        let w = WorldSnapshot.empty
        let busy = ClosePlan(items: [PlanItem(id: .session(ProcKey(pid: 1, startSec: 1)), protection: .confirm([.busy(nil)]), bytes: 1)],
                             locked: [], estimate: 1, world: w)
        #expect(busy.needsSheet && busy.sheetMandatory)
        let pinned = ClosePlan(items: [PlanItem(id: .chromeTab(browserPid: 1, tabId: 1), protection: .confirm([.pinned]), bytes: 1)],
                               locked: [], estimate: 1, world: w)
        #expect(pinned.needsSheet && !pinned.sheetMandatory)
        let plain = ClosePlan(items: [PlanItem(id: .chromeTab(browserPid: 1, tabId: 1), protection: .none, bytes: 1)],
                              locked: [], estimate: 1, world: w)
        #expect(!plain.needsSheet)
    }

    @Test func wireOutcomes() throws {
        #expect(Wire.outcome("gone") == .alreadyGone)
        #expect(Wire.outcome("failed:boom") == .failed("boom"))
        let hello = try JSONDecoder().decode(Wire.HostHello.self, from: Data(#"{"t":"host","v":1,"hostPid":5,"browserPid":812,"hostVersion":"1.0.0"}"#.utf8))
        #expect(hello.browserPid == 812)
    }
}

@Suite struct IntegrationContractAdditions {
    @Test func childProcessReasonHasItsOwnCode() throws {
        #expect(Reason.childProcess.code == "childProcess")
        #expect(Reason.childProcess.text == "part of a live session; close the session instead")
        let d = try JSONEncoder().encode(Protection.locked(.childProcess))
        #expect(try JSONDecoder().decode(Protection.self, from: d) == .locked(.childProcess))
    }

    @Test func mockSeamsComeFromTheEnvironment() {
        let e = HeadroomEnv(environment: ["HOME": "/tmp/x", "HEADROOM_MOCK_CHROME": "waiting", "HEADROOM_MOCK_JITTER": "1"])
        #expect(e.mockChrome == "waiting" && e.mockJitter)
        let d = HeadroomEnv(environment: ["HOME": "/tmp/x"])
        #expect(d.mockChrome == nil && !d.mockJitter)
    }

    @Test func helloSwStartIsOptional() throws {
        let old = #"{"t":"hello","v":1,"ext":"x","install":"i","incognitoAllowed":false,"mode":"persistent"}"#
        #expect(try JSONDecoder().decode(Wire.ExtHello.self, from: Data(old.utf8)).swStart == nil)
        let new = #"{"t":"hello","v":1,"ext":"x","install":"i","incognitoAllowed":false,"mode":"persistent","swStart":12.5}"#
        #expect(try JSONDecoder().decode(Wire.ExtHello.self, from: Data(new.utf8)).swStart == 12.5)
    }
}

