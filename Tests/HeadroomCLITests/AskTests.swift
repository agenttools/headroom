// `suggest --ask`: answer parsing, validation against the snapshot, and the claude -p round trip
// through a fake `claude` script (HEADROOM_ASK_CLAUDE). The real claude is never called from tests.
import Foundation
import Testing
@testable import HeadroomCLI
import HeadroomActions
import HeadroomContracts

private let now = Date()
private let w = MockWorld.snapshot(now: now)
private let planner = Planner()
private let prot = planner.protections(w, now: now)
private let list = ListSnapshot(world: w, protections: prot, dryRun: true, now: now)

private func id(_ title: String) -> String { list.items.first { $0.title == title }!.id }

private func validate(_ text: String) throws -> AskResult {
    try AskParser.validate(text, list: list, world: w, protections: prot, plan: { planner.plan($0, $1, now: now) })
}

/// Writes an executable fake `claude` that saves its stdin and args, then prints `body` (or runs `script`).
private func fakeClaude(_ body: String? = nil, script: String? = nil) throws -> (path: String, dir: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-wp6-ask-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try (body ?? "").write(to: dir.appendingPathComponent("answer.txt"), atomically: true, encoding: .utf8)
    let sh = script ?? """
    #!/bin/sh
    printf '%s\\n' "$@" > '\(dir.path)/args.txt'
    cat > '\(dir.path)/prompt.txt'
    cat '\(dir.path)/answer.txt'
    """
    let path = dir.appendingPathComponent("claude").path
    try sh.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return (path, dir)
}

@Suite struct AskParserTests {
    @Test func splitsFencedJSONFromProse() {
        let (j, prose) = AskParser.split("Here you go.\n```json\n{\"suggestions\":[]}\n```\nClose the tabs first.")
        #expect(j == "{\"suggestions\":[]}")
        #expect(prose == "Here you go.\n\nClose the tabs first.")
    }

    @Test func splitsBareJSONWithBracesInStrings() {
        let (j, prose) = AskParser.split("{\"suggestions\":[{\"id\":\"x\",\"reason\":\"a } b \\\" {\"}]}\nThen prose.")
        #expect(j == "{\"suggestions\":[{\"id\":\"x\",\"reason\":\"a } b \\\" {\"}]}")
        #expect(prose == "Then prose.")
    }

    @Test func skipsNonJSONFences() {
        let (j, _) = AskParser.split("```sh\nheadroom close x\n```\n```json\n{\"suggestions\":[]}\n```")
        #expect(j == "{\"suggestions\":[]}")
    }

    @Test func noJSONIsAnError() {
        #expect(throws: CLIError.self) { try validate("I think you should close some tabs.") }
        #expect(throws: CLIError.self) { try validate("```json\n{\"nope\": 1}\n```") }
    }

    @Test func validationEnforcesSnapshotAndPlanner() throws {
        let directions = id("map directions")             // plain idle session → safe allowed
        let tour = id("tour landing")                     // leftover → confirm only
        let launcher = id("ram")                          // launcher → locked
        let inbox = id("Inbox (3) – me@example.com – Mail")  // pinned → confirm only
        let answer = """
        ```json
        {"suggestions":[
          {"id":"\(directions)","verdict":"safe","reason":"idle 30h"},
          {"id":"\(tour)","verdict":"safe","reason":"orphaned dev server"},
          {"id":"\(launcher)","verdict":"safe","reason":"big"},
          {"id":"\(inbox)","verdict":"SAFE"},
          {"id":"tab:812:1","verdict":"safe","reason":"invented"},
          {"id":"garbage","verdict":"safe","reason":"x"},
          {"id":"\(directions)","verdict":"keep","reason":"dup"},
          {"id":"\(id("Q4 plan – Notion"))","verdict":"maybe","reason":"x"},
          {"verdict":"safe"}
        ]}
        ```
        Close map directions first.
        """
        let r = try validate(answer)
        let by = Dictionary(uniqueKeysWithValues: r.suggestions.map { ($0.id.stringValue, $0) })
        #expect(by[directions]?.verdict == .safe)
        #expect(by[directions]?.reason == "idle 30h")
        #expect(by[tour]?.verdict == .confirm)
        #expect(by[launcher]?.verdict == .keep)
        #expect(by[inbox]?.verdict == .confirm)
        #expect(by[inbox]?.reason.hasPrefix("(no reason given)") == true)
        #expect(r.suggestions.count == 4)
        // Bytes and titles come from the snapshot, not from Claude.
        let directionsItem = list.items.first { $0.id == directions }!
        #expect(by[directions]?.bytes == directionsItem.bytes && by[directions]?.title == "map directions")
        #expect(r.prose == "Close map directions first.")
        let warn = r.warnings.joined(separator: "\n")
        for needle in ["tab:812:1", "garbage", "duplicate", "maybe", "without an id", "locked", "safe → confirm"] {
            #expect(warn.contains(needle), "missing warning about \(needle)")
        }
        #expect(SuggestReport(generatedAt: now, source: "claude", suggestions: r.suggestions).closeCommand == "headroom close \(directions)")
    }

