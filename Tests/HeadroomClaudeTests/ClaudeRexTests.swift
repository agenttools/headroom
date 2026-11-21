// Rex in the Claude source: placement from REX_BLOCK when the ppid chain reaches a Rex server before any tmux, Jump
// (server-side focus, Rex.app forward, `do session.select`, a note when that fails) and Undo into Rex. Rex state comes
// from the `rexData` seam and every rex call goes to RexStub (a fake rex that logs its calls). Nothing here reaches
// the user's Rex server, tmux server or desktop.
import Foundation
import Testing
import HeadroomContracts
import HeadroomCore
@testable import HeadroomClaude

/// Records desktop calls; focusRex also notes how many rex calls the stub had answered by then (to check the order).
final class StubOrderDesktop: ClaudeDesktop, @unchecked Sendable {
    let stub: RexStub
    private let lock = NSLock()
    private var _calls: [String] = []
    init(_ stub: RexStub) { self.stub = stub }
    var calls: [String] { lock.withLock { _calls } }
    func focusTerminal(tty: String?) async -> TerminalFocus {
        lock.withLock { _calls.append("focus:\(tty ?? "")") }
        return tty == nil ? .appOnly : .exact
    }
    func noClientAttached(attachCommand: String) async { lock.withLock { _calls.append("noClient:\(attachCommand)") } }
    func focusRex() async {
        let n = stub.calls().count
        lock.withLock { _calls.append("rex:focus@\(n)") }
    }
}

// MARK: - Snapshot: which multiplexer, which block

@Suite struct ClaudeRexSnapshotTests {
    typealias W = ClaudeWorld

