// CLI tests. Shared harness + argument parsing, id codec and `list` tests.
import Foundation
import Testing
@testable import HeadroomCLI
import HeadroomActions
import HeadroomContracts

/// Runs the CLI in-process against one shared mock context (so close → undo can be observed).
struct Harness {
    static let baseEnv = ["HOME": "/nonexistent", "HEADROOM_DRY_RUN": "1", "PATH": "/usr/bin:/bin"]
    let ctx: HeadroomContext
    init() { ctx = Headroom.mock(env: HeadroomEnv(environment: Self.baseEnv)) }

    func run(_ args: [String], tty: Bool = false, answers: [String] = [],
             env extra: [String: String] = [:]) async -> (code: Int32, io: CaptureIO) {
        let io = CaptureIO(tty: tty, answers: answers)
        let ctx = self.ctx
        let code = await HeadroomCLI.run(["--mock"] + args, io: io,
                                         environment: Self.baseEnv.merging(extra) { $1 },
                                         makeContext: { _ in ctx })
        return (code, io)
    }

    func json<T: Decodable>(_ type: T.Type, _ args: [String], env: [String: String] = [:]) async throws -> (Int32, T) {
        let (code, io) = await run(args, env: env)
        return (code, try HeadroomJSON.decoder().decode(T.self, from: Data(io.stdout.utf8)))
    }
}

@Suite struct ArgsTests {
    @Test func flagsOptionsAndPositionals() throws {
        let p = try ParsedArgs.parse(["a", "--json", "--kind", "tabs", "--min-mb=300", "-y", "--", "--x"],
                                     flags: ["json", "yes"], options: ["kind", "min-mb"], short: ["-y": "yes"])
        #expect(p.flags == ["json", "yes"])
        #expect(p.options == ["kind": "tabs", "min-mb": "300"])
        #expect(p.positionals == ["a", "--x"])
    }

    @Test func unknownOptionMissingValueAndValueOnFlagAreErrors() {
        #expect(throws: CLIError.self) { try ParsedArgs.parse(["--bogus"], flags: []) }
        #expect(throws: CLIError.self) { try ParsedArgs.parse(["--kind"], flags: [], options: ["kind"]) }
        #expect(throws: CLIError.self) { try ParsedArgs.parse(["--json=1"], flags: ["json"]) }
        #expect(throws: CLIError.self) { try ParsedArgs.parse(["-z"], flags: []) }
    }

    @Test func unknownCommandAndBadKindExitOne() async {
        let h = Harness()
        #expect(await h.run(["frobnicate"]).code == 1)
        #expect(await h.run(["list", "--kind", "bogus"]).code == 1)
        #expect(await h.run(["list", "--nope"]).code == 1)
        #expect(await h.run([]).code == 1)
        #expect(await h.run(["--help"]).code == 0)
    }
}

@Suite struct IDCodecTests {
    @Test func everyKindRoundTrips() {
        let ids: [ItemID] = [
            .chromeTab(browserPid: 812, tabId: 1_101_007), .chromeWindow(browserPid: 812, windowId: 1_100_001),
            .chromeOverhead(browserPid: 812, kind: "gpu"), .session(ProcKey(pid: 41000, startSec: 1_790_694_600)),
            .leftover(pgid: 7164, leaderStartSec: 1_790_613_600), .process(ProcKey(pid: 85291, startSec: 1_790_694_720)),
        ]
        for id in ids {
            #expect(ItemID(string: id.stringValue) == id)
            #expect(ItemID(id.description) == id)
        }
        #expect(ids.map(\.stringValue) == ["tab:812:1101007", "window:812:1100001", "overhead:812:gpu",
                                           "session:41000:1790694600", "leftover:7164:1790613600", "proc:85291:1790694720"])
    }

    @Test func malformedStringsAreRejected() {
        for s in ["", "tab", "tab:812", "tab:812:", "tab:x:1", "tab:812:1:2", "session:41000:abc", "overhead:812:bogus",
                  "Tab:812:1", "pid:1:2", " tab:812:1", "leftover::1"] {
            #expect(ItemID(string: s) == nil, "\(s) should not parse")
        }
    }

    @Test func listJSONIdsAreUniqueAndParse() async throws {
        let (code, snap) = try await Harness().json(ListSnapshot.self, ["list", "--json"])
        #expect(code == 0)
        #expect(snap.items.count == 41)                 // 15 tabs + 23 sessions (3 in Rex) + 3 leftovers
        #expect(Set(snap.items.map(\.id)).count == snap.items.count)
        for item in snap.items {
            let id = try #require(ItemID(string: item.id))
            #expect(id.kind.rawValue == item.kind)
        }
    }

    @Test func closeRejectsMalformedIdWithExitOne() async {
        let (code, io) = await Harness().run(["close", "tab:812"])
        #expect(code == 1)
        #expect(io.stderr.contains("not a Headroom id"))
    }
}

