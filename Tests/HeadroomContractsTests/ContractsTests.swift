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
        #expect(w.claude.sessions.count == 20)
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
        #expect(back.claude.sessions.count == 20)
    }
}

@Suite struct CLIModelTests {
    @Test func listSnapshotJSON() throws {
        let now = Date(timeIntervalSince1970: 1_790_786_000)
        let w = MockWorld.snapshot(now: now)
        let launcher = w.claude.sessions.first(where: \.isLauncher)!
        let snap = ListSnapshot(world: w, protections: [launcher.itemID: .locked(.launcher)], dryRun: true, now: now)
        #expect(snap.items.count == w.chrome.tabs.count + 23)
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