    @Test func placesEachClaudeByTheNearestMultiplexer() async throws {
        let w = ClaudeWorld(withRex: true)
        let map = w.assign()
        #expect(Set(map.liveSessions.map(\.pid)) == [301, 302, 303, 304, 306, 307, 308, 309, 310])
        #expect(ClaudeSource.rexNeeded(w.table, map, w.sys, tmuxPanes: w.panes))
        // The sessions discovery inspects first: those the claudes in Rex name (308 and 309 are not in Rex).
        #expect(ClaudeSource.rexSessionsNeeded(w.table, map, w.sys, tmuxPanes: w.panes) == [W.rexS1])
        let snap = await w.source().snapshot(w.table, map, w.sys)
        #expect(w.rexCalls.count == 1)                  // one discovery pass per snapshot
        func s(_ pid: Int32) throws -> ClaudeSession { try #require(snap.sessions.first { $0.key.pid == pid }) }

        // 306: block b1 = tab 2 of "foundry", the active tab of a session an app is attached to → visible.
        let a = try s(306)
        #expect(a.rex?.label == "foundry:2.1" && a.rex?.visible == true && a.rex?.placed == true && a.tmux == nil)
        #expect(a.rex?.blockId == W.rexBlock("b1") && a.rex?.sessionId == W.rexS1 && a.rex?.windowLabel == "api reference")
        #expect(a.inMultiplexer && a.onScreen && a.placeLabel == "rex foundry:2.1")
        // 307: tab 3 is not the session's active tab.
        let b = try s(307)
        #expect(b.rex?.label == "foundry:3.1" && b.rex?.visible == false && b.tmux == nil && !b.onScreen)
        // 310: its REX_BLOCK was not discovered → unplaced, and counted as visible (fail-closed).
        let c = try s(310)
        #expect(c.rex?.label == "foundry:?" && c.rex?.placed == false && c.rex?.visible == true && c.tmux == nil)
        // 308: REX_BLOCK in its env, but reparented to launchd → in neither.
        let d = try s(308)
        #expect(d.rex == nil && d.tmux == nil && !d.inMultiplexer)
        // 309: a tmux pane is nearer than the Rex server → tmux; the inherited REX_BLOCK is ignored.
        let e = try s(309)
        #expect(e.tmux?.label == "nested:1.0" && e.rex == nil)
        // The tmux rows are as without Rex, and no session is in both.
        #expect(try s(301).tmux?.label == "hub:1.0" && (try s(301)).rex == nil)
        #expect(try s(304).tmux == nil && (try s(304)).rex == nil)
        #expect(!snap.sessions.contains { $0.tmux != nil && $0.rex != nil })
    }

    @Test func noRexCallWhenNoClaudeRunsInRex() async {
        let w = ClaudeWorld()
        let map = w.assign()
        #expect(!ClaudeSource.rexNeeded(w.table, map, w.sys, tmuxPanes: w.panes))
        #expect(ClaudeSource.rexSessionsNeeded(w.table, map, w.sys, tmuxPanes: w.panes) == nil)
        let snap = await w.source().snapshot(w.table, map, w.sys)
        #expect(w.rexCalls.count == 0)
        #expect(snap.sessions.allSatisfy { $0.rex == nil })
    }

    @Test func prefetchedStateIsUsedAndFailedDiscoveryFailsClosed() async throws {
        let w = ClaudeWorld(withRex: true)
        let map = w.assign()
        // The caller's state (LiveWorld's cache) is used as is. Here discovery failed (.empty): every claude in Rex
        // is unplaced and counts as visible; the tmux one is unaffected.
        let snap = await w.source().snapshot(w.table, map, w.sys, tmuxState: (w.panes, w.clients), rexState: .empty)
        #expect(w.rexCalls.count == 0)
        for pid: Int32 in [306, 307, 310] {
            let s = try #require(snap.sessions.first { $0.key.pid == pid })
            #expect(s.rex?.placed == false && s.rex?.visible == true && s.rex?.label == "…000001:?" && s.onScreen)
        }
        #expect(snap.sessions.first { $0.key.pid == 309 }?.tmux?.label == "nested:1.0")
    }

    @Test func discoveryInspectsTheClaudesSessionEvenBeyondTheFirst64() async throws {
        // A real discovery pass against RexStub: `ls` lists 65 sessions with the claudes' session last. Only the
        // REX_SESSION the claudes carry gets it inspected (the first 64 alone would leave it out).
        let stub = RexStub(); defer { stub.remove() }
        var w = ClaudeWorld(withRex: true)
        w.env.rexPath = stub.path
        func other(_ n: Int) -> [String: String] {
            ["session_id": String(format: "session:0190ffff-0000-7000-8000-%012d", n), "label": "other \(n)"]
        }
        let refs = (1...64).map(other) + [["session_id": W.rexS1, "label": "foundry"]]
        stub.respond("ls", stdout: TX.json(["sessions": refs]))
        func tab(_ n: Int, _ label: String, _ block: String) -> [String: Any] {
            ["window_id": W.rexWindow(n), "label": label,
             "layers": [["kind": "tiled", "blocks": [["block_id": W.rexBlock(block), "label": "shell"]]]]]
        }
        stub.respond("inspect \(W.rexS1)", stdout: TX.json([
            "session_id": W.rexS1, "label": "foundry", "active_window_id": W.rexWindow(2),
            "windows": [tab(1, "main", "a0"), tab(2, "api reference", "b1"), tab(3, "notes", "b2")],
            "clients": [["client_id": W.rexClient, "info": ["kind": "app"], "principal": ["transport": "unix"],
                         "connection_state": "connected"]]]))
        let src = w.source()
        src.rexData = nil                                   // the real RexClient, against the stub
        let snap = await src.snapshot(w.table, w.assign(), w.sys)
        let a = try #require(snap.sessions.first { $0.key.pid == 306 })
        #expect(a.rex?.label == "foundry:2.1" && a.rex?.placed == true && a.rex?.visible == true)
        #expect(snap.sessions.first { $0.key.pid == 307 }?.rex?.label == "foundry:3.1")
        let inspected = stub.commands().filter { $0.first == "session" }.map { $0[2] }
        #expect(inspected.contains(W.rexS1) && inspected.count == 64)
    }
}

// MARK: - Jump (§7.6) into Rex, against RexStub

@Suite struct ClaudeRexJumpTests {
    typealias W = ClaudeWorld

    struct Setup {
        let src: ClaudeSource
        let stub: RexStub
        let desk: StubOrderDesktop
        let world: ClaudeWorld
        func key(_ pid: Int32) -> ProcKey { world.table.byPid[pid]!.key }
    }

    /// The Rex world with rex pointed at a fresh stub, snapshotted once (which remembers each session's block) unless
    /// `snapshot` is false. `clients` replaces the session's app clients (default: one local, connected).
    func setup(appClient: Bool = true, clients: [RexAppClient]? = nil, snapshot: Bool = true) async -> Setup {
        let stub = RexStub()
        var w = ClaudeWorld(withRex: true)
        w.env.rexPath = stub.path
        if !appClient { w.rexState.appClients = [:] }
        if let clients { w.rexState.appClients = [W.rexS1: clients] }
        let desk = StubOrderDesktop(stub)
        let src = w.source(desktop: desk)
        if snapshot { _ = await src.snapshot(w.table, w.assign(), w.sys) }
        return Setup(src: src, stub: stub, desk: desk, world: w)
    }