    @Test func claudesSafeSetIsReplannedAsOneClose() throws {
        // Claude calls every tab in window 1 "safe" except the pinned/active ones; with the inbox and claude.ai
        // left out the window is not emptied, so all stay safe. Then add a 16-item batch → cap applies.
        let sessions = w.claude.sessions.filter { prot[$0.itemID] == Protection.none }.map(\.itemID.stringValue)
        let tabs = w.chrome.tabs.filter { prot[$0.itemID] == Protection.none && !$0.active }.map(\.itemID.stringValue)
        let all = sessions + tabs
        #expect(all.count > 15)
        let json = "{\"suggestions\":[" + all.map { "{\"id\":\"\($0)\",\"verdict\":\"safe\",\"reason\":\"r\"}" }.joined(separator: ",") + "]}"
        let r = try validate(json)
        #expect(r.suggestions.filter { $0.verdict == .safe }.count == 15)
        #expect(r.warnings.contains { $0.contains("closed together") })
        let safe = Set(r.suggestions.filter { $0.verdict == .safe }.map(\.id))
        #expect(!planner.plan(safe, w, now: now).needsSheet)
    }
}

@Suite(.serialized) struct AskRoundTripTests {
    @Test func fakeClaudeRoundTripJSON() async throws {
        let directions = id("map directions")
        let (path, dir) = try fakeClaude("""
        ```json
        {"suggestions":[{"id":"\(directions)","verdict":"safe","reason":"idle for a day, nothing pending"},
                        {"id":"\(id("tour landing"))","verdict":"confirm","reason":"leftover; cannot undo"}]}
        ```
        Start with map directions.
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (code, report) = try await Harness().json(SuggestReport.self, ["suggest", "--ask", "--json"],
                                                      env: ["HEADROOM_ASK_CLAUDE": path])
        #expect(code == 0)
        #expect(report.source == "claude")
        #expect(report.suggestions.map(\.verdict) == [.safe, .confirm])
        #expect(report.closeCommand == "headroom close \(directions)")
        #expect(report.notes == "Start with map directions.")

        // The prompt carried the snapshot and the rules result, with incognito titles redacted.
        let prompt = try String(contentsOf: dir.appendingPathComponent("prompt.txt"), encoding: .utf8)
        #expect(prompt.contains("SNAPSHOT (headroom list --json)"))
        #expect(prompt.contains("RULES (headroom suggest --json"))
        #expect(prompt.contains(directions))
        #expect(prompt.contains("(incognito tab)"))
        #expect(!prompt.contains("Private tab"))
        #expect(!prompt.contains("example.com/private"))
        // Headless, no tools, no MCP, no saved session.
        let args = try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(args.starts(with: ["-p", "--output-format", "text", "--tools", "", "--strict-mcp-config",
                                   "--no-session-persistence"]))
    }

    @Test func humanOutputShowsNotesChecksAndCommand() async throws {
        let (path, dir) = try fakeClaude("{\"suggestions\":[{\"id\":\"\(id("ram"))\",\"verdict\":\"safe\",\"reason\":\"x\"}]}\nNothing else.")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (code, io) = await Harness().run(["suggest", "--ask"], env: ["HEADROOM_ASK_CLAUDE": path])
        #expect(code == 0)
        #expect(io.stdout.contains("Suggestions (claude -p"))
        #expect(io.stdout.contains("KEEP"))
        #expect(io.stdout.contains("Claude's notes:"))
        #expect(io.stdout.contains("is locked"))
        #expect(!io.stdout.contains("Close the safe ones"))
    }

    @Test func failuresExitOneAndCloseNothing() async throws {
        let h = Harness()
        let before = await h.ctx.world.snapshot()
        // Non-zero exit.
        let (bad, d1) = try fakeClaude(script: "#!/bin/sh\ncat >/dev/null\necho 'auth expired' >&2\nexit 3\n")
        defer { try? FileManager.default.removeItem(at: d1) }
        let r1 = await h.run(["suggest", "--ask"], env: ["HEADROOM_ASK_CLAUDE": bad])
        #expect(r1.code == 1 && r1.io.stderr.contains("exit 3") && r1.io.stderr.contains("auth expired"))
        // Garbage answer.
        let (junk, d2) = try fakeClaude("Sure! Close whatever you like.")
        defer { try? FileManager.default.removeItem(at: d2) }
        let r2 = await h.run(["suggest", "--ask"], env: ["HEADROOM_ASK_CLAUDE": junk])
        #expect(r2.code == 1 && r2.io.stderr.contains("no valid JSON"))
        // Timeout (the fake is our own child; Shell.run stops only it).
        let (slow, d3) = try fakeClaude(script: "#!/bin/sh\nexec /bin/sleep 20\n")
        defer { try? FileManager.default.removeItem(at: d3) }
        let t0 = Date()
        let r3 = await h.run(["suggest", "--ask", "--timeout", "1"], env: ["HEADROOM_ASK_CLAUDE": slow])
        #expect(r3.code == 1 && r3.io.stderr.contains("timed out after 1 s"))
        #expect(Date().timeIntervalSince(t0) < 10)
        // Missing binary.
        let r4 = await h.run(["suggest", "--ask"], env: ["HEADROOM_ASK_CLAUDE": "/nonexistent/claude"])
        #expect(r4.code == 1)
        // Nothing was closed by any of it.
        let after = await h.ctx.world.snapshot()
        #expect(after.chrome.tabs.count == before.chrome.tabs.count)
        #expect(after.claude.sessions.count == before.claude.sessions.count)
        #expect(await h.ctx.executor.recentlyClosed().isEmpty)
    }

    @Test func defaultTimeoutIsNinetySeconds() {
        #expect(SuggestTuning.askTimeout == 90)
        #expect(AskClaude(claudePath: "/x").timeout == 90)
    }
}