@Suite struct ListTests {
    @Test func humanTableHasSectionsAndIds() async {
        let (code, io) = await Harness().run(["list"])
        #expect(code == 0)
        let out = io.stdout
        #expect(out.contains("CHROME TABS"))
        #expect(out.contains("CLAUDE SESSIONS"))
        #expect(out.contains("LEFTOVERS"))
        #expect(out.contains("MOCK"))
        #expect(out.contains("leftover:7164:"))
        #expect(out.contains("hub:5.0"))                 // map directions' tmux location
        #expect(!out.contains("example.com/private"))    // incognito URL never printed
    }

    /// Rex sessions carry `rex` ("session:tab.pane"); `tmux` stays tmux-only and both are omitted when nil.
    @Test func rexSessionsInListJSON() async throws {
        let (code, snap) = try await Harness().json(ListSnapshot.self, ["list", "--json", "--kind", "sessions"])
        #expect(code == 0)
        let by = Dictionary(uniqueKeysWithValues: snap.items.map { ($0.id, $0) })
        let docs = try #require(by["session:43037:1790691540"])           // rex docs pass (visible)
        #expect(docs.rex == "foundry:2.1" && docs.tmux == nil)
        #expect(docs.reasons.map(\.code) == ["visiblePane"])
        let spike = try #require(by["session:43134:1790694480"])          // rex billing spike (hidden tab)
        #expect(spike.rex == "studio:1.1" && spike.tmux == nil)
        #expect(spike.protection == "none" && spike.reasons.isEmpty)
        let notes = try #require(by["session:42940:1790693400"])          // rex release notes (busy)
        #expect(notes.rex == "foundry:1.1" && notes.reasons.map(\.code) == ["busy"])
        #expect(snap.items.filter { $0.rex != nil }.count == 3)
        #expect(!snap.items.contains { $0.rex != nil && $0.tmux != nil })
        #expect(!snap.items.contains { $0.reasons.contains { $0.code == "notInTmux" } && $0.rex != nil })
        // tmux rows unchanged.
        let directions = try #require(snap.items.first { $0.title == "map directions" })
        #expect(directions.tmux == "hub:5.0" && directions.rex == nil && directions.reasons.isEmpty)
        let draft = try #require(snap.items.first { $0.title == "newsletter draft" })
        #expect(draft.tmux == nil && draft.rex == nil && draft.reasons.map(\.code) == ["notInTmux"])
        #expect(draft.reasons[0].text.contains("not in tmux"))

        // Raw JSON: the key is "rex", and a nil location is omitted rather than null.
        let (_, io) = await Harness().run(["list", "--json", "--kind", "sessions"])
        let root = try #require(try JSONSerialization.jsonObject(with: Data(io.stdout.utf8)) as? [String: Any])
        let raw = try #require(root["items"] as? [[String: Any]])
        let rawDocs = try #require(raw.first { $0["id"] as? String == "session:43037:1790691540" })
        #expect(rawDocs["rex"] as? String == "foundry:2.1" && rawDocs["tmux"] == nil)
        let rawDirections = try #require(raw.first { $0["title"] as? String == "map directions" })
        #expect(rawDirections["tmux"] as? String == "hub:5.0" && rawDirections["rex"] == nil)
    }

    @Test func humanTableShowsRexAndNeither() async {
        let (code, io) = await Harness().run(["list", "--kind", "sessions"])
        #expect(code == 0)
        let lines = io.stdout.split(separator: "\n").map(String.init)
        let docs = lines.first { $0.contains("session:43037:1790691540") } ?? ""
        #expect(docs.contains("rex foundry:2.1  /Users/jappleseed/work/foundry"))
        #expect(docs.hasSuffix("(visiblePane)"))
        let draft = lines.first { $0.contains("newsletter draft") } ?? ""
        #expect(draft.contains("not in tmux or Rex  "))
        #expect(draft.hasSuffix("(notInTmux)"))
        #expect(io.stdout.contains("rex studio:1.1"))
        let directions = lines.first { $0.contains("map directions") } ?? ""
        #expect(directions.contains(" hub:5.0  /Users/jappleseed/work"))
    }

    @Test func kindFilterLimitsJSONAndTable() async throws {
        let (_, snap) = try await Harness().json(ListSnapshot.self, ["list", "--json", "--kind", "leftovers"])
        #expect(snap.items.map(\.kind) == ["leftover", "leftover", "leftover"])
        let (_, io) = await Harness().run(["list", "--kind", "tabs"])
        #expect(io.stdout.contains("CHROME TABS") && !io.stdout.contains("CLAUDE SESSIONS"))
    }
}