    @Test func focusesTheBlockBringsRexForwardThenSelectsItsTab() async throws {
        let x = await setup(); defer { x.stub.remove() }
        #expect(await x.src.jumpNote(x.key(306)) == nil)
        #expect(x.stub.commands() == [["focus", "-s", W.rexS1, W.rexBlock("b1")],
                                      ["do", "session.select", "session_id=\(W.rexS1)", "window_id=\(W.rexWindow(2))"]])
        let select = try #require(x.stub.calls().last)
        #expect(Array(select.prefix(5)) == ["--autostart=false", "--timeout", "5s", "-C", W.rexClient])
        #expect(x.desk.calls == ["rex:focus@1"])       // after `focus`, before `do`
        #expect(x.world.rexCalls.count == 2)            // the snapshot, then fresh state for the jump
    }

    @Test func refusedSelectGivesARemoteControlNote() async {
        let x = await setup(); defer { x.stub.remove() }
        x.stub.respond("do", stdout: "", exit: 1)
        let note = await x.src.jumpNote(x.key(306))
        #expect(note?.contains("Remote Control") == true)
        #expect(note?.contains("“foundry”") == true)
        #expect(x.desk.calls == ["rex:focus@1"])
        // jump(_:) (ClaudeProvider) does the same and drops the note.
        await x.src.jump(x.key(306))
        #expect(x.stub.commands().count == 4)
    }

    @Test func clientNotFoundSaysNotConnectedNotRemoteControl() async throws {
        // Exit 3: the client target was not found (e.g. Rex.app has not connected yet). Remote Control is not the cause.
        let x = await setup(); defer { x.stub.remove() }
        x.stub.respond("do", stdout: "", stderr: "Error: client target default not found: no app client is connected\n",
                       exit: 3)
        let note = try #require(await x.src.jumpNote(x.key(306)))
        #expect(note.contains("“foundry”") && note.contains("not connected") && !note.contains("Remote Control"))
        #expect(note.contains("no app client is connected"))
    }

    @Test func theAppsOwnRefusalIsShown() async throws {
        let x = await setup(); defer { x.stub.remove() }
        let refusal = "Rex.app is not accepting actions. Turn on Remote Control in Rex Settings to allow it."
        x.stub.respond("do", stdout: "", stderr: "Error: \(refusal)\n", exit: 1)
        let note = try #require(await x.src.jumpNote(x.key(306)))
        #expect(note == "If Rex shows another session, open “foundry”. " + refusal)
    }

    @Test func anotherDevicesAppIsNeverAskedToSwitch() async throws {
        // Only a remote (Tailscale, say) app client is connected, before and after Rex.app comes forward: no
        // `do session.select` at all, since without -C rex's default client would be that device.
        let remote = RexAppClient(clientId: "client:0190cccc-0000-7000-8000-0000000000r1", local: false,
                                  connected: true, connectedAt: Date())
        let x = await setup(clients: [remote]); defer { x.stub.remove() }
        let note = try #require(await x.src.jumpNote(x.key(306)))
        #expect(note.contains("open “foundry”") && note.contains("another device"))
        #expect(x.stub.commands() == [["focus", "-s", W.rexS1, W.rexBlock("b1")]])
        #expect(x.desk.calls == ["rex:focus@1"])
        #expect(x.world.rexCalls.count == 3)            // the snapshot, the jump's pass, a re-read after Rex came forward
    }

    @Test func liveFallbackFindsRexWithoutASnapshot() async throws {
        let x = await setup(snapshot: false); defer { x.stub.remove() }
        let sys = x.world.sys
        x.src.liveSys = { sys }
        // 306: the chain reaches the Rex server first → REX_BLOCK b1 → focus, Rex forward, session.select.
        #expect(await x.src.jumpNote(x.key(306)) == nil)
        #expect(x.stub.commands() == [["focus", "-s", W.rexS1, W.rexBlock("b1")],
                                      ["do", "session.select", "session_id=\(W.rexS1)", "window_id=\(W.rexWindow(2))"]])
        #expect(x.desk.calls == ["rex:focus@1"])
        #expect(x.world.rexCalls.count == 1)            // fresh state for the jump only
    }

    @Test func liveFallbackTakesTmuxWhenAPaneIsNearer() async {
        let x = await setup(snapshot: false); defer { x.stub.remove() }
        let sys = x.world.sys
        x.src.liveSys = { sys }
        // 309: tmux pane %5 is nearer than the Rex server; its inherited REX_BLOCK is ignored. tmux is /nonexistent
        // here, so the switch fails: Ghostty forward only, and a note with the reason.
        #expect(await x.src.jumpNote(x.key(309))
            == "tmux could not switch to “nested” (tmux not found at /nonexistent/tmux), so Ghostty was only brought forward.")
        #expect(x.desk.calls.last == "focus:")
        // 308: stale REX_BLOCK under launchd → neither multiplexer → terminal app forward.
        #expect(await x.src.jumpNote(x.key(308)) == nil)
        #expect(x.desk.calls.last == "focus:")
        #expect(x.stub.calls().isEmpty && x.world.rexCalls.count == 0)
    }

    @Test func liveFallbackWithAnUndiscoveredBlockOnlyBringsRexForward() async {
        let x = await setup(snapshot: false); defer { x.stub.remove() }
        let sys = x.world.sys
        x.src.liveSys = { sys }
        let note = await x.src.jumpNote(x.key(310))
        #expect(note?.contains("could not find") == true)
        #expect(x.desk.calls == ["rex:focus@0"] && x.stub.calls().isEmpty && x.world.rexCalls.count == 1)
    }

    @Test func noConnectedAppClientMeansNoDashC() async throws {
        let x = await setup(appClient: false); defer { x.stub.remove() }
        #expect(await x.src.jumpNote(x.key(306)) == nil)
        let select = try #require(x.stub.calls().last)
        #expect(select.contains("session.select") && !select.contains("-C"))
    }

    @Test func undiscoveredBlockOnlyBringsRexForward() async {
        let x = await setup(); defer { x.stub.remove() }
        let note = await x.src.jumpNote(x.key(310))
        #expect(note?.contains("could not find") == true)
        #expect(x.desk.calls == ["rex:focus@0"] && x.stub.calls().isEmpty)
    }

    @Test func sessionsOutsideRexTakeTheTmuxPathAsBefore() async {
        let x = await setup(); defer { x.stub.remove() }
        // 308 (stale REX_BLOCK, under launchd) was placed nowhere and its ProcKey is not live here: the terminal app
        // is brought forward, as for any session outside tmux. The same for a dead ProcKey.
        #expect(await x.src.jumpNote(x.key(308)) == nil)
        #expect(x.desk.calls == ["focus:"])
        await x.src.jump(ProcKey(pid: 999_999, startSec: 1))
        #expect(x.desk.calls == ["focus:", "focus:"])
        // 309 (tmux in Rex) goes to its tmux pane (tmux is /nonexistent here, so the switch fails with a note).
        #expect(await x.src.jumpNote(x.key(309))?.hasPrefix("tmux could not switch to “nested”") == true)
        #expect(x.desk.calls.last == "focus:")
        #expect(x.stub.calls().isEmpty)
    }
}

// MARK: - Undo (§7.7) into Rex, against RexStub

@Suite struct ClaudeRexReopenTests {
    static let s1 = ClaudeWorld.rexS1
    static let s2 = "session:0190cccc-0000-7000-8000-000000000002"
    static let sid = "abcdef01-0000-4000-8000-0000000000aa"
    static let title = "rex \"quoted\" tab"
    static func b(_ n: String) -> String { ClaudeWorld.rexBlock(n) }
    static func w(_ n: Int) -> String { ClaudeWorld.rexWindow(n) }
    static let ls = TX.json(["sessions": [["session_id": s1, "label": "foundry"]]])

    /// `session inspect --json` with one tiled block per tab.
    static func inspect(_ session: String, _ label: String, tabs: [(window: String, label: String, block: String)]) -> String {
        let windows: [[String: Any]] = tabs.map { t in
            ["window_id": t.window, "label": t.label,
             "layers": [["kind": "tiled", "blocks": [["block_id": t.block, "label": "shell"]]]]]
        }
        return TX.json(["session_id": session, "label": label, "active_window_id": tabs.first?.window ?? "",
                        "windows": windows, "clients": [Any]()])
    }
    static let before = inspect(s1, "foundry", tabs: [(w(1), "main", b("a0"))])
    static let withNewTab = inspect(s1, "foundry", tabs: [(w(1), "main", b("a0")), (w(9), title, b("b9"))])

    struct Setup {
        let dir = ScratchDir("rex-undo")
        let stub = RexStub()
        var cwd: String { dir.path + "/proj" }
        init() { dir.mkdir("proj") }
    }

    func env(_ x: Setup, rex: String, dryRun: Bool = false) -> HeadroomEnv {
        var e = ["HOME": x.dir.path, "HEADROOM_CLAUDE_DIR": x.dir.path + "/.claude",
                 "HEADROOM_SUPPORT_DIR": x.dir.path + "/support", "HEADROOM_TMUX": "/nonexistent/tmux", "HEADROOM_REX": rex]
        if dryRun { e["HEADROOM_DRY_RUN"] = "1" }
        return HeadroomEnv(environment: e)
    }

    static let localApp = RexAppClient(clientId: ClaudeWorld.rexClient, local: true, connected: true, connectedAt: nil)

    /// A source over `rex` (the stub, or a wrapper around it). Fresh state for `do session.select` comes from the seam:
    /// `clients` (default: one local, connected app client).
    func source(_ x: Setup, rex: String? = nil, desk: any ClaudeDesktop, dryRun: Bool = false,
                clients: [RexAppClient] = [localApp]) -> ClaudeSource {
        let src = ClaudeSource(env: env(x, rex: rex ?? x.stub.path, dryRun: dryRun), desktop: desk, watch: false)
        let st = RexState(reachable: true, complete: true, sessions: [], blocks: [], appClients: [Self.s1: clients])
        src.rexData = { st }
        return src
    }

    func record(_ cwd: String, rexId: String? = s1, rexLabel: String? = "foundry", tmux: String? = nil) -> ClosedRecord {
        ClosedRecord(batchId: "b", kind: "session", itemId: "session:1:1", closedAt: Date(), title: Self.title, bytes: 1,
                     sessionId: Self.sid, cwd: cwd, tmuxSession: tmux, rexSessionId: rexId, rexSessionLabel: rexLabel)
    }

    func newTab(_ x: Setup, in session: String = s1, block: String = b("b9")) -> [[String]] {
        [["window", "new", "-s", session, Self.title, "-c", x.cwd, "--focus=false", "--json"],
         ["send", "-s", session, "-b", block, "claude --resume \(Self.sid)"],
         ["send-key", "-s", session, "-b", block, "enter"]]
    }

    /// A wrapper around the stub: a call with an argument matching the shell pattern `trigger` first replaces the
    /// stub's answer for `route`, so that route answers differently before and after that call.
    func swapping(_ x: Setup, trigger: String, route: String, stdout: String, exit: Int32 = 0) -> String {
        let d = x.stub.dir
        let file = String(route.map { " :/".contains($0) ? "_" : $0 })
        let fm = FileManager.default
        fm.createFile(atPath: d + "/swap.out", contents: Data(stdout.utf8))
        fm.createFile(atPath: d + "/swap.code", contents: Data("\(exit)".utf8))
        let script = """
        #!/bin/sh
        for a in "$@"; do
          case "$a" in \(trigger)) cp '\(d)/swap.out' '\(d)/resp/\(file).out'; cp '\(d)/swap.code' '\(d)/resp/\(file).code' ;; esac
        done
        exec '\(x.stub.path)' "$@"

        """
        fm.createFile(atPath: d + "/rex-swap", contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        return d + "/rex-swap"
    }

    @Test func recordedSessionGetsANewTabWithTheResumeCommand() async {
        let x = Setup(); defer { x.stub.remove() }
        x.stub.respond("ls", stdout: Self.ls)
        x.stub.respond("inspect \(Self.s1)", stdout: Self.before)
        x.stub.respond("window-new", stdout: TX.json(["window_id": Self.w(9), "block_ids": [Self.b("b9")], "revision": 2]))
        let desk = StubOrderDesktop(x.stub)
        let r = record(x.cwd)
        let src = source(x, desk: desk)
        #expect(await src.reopen([r])[r] == .done)
        #expect(x.stub.commands() == [["ls", "--json"], ["session", "inspect", Self.s1, "--json"]] + newTab(x))
        #expect(x.stub.calls()[2].prefix(3) == ["--autostart=false", "--timeout", "10s"])
        #expect(desk.calls.isEmpty)                     // an existing session: what Rex shows is left alone
        #expect(src.lastReopenNotes.isEmpty)
    }

    @Test func unknownIdFallsBackToTheLabel() async {
        let x = Setup(); defer { x.stub.remove() }
        x.stub.respond("ls", stdout: Self.ls)
        x.stub.respond("inspect \(Self.s1)", stdout: Self.before)
        x.stub.respond("window-new", stdout: TX.json(["window_id": Self.w(9), "block_ids": [Self.b("b9")], "revision": 2]))
        let r = record(x.cwd, rexId: "session:0190cccc-0000-7000-8000-0000000000ff", rexLabel: "foundry")
        #expect(await source(x, desk: StubOrderDesktop(x.stub)).reopen([r])[r] == .done)
        #expect(x.stub.commands().dropFirst(2).first == newTab(x)[0])
    }

    @Test func goneSessionIsCreatedThenShown() async throws {
        let x = Setup(); defer { x.stub.remove() }
        x.stub.respond("ls", stdout: Self.ls)
        x.stub.respond("new", stdout: TX.json(["session_id": Self.s2, "initial_windows": [
            ["window_id": Self.w(5), "block_ids": [Self.b("b5")], "revision": 1]]]))
        let desk = StubOrderDesktop(x.stub)
        let r = record(x.cwd, rexId: Self.s2, rexLabel: "studio")
        let src = source(x, desk: desk)
        #expect(await src.reopen([r])[r] == .done)
        #expect(x.stub.commands() == [
            ["ls", "--json"],
            ["new", "studio", "-c", x.cwd, "--window=\(Self.title)", "--json"],
            ["send", "-s", Self.s2, "-b", Self.b("b5"), "claude --resume \(Self.sid)"],
            ["send-key", "-s", Self.s2, "-b", Self.b("b5"), "enter"],
            ["do", "session.select", "session_id=\(Self.s2)", "window_id=\(Self.w(5))"]])
        #expect(desk.calls == ["rex:focus@4"])          // Rex forward before the client action
        let select = try #require(x.stub.calls().last)
        #expect(select.contains("-C") && select.contains(ClaudeWorld.rexClient))
        #expect(src.lastReopenNotes.isEmpty)            // Rex.app switched: nothing to say
    }

    /// `ls`, and `new` creating "studio" (s2) with block b5.
    func goneStudio(_ x: Setup) {
        x.stub.respond("ls", stdout: Self.ls)
        x.stub.respond("new", stdout: TX.json(["session_id": Self.s2, "initial_windows": [
            ["window_id": Self.w(5), "block_ids": [Self.b("b5")], "revision": 1]]]))
    }

    @Test func createdSessionThatRexCannotShowIsDoneWithANote() async throws {
        // Remote Control off (the default): the session is resumed (.done), and a note says where.
        let x = Setup(); defer { x.stub.remove() }
        goneStudio(x)
        x.stub.respond("do", stdout: "", exit: 1)
        let desk = StubOrderDesktop(x.stub)
        let r = record(x.cwd, rexId: Self.s2, rexLabel: "studio")
        let src = source(x, desk: desk)
        #expect(await src.reopen([r])[r] == .done)
        #expect(x.stub.commands().last == ["do", "session.select", "session_id=\(Self.s2)", "window_id=\(Self.w(5))"])
        #expect(desk.calls == ["rex:focus@4"])
        #expect(src.lastReopenNotes == ["Resumed in the new Rex session “studio”; open it in Rex. "
                                        + "Turn on Remote Control in Rex so Undo can switch sessions."])
        // The next reopen replaces the notes: an existing session needs no switch.
        x.stub.respond("inspect \(Self.s1)", stdout: Self.before)
        x.stub.respond("window-new", stdout: TX.json(["window_id": Self.w(9), "block_ids": [Self.b("b9")], "revision": 2]))
        let again = record(x.cwd)
        #expect(await src.reopen([again])[again] == .done)
        #expect(src.lastReopenNotes.isEmpty)
    }

    @Test func createdSessionNoteSaysWhyWhenRexSaysWhy() async throws {
        let x = Setup(); defer { x.stub.remove() }
        goneStudio(x)
        x.stub.respond("do", stdout: "", stderr: "Error: client target default not found: no app client is connected\n",
                       exit: 3)
        let r = record(x.cwd, rexId: Self.s2, rexLabel: "studio")
        let src = source(x, desk: StubOrderDesktop(x.stub))
        #expect(await src.reopen([r])[r] == .done)
        let note = try #require(src.lastReopenNotes.first)
        #expect(src.lastReopenNotes.count == 1)
        #expect(note.contains("“studio”") && note.contains("not connected") && !note.contains("Remote Control"))
    }

    @Test func createdSessionIsNotSelectedOnAnotherDevice() async throws {
        // Only another device's app is connected: no `do session.select` (rex's default client would be that device).
        let x = Setup(); defer { x.stub.remove() }
        goneStudio(x)
        let remote = RexAppClient(clientId: "client:0190cccc-0000-7000-8000-0000000000r1", local: false,
                                  connected: true, connectedAt: nil)
        let desk = StubOrderDesktop(x.stub)
        let r = record(x.cwd, rexId: Self.s2, rexLabel: "studio")
        let src = source(x, desk: desk, clients: [remote])
        #expect(await src.reopen([r])[r] == .done)
        #expect(!x.stub.commands().contains { $0.first == "do" })
        #expect(x.stub.commands().count == 4 && desk.calls == ["rex:focus@4"])
        let note = try #require(src.lastReopenNotes.first)
        #expect(note.contains("“studio”") && note.contains("another device"))
    }

    @Test func recordInNeitherUsesRexWhenOnlyRexIsInstalled() async {
        let x = Setup(); defer { x.stub.remove() }
        x.stub.respond("ls", stdout: Self.ls)
        x.stub.respond("new", stdout: TX.json(["session_id": Self.s2, "initial_windows": [
            ["window_id": Self.w(5), "block_ids": [Self.b("b5")], "revision": 1]]]))
        let r = record(x.cwd, rexId: nil, rexLabel: nil)
        #expect(await source(x, desk: StubOrderDesktop(x.stub)).reopen([r])[r] == .done)
        #expect(x.stub.commands().dropFirst().first == ["new", "headroom", "-c", x.cwd, "--window=\(Self.title)", "--json"])
    }

    @Test func refusalsAndRexDown() async {
        let x = Setup(); defer { x.stub.remove() }
        let desk = StubOrderDesktop(x.stub)
        // Dry run: nothing runs.
        let r = record(x.cwd)
        #expect(await source(x, desk: desk, dryRun: true).reopen([r])[r] == .dryRun)
        #expect(x.stub.calls().isEmpty)
        // A tmux record stays with tmux (missing here) and never runs rex.
        let t = record(x.cwd, rexId: nil, rexLabel: nil, tmux: "hub")
        #expect(await source(x, desk: desk).reopen([t])[t] == .failed("tmux could not open a window in hub"))
        #expect(x.stub.calls().isEmpty)
        // rex missing.
        let missing = source(x, rex: "/nonexistent/rex", desk: desk)
        #expect(await missing.reopen([r])[r] == .failed("rex is not installed (/nonexistent/rex)"))
        // No server (rex exits 4): fails, never starts one.
        x.stub.respond("ls", stdout: "", exit: 4)
        #expect(await source(x, desk: desk).reopen([r])[r] == .failed("Rex is not running (open Rex, then Undo again)"))
        #expect(x.stub.commands() == [["ls", "--json"]])
        #expect(x.stub.calls()[0].first == "--autostart=false")
        #expect(desk.calls.isEmpty)
    }

    @Test func timedOutNewTabIsAdoptedNotOpenedTwice() async {
        let x = Setup(); defer { x.stub.remove() }
        x.stub.respond("ls", stdout: Self.ls)
        x.stub.respond("inspect \(Self.s1)", stdout: Self.before)
        x.stub.respond("window-new", stdout: "", exit: 4)       // the call failed, but the tab was made
        let rex = swapping(x, trigger: "--focus=false", route: "inspect \(Self.s1)", stdout: Self.withNewTab)
        let r = record(x.cwd)
        #expect(await source(x, rex: rex, desk: StubOrderDesktop(x.stub)).reopen([r])[r] == .done)
        let t = newTab(x)
        #expect(x.stub.commands() == [["ls", "--json"], ["session", "inspect", Self.s1, "--json"], t[0],
                                      ["session", "inspect", Self.s1, "--json"], t[1], t[2]])
    }

    @Test func failedNewTabIsNotRecoveredWithoutAKnownBefore() async {
        let x = Setup(); defer { x.stub.remove() }
        x.stub.respond("ls", stdout: Self.ls)
        x.stub.respond("inspect \(Self.s1)", stdout: "", exit: 3)
        x.stub.respond("window-new", stdout: "", exit: 4)
        // A tab with the same name shows up afterwards, but it could be an older one: never adopted.
        let rex = swapping(x, trigger: "--focus=false", route: "inspect \(Self.s1)", stdout: Self.withNewTab)
        let r = record(x.cwd)
        #expect(await source(x, rex: rex, desk: StubOrderDesktop(x.stub)).reopen([r])[r]
                == .failed("Rex could not open a tab in “foundry”"))
        #expect(x.stub.commands() == [["ls", "--json"], ["session", "inspect", Self.s1, "--json"], newTab(x)[0]])
    }

    @Test func timedOutNewSessionIsAdopted() async {
        let x = Setup(); defer { x.stub.remove() }
        x.stub.respond("ls", stdout: Self.ls)
        x.stub.respond("new", stdout: "", exit: 4)
        x.stub.respond("inspect \(Self.s2)", stdout: Self.inspect(Self.s2, "studio", tabs: [(Self.w(5), Self.title, Self.b("b5"))]))
        let after = TX.json(["sessions": [["session_id": Self.s1, "label": "foundry"], ["session_id": Self.s2, "label": "studio"]]])
        let rex = swapping(x, trigger: "--window=*", route: "ls", stdout: after)
        let desk = StubOrderDesktop(x.stub)
        let r = record(x.cwd, rexId: Self.s2, rexLabel: "studio")
        #expect(await source(x, rex: rex, desk: desk).reopen([r])[r] == .done)
        #expect(x.stub.commands() == [
            ["ls", "--json"],
            ["new", "studio", "-c", x.cwd, "--window=\(Self.title)", "--json"],
            ["ls", "--json"],
            ["session", "inspect", Self.s2, "--json"],
            ["send", "-s", Self.s2, "-b", Self.b("b5"), "claude --resume \(Self.sid)"],
            ["send-key", "-s", Self.s2, "-b", Self.b("b5"), "enter"],
            ["do", "session.select", "session_id=\(Self.s2)", "window_id=\(Self.w(5))"]])
        #expect(desk.calls == ["rex:focus@6"])
    }
}

// MARK: - selftest claude: the `rex` check

@Suite struct ClaudeRexSelfTestCheckTests {
    static let info = RexServerInfo(pid: 4242, version: "0.1.0-preview.20", apiRevision: 16)
    static let complete = RexState(reachable: true, complete: true, sessions: [], blocks: [], appClients: [:])
    static let incomplete = RexState(reachable: true, complete: false, sessions: [], blocks: [], appClients: [:])

    /// The Rex world's sessions (306 and 307 placed, 310 unplaced; 308, 309 and the tmux ones not in Rex).
    func sessions() async -> [ClaudeSession] {
        let w = ClaudeWorld(withRex: true)
        return await w.source().snapshot(w.table, w.assign(), w.sys).sessions
    }

    @Test func noClaudeInRexNeverFailsOnDiscovery() async {
        // A Rex server runs (a private one, say, or Rex.app with no claude in it), but the personal server cannot be
        // read: rex missing, not answering, or more than 64 sessions. The snapshot made no rex call, so discovery is
        // printed for information and the check passes.
        let outside = await sessions().filter { $0.rex == nil }
        for st in [RexState.empty, Self.incomplete] {
            let c = ClaudeSelfTest.rexCheck(sessions: outside, inRex: [], state: st, who: nil, rexFound: false,
                                            rexPath: "/nonexistent/rex")
            #expect(c.passed, "\(c.detail)")
            #expect(c.detail.contains("information only: no claude in Rex"))
            #expect(c.detail.contains("rex not found at /nonexistent/rex"))
            #expect(c.detail.contains("reachable \(st.reachable), complete \(st.complete)"))
        }
    }

    @Test func aClaudeInRexNeedsCompleteDiscoveryAndAPlace() async throws {
        let all = await sessions()
        let placed = all.filter { $0.rex?.placed == true }
        #expect(Set(placed.map(\.key.pid)) == [306, 307])
        let ok = ClaudeSelfTest.rexCheck(sessions: placed, inRex: placed, state: Self.complete, who: Self.info,
                                         rexFound: true, rexPath: "/x/rex")
        #expect(ok.passed, "\(ok.detail)")
        #expect(ok.detail.hasPrefix("server 0.1.0-preview.20 api 16 pid 4242;"))
        #expect(!ok.detail.contains("information only") && !ok.detail.contains("not found"))
        #expect(ok.detail.contains("2 claudes in Rex, 2 placed, 1 visible"))
        // Discovery failed or was cut short while a claude runs in Rex: fails.
        for st in [RexState.empty, Self.incomplete] {
            #expect(!ClaudeSelfTest.rexCheck(sessions: placed, inRex: placed, state: st, who: nil, rexFound: true,
                                             rexPath: "/x/rex").passed)
        }
        // An unplaced claude (310) fails even when discovery is complete.
        let unplaced = try #require(all.first { $0.key.pid == 310 })
        let u = ClaudeSelfTest.rexCheck(sessions: placed + [unplaced], inRex: placed + [unplaced],
                                        state: Self.complete, who: Self.info, rexFound: true, rexPath: "/x/rex")
        #expect(!u.passed && u.detail.contains("in Rex but not placed: [310]"))
        // A claude in Rex without a Rex location (no REX_BLOCK/REX_SESSION) fails too.
        let bare = try #require(all.first { $0.key.pid == 308 })
        let n = ClaudeSelfTest.rexCheck(sessions: [bare], inRex: [bare], state: Self.complete, who: Self.info,
                                        rexFound: true, rexPath: "/x/rex")
        #expect(!n.passed && n.detail.contains("in Rex without REX_BLOCK/REX_SESSION: [308]"))
    }
}
