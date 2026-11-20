// Rex in the actions layer: planner protection (never close what the user is looking at; an unplaced Rex pane is
// protected), the close-time re-check, presets, filter, list grouping, the Signaller's Rex rules, closed records,
// mock Peek, the Rex state cache and LiveExecutor's Rex Peek / Jump wiring.
// Mock data and synthetic process tables only; every rex call goes to RexStub (never the user's Rex server).
import Darwin
import Foundation
import Testing
import HeadroomContracts
import HeadroomCore
import HeadroomClaude
import HeadroomChrome
@testable import HeadroomActions

private let now = Date()
private let world = MockWorld.snapshot(now: now)
private let planner = Planner()
private let foundryId = "session:0190aaaa-0000-7000-8000-000000000001"
private let studioId = "session:0190aaaa-0000-7000-8000-000000000002"

private func session(_ title: String) -> ClaudeSession { world.claude.sessions.first { $0.title == title }! }
private func codes(_ p: Protection?) -> Set<String> { Set((p?.reasons ?? []).map(\.code)) }

/// The same session placed elsewhere (tmux, Rex or neither); every other field is kept.
private func relocated(_ s: ClaudeSession, tmux: TmuxLoc? = nil, rex: RexLoc? = nil) -> ClaudeSession {
    ClaudeSession(key: s.key, sessionId: s.sessionId, cwd: s.cwd, title: s.title, project: s.project,
                  worktree: s.worktree, branch: s.branch, cwdExists: s.cwdExists, hasTranscript: s.hasTranscript,
                  busy: s.busy, remoteControl: s.remoteControl, isLauncher: s.isLauncher, unregistered: s.unregistered,
                  status: s.status, statusSince: s.statusSince, lastActivity: s.lastActivity, startedAt: s.startedAt,
                  cpuPercent: s.cpuPercent, lastPrompt: s.lastPrompt, lastAssistant: s.lastAssistant,
                  awaySummary: s.awaySummary, tmux: tmux, rex: rex, kind: s.kind, version: s.version,
                  selfFootprint: s.selfFootprint, selfRSS: s.selfRSS, children: s.children, background: s.background)
}

private func rexLoc(placed: Bool = true, visible: Bool, label: String = "foundry",
                    sessionId: String = foundryId) -> RexLoc {
    placed
        ? RexLoc(blockId: "block:0190cccc-0000-7000-8000-0000000000b1", sessionId: sessionId, sessionLabel: label,
                 windowId: "window:0190cccc-0000-7000-8000-0000000000a3", windowLabel: "spare tab", windowIndex: 3,
                 paneIndex: 2, visible: visible)
        : RexLoc(blockId: "block:0190cccc-0000-7000-8000-0000000000b1", sessionId: sessionId, sessionLabel: label,
                 visible: visible)
}

private func worldWith(_ sessions: [ClaudeSession]) -> WorldSnapshot {
    var c = world.claude
    c.sessions = sessions
    return WorldSnapshot(system: world.system, chrome: world.chrome, claude: c, ownership: world.ownership,
                         selfBytes: 0, at: now)
}

private func tempDir(_ tag: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("hr-\(tag)-\(UUID().uuidString)").path
}

// MARK: - Planner (§7.3)

@Suite struct RexPlanner {
    let prot = planner.protections(world, now: now)

    @Test func mockRexRows() {
        #expect(codes(prot[session("rex docs pass").itemID]) == ["visiblePane"])
        #expect(prot[session("rex billing spike").itemID] == Protection.none)
        #expect(codes(prot[session("rex release notes").itemID]).contains("busy"))
        for s in world.claude.sessions where s.rex != nil {
            #expect(!codes(prot[s.itemID]).contains("notInTmux"), "\(s.title)")
        }
        // tmux rows keep their reasons.
        #expect(codes(prot[session("weekly update skill").itemID]).isSuperset(of: ["visiblePane", "hasBackground"]))
        #expect(codes(prot[session("newsletter draft").itemID]) == ["notInTmux"])
        #expect(prot[session("map directions").itemID] == Protection.none)
    }

    /// The same idle, unprotected session ("map directions", in tmux) moved around.
    @Test func placementDecidesVisiblePaneAndNotInTmux() {
        let base = session("map directions")
        func p(_ s: ClaudeSession) -> Set<String> { codes(planner.sessionProtection(s, now: now)) }
        #expect(p(base).isEmpty)
        // Rex: placed and hidden → nothing; placed and visible → visiblePane; place unknown → visiblePane (fail-closed).
        #expect(p(relocated(base, rex: rexLoc(visible: false))).isEmpty)
        #expect(p(relocated(base, rex: rexLoc(visible: true))) == ["visiblePane"])
        #expect(p(relocated(base, rex: rexLoc(placed: false, visible: true))) == ["visiblePane"])
        // Neither multiplexer → notInTmux (Undo cannot put it back where it ran).
        #expect(p(relocated(base)) == ["notInTmux"])
        // tmux unchanged: visible or current alone protects.
        let t = base.tmux!
        func tm(visible: Bool, current: Bool) -> TmuxLoc {
            TmuxLoc(paneId: t.paneId, session: t.session, windowName: t.windowName, windowIndex: t.windowIndex,
                    paneIndex: t.paneIndex, panePid: t.panePid, visible: visible, current: current)
        }
        #expect(p(relocated(base, tmux: tm(visible: false, current: true))) == ["visiblePane"])
        #expect(p(relocated(base, tmux: tm(visible: true, current: false))) == ["visiblePane"])
        #expect(p(relocated(base, tmux: tm(visible: false, current: false))).isEmpty)
    }

    @Test func planAsksBeforeClosingAVisibleOrUnplacedRexPane() {
        let docs = session("rex docs pass")
        let plan = planner.plan([docs.itemID], world, now: now)
        #expect(plan.needsSheet)
        #expect(plan.items.first?.protection.reasons == [.visiblePane])
        let spike = session("rex billing spike")
        #expect(!planner.plan([spike.itemID], world, now: now).needsSheet)
        let unplaced = worldWith([relocated(spike, rex: rexLoc(placed: false, visible: true, label: "studio",
                                                                 sessionId: studioId))])
        #expect(planner.plan([spike.itemID], unplaced, now: now).needsSheet)
    }

    @Test func footerNamesTheNewReasonText() {
        let rows = ListModel.build(world, protections: prot, options: ListOptions(), now: now)
        let idx = ListModel.index(rows)
        let sel = [idx[session("newsletter draft").itemID.stringValue]!]
        let text = SelectionSummary.text(selected: sel, plan: planner.plan(Set(sel.compactMap(\.item)), world, now: now))
        #expect(text.contains("1 needs a look (not in tmux or Rex)"))
        let vis = [idx[session("rex docs pass").itemID.stringValue]!]
        #expect(SelectionSummary.text(selected: vis, plan: planner.plan(Set(vis.compactMap(\.item)), world, now: now))
                    .contains("(visible pane)"))
    }
}

// MARK: - Close-time re-check (§7.4 step 3)

@Suite struct RexCloseRecheck {
    @Test func newlyProtectedSeesRexVisibility() {
        let spike = session("rex billing spike")                  // placed, not visible: no reason at plan time
        let item = planner.plan([spike.itemID], world, now: now).items[0]
        #expect(item.protection == Protection.none)
        let same = spike
        #expect(CloseCoordinator.newlyProtected(plan: item, fresh: same, now: now).isEmpty)
        // Discovery failed or the block vanished from Rex's layout at close time: unplaced = visible → skip.
        let unplaced = relocated(spike, rex: rexLoc(placed: false, visible: true, label: "", sessionId: studioId))
        #expect(CloseCoordinator.newlyProtected(plan: item, fresh: unplaced, now: now) == ["visiblePane"])
        // The user switched to its tab.
        let shown = relocated(spike, rex: rexLoc(visible: true, label: "studio", sessionId: studioId))
        #expect(CloseCoordinator.newlyProtected(plan: item, fresh: shown, now: now) == ["visiblePane"])
        // Already visible at plan time (the user confirmed it): not new.
        let docs = session("rex docs pass")
        let docsItem = planner.plan([docs.itemID], world, now: now).items[0]
        #expect(CloseCoordinator.newlyProtected(plan: docsItem, fresh: docs, now: now).isEmpty)
    }

    /// End to end through `run`: the fresh state cannot place the Rex pane, so the session is skipped and nothing
    /// is signalled (dry run as a second guard; the key is MockWorld's, not a process of ours).
    @Test func unplacedAtCloseTimeIsSkippedWithoutASignal() async {
        let dir = tempDir("rexrecheck")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var env = HeadroomEnv(environment: ["HOME": dir, "HEADROOM_SUPPORT_DIR": dir])
        env.dryRun = true
        let spike = session("rex billing spike")
        let fresh = relocated(spike, rex: rexLoc(placed: false, visible: true, label: "studio", sessionId: studioId))
        let backend = CloseBackend(sys: TestSysKit(), freshSessions: { _ in [spike.key: fresh] })
        let coord = CloseCoordinator(env: env, backend: backend, source: "test", timing: .fast)
        let log_ = EventLog()
        let recs = await coord.run(planner.plan([spike.itemID], world, now: now)) { log_.add($0) }
        #expect(log_.outcomes[spike.itemID] == .changedSkipped)
        #expect(recs.isEmpty)
        let entries = coord.journal.entries()
        #expect(!entries.contains { $0.kind == "signal" })
        #expect(entries.contains { $0.kind == "skip" && $0.reason.contains("visiblePane") })
    }
}

// MARK: - Presets (§7.2)

@Suite struct RexPresets {
    let prot = planner.protections(world, now: now)

    func titles(_ ids: [ItemID]) -> Set<String> {
        let s = Set(ids)
        return Set(world.claude.sessions.filter { s.contains($0.itemID) }.map(\.title))
    }

    @Test func idleSessionsTakeHiddenRexPanesOnly() {
        let idle = titles(SelectPreset.idleSessions(1800).ids(world, protections: prot, now: now))
        #expect(idle.contains("rex billing spike"))
        #expect(!idle.contains("rex docs pass"))              // visible
        #expect(!idle.contains("rex release notes"))          // busy
        #expect(!idle.contains("newsletter draft"))           // in neither
        #expect(idle.contains("map directions"))              // tmux unchanged
        // An unplaced Rex pane counts as on screen.
        let spike = session("rex billing spike")
        let w = worldWith([relocated(spike, rex: rexLoc(placed: false, visible: true, sessionId: studioId))])
        #expect(SelectPreset.idleSessions(1800).ids(w, protections: planner.protections(w, now: now), now: now).isEmpty)
    }

    @Test func rexSessionPresetKeysOnTheId() {
        let foundry = SelectPreset.rexSession(id: foundryId, label: "foundry")
        #expect(foundry.title == "foundry")
        #expect(titles(foundry.ids(world, protections: prot, now: now)) == ["rex release notes", "rex docs pass"])
        #expect(SelectPreset.rexSession(id: studioId, label: "studio").ids(world, protections: prot, now: now).count == 1)
        #expect(SelectPreset.rexSession(id: "session:gone", label: "foundry").ids(world, protections: prot, now: now)
                    .isEmpty)
        // A tmux session of the same name is not a Rex session, and vice versa.
        #expect(SelectPreset.tmuxSession("foundry").ids(world, protections: prot, now: now).isEmpty)
        #expect(SelectPreset.tmuxSession("oakfield-ledger").ids(world, protections: prot, now: now).count == 3)
        // Locked rows are left out.
        let locked = [session("rex docs pass").itemID: Protection.locked(.launcher)]
        #expect(foundry.ids(world, protections: locked, now: now).count == 1)
    }
}

// MARK: - Filter (§7.5)

@Suite struct RexFilter {
    func matching(_ q: String, in w: WorldSnapshot = world) -> Set<String> {
        let f = FilterQuery(q)
        var out: Set<String> = []
        for t in w.chrome.tabs where f.matches(FilterSubject(tab: t, now: now)) { out.insert(t.title) }
        for s in w.claude.sessions where f.matches(FilterSubject(session: s, now: now)) { out.insert(s.title) }
        for l in w.claude.leftovers where f.matches(FilterSubject(leftover: l, now: now)) { out.insert(l.unit.command) }
        return out
    }

    @Test func parses() {
        typealias T = FilterQuery.Token
        #expect(FilterQuery("rex:Foundry !rex:studio tmux:hub").tokens == [T.rex("foundry"), T.not(.rex("studio")), T.tmux("hub")])
        #expect(FilterQuery("rex:").tokens == [T.word("rex:")])
    }

    @Test func rexTokenMatchesTheRexSessionLabel() {
        #expect(matching("rex:found") == ["rex release notes", "rex docs pass"])
        #expect(matching("rex:foundry") == ["rex release notes", "rex docs pass"])
        #expect(matching("rex:studio") == ["rex billing spike"])
        #expect(matching("rex:hub").isEmpty)                   // a tmux session name
        // tmux: never matches a Rex session.
        for name in ["foundry", "studio", "f", "s"] {
            #expect(matching("tmux:\(name)").allSatisfy { !$0.hasPrefix("rex ") }, "tmux:\(name)")
        }
        // !rex:foundry keeps every tmux session (and everything else not in that Rex session).
        let notFoundry = matching("!rex:foundry is:session")
        for s in world.claude.sessions where s.tmux != nil { #expect(notFoundry.contains(s.title), "\(s.title)") }
        #expect(!notFoundry.contains("rex docs pass") && notFoundry.contains("rex billing spike"))
        // A label Headroom could not read ("") matches no rex: token.
        let spike = session("rex billing spike")
        let w = worldWith([relocated(spike, rex: rexLoc(visible: false, label: "", sessionId: studioId))])
        #expect(matching("rex:studio", in: w).isEmpty)
    }

    @Test func plainWordsSeeTheRexSessionAndTab() {
        #expect(matching("reference") == ["rex docs pass"])           // its tab label "api reference"
        #expect(matching("stripe spike") == ["rex billing spike"])     // two words, both in its tab label / title
        #expect(matching("foundry:2.1") == ["rex docs pass"])
        #expect(matching("studio").contains("rex billing spike"))
    }
}

// MARK: - List (§6.1)

@Suite struct RexList {
    var prot: [ItemID: Protection] { planner.protections(world, now: now) }

    @Test func groupingByTmuxOrRexSession() {
        let rows = ListModel.build(world, protections: prot, options: ListOptions(claudeGrouping: .tmux), now: now)
        let groups = rows[1].children
        #expect(groups.allSatisfy { $0.kind == .subgroup && !$0.selectable })
        let foundry = groups.first { $0.id == "rex:" + foundryId }
        #expect(foundry?.title == "Rex: foundry")
        #expect(Set(foundry?.children.map(\.title) ?? []) == ["rex release notes", "rex docs pass"])
        let studio = groups.first { $0.title == "Rex: studio" }
        #expect(studio?.id == "rex:" + studioId && studio?.children.count == 1)
        #expect(groups.contains { $0.id == "tmux:hub" && $0.title == "tmux: hub" })
        #expect(groups.last?.id == "tmux:" && groups.last?.title == "Not in tmux or Rex")
        #expect(groups.last?.children.map(\.title) == ["newsletter draft"])
        #expect(groups.reduce(0) { $0 + $1.children.count } == world.claude.sessions.count)
    }

    @Test func rexSessionsWithTheSameLabelStaySeparate() {
        let a = session("rex billing spike"), b = session("map directions")
        let other = "session:0190cccc-0000-7000-8000-0000000000ff"
        let w = worldWith([relocated(a, rex: rexLoc(visible: false, label: "dup", sessionId: studioId)),
                             relocated(b, rex: rexLoc(visible: false, label: "dup", sessionId: other))])
        let rows = ListModel.build(w, protections: planner.protections(w, now: now),
                                   options: ListOptions(claudeGrouping: .tmux), now: now)
        let groups = rows[1].children
        #expect(Set(groups.map(\.id)) == ["rex:" + studioId, "rex:" + other])
        #expect(groups.allSatisfy { $0.title == "Rex: dup" && $0.children.count == 1 })
    }

    @Test func locationAndVisibleGlyph() {
        let idx = ListModel.index(ListModel.build(world, protections: prot, options: ListOptions(), now: now))
        func row(_ t: String) -> Row { idx[session(t).itemID.stringValue]! }
        #expect(row("rex docs pass").location == "rex foundry:2.1 › foundry")
        #expect(row("rex docs pass").glyphs.contains(.visible))
        #expect(row("rex billing spike").location == "rex studio:1.1 › billing")
        #expect(!row("rex billing spike").glyphs.contains(.visible))
        #expect(row("newsletter draft").location.hasPrefix("not in tmux or Rex › "))
        let weekly = session("weekly update skill")
        #expect(row("weekly update skill").location.hasPrefix(weekly.tmux!.label + " "))
        #expect(row("weekly update skill").glyphs.contains(.visible))
        // Unplaced: "rex <label>:?" and the visible glyph (it is protected as visible).
        let spike = session("rex billing spike")
        let w = worldWith([relocated(spike, rex: rexLoc(placed: false, visible: true, label: "studio",
                                                          sessionId: studioId))])
        let r = ListModel.index(ListModel.build(w, protections: planner.protections(w, now: now), options: ListOptions(),
                                                now: now))[spike.itemID.stringValue]!
        #expect(r.location == "rex studio:? › billing")
        #expect(r.glyphs.contains(.visible))
    }
}

// MARK: - Signaller (§7.4 allowlist (b))

private let rexServerPath = "/Users/test/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/"
    + "Rex Server.app/Contents/MacOS/rex"

/// Fixture's table plus a Rex server 900 → login 901 (root-owned, absent from the table; parentPid knows it) →
/// `-zsh` 902 → `npm` 920 + `node` 921 in their own group, a `rex run` block 910 (+ child 911), and a dev server
/// 930/931 reparented to launchd (the control).
struct RexSignalFixture {
    let base = Fixture()
    var samples: [ProcSample] = []
    var argv: [Int32: [String]] = [:]

    static let server = ProcKey(pid: 900, startSec: 2000)
    static let shell = ProcKey(pid: 902, startSec: 2001)
    static let runRoot = ProcKey(pid: 910, startSec: 2002)
    static let runChild = ProcKey(pid: 911, startSec: 2003)
    static let npm = ProcKey(pid: 920, startSec: 2010)
    static let node = ProcKey(pid: 921, startSec: 2011)
    static let detached = ProcKey(pid: 930, startSec: 2020)
    static let detachedChild = ProcKey(pid: 931, startSec: 2021)
    static let parents: [Int32: Int32] = [901: 900]

    init(serverPath: String = rexServerPath) {
        func s(_ k: ProcKey, ppid: Int32, pgid: Int32, _ path: String, _ args: [String]) {
            samples.append(ProcSample(key: k, ppid: ppid, pgid: pgid, path: path, footprint: 1, rss: 1))
            argv[k.pid] = args
        }
        s(Self.server, ppid: 1, pgid: 900, serverPath, [serverPath, "server", "run", "--listen", "unix:///x/s.sock"])
        s(Self.shell, ppid: 901, pgid: 902, "/bin/zsh", ["-zsh"])
        s(Self.npm, ppid: 902, pgid: 920, "/opt/homebrew/bin/npm", ["npm", "run", "dev"])
        s(Self.node, ppid: 920, pgid: 920, "/usr/local/bin/node", ["node", "server.js"])
        s(Self.runRoot, ppid: 900, pgid: 910, "/opt/homebrew/bin/bun", ["bun", "run", "dev"])
        s(Self.runChild, ppid: 910, pgid: 910, "/usr/local/bin/node", ["node", "next"])
        s(Self.detached, ppid: 1, pgid: 930, "/opt/homebrew/bin/bun", ["bun", "run", "dev"])
        s(Self.detachedChild, ppid: 930, pgid: 930, "/usr/local/bin/node", ["node", "next"])
    }

    func table() -> ProcessTable { base.table(dropping: [Fixture.appThing.pid], extra: samples) }

    var args: @Sendable (ProcKey) -> ProcArgs? {
        let a = base.argv.merging(argv) { _, new in new }
        return { k in a[k.pid].map { ProcArgs(argv: $0) } }
    }

    var sys: StaticSysKit {
        let t = table()
        let a = args
        var byPid: [Int32: ProcArgs] = [:]
        for p in t.byPid.values { if let x = a(p.key) { byPid[p.pid] = x } }
        return StaticSysKit(table: t, args: byPid, parents: Self.parents)
    }
}

private func signalEnv(dryRun: Bool) -> HeadroomEnv {
    var e = HeadroomEnv(environment: ["HOME": "/Users/test"])
    e.dryRun = dryRun
    return e
}

/// kill(-pgid) of a group led by its first member (every fixture group is).
private func group(_ keys: ProcKey...) -> SignalTarget {
    .group(pgid: keys[0].pid, members: keys, automationRoots: [])
}

@Suite struct RexSignaller {
    let f = RexSignalFixture()

    func check(_ t: SignalTarget, fixture: RexSignalFixture? = nil, parentPid: Bool = true) -> SignalResult? {
        let fx = fixture ?? f
        let parents = parentPid ? RexSignalFixture.parents : [:]
        let s = Signaller(env: signalEnv(dryRun: false), sender: RecordingSender(), args: fx.args,
                          parentPid: { parents[$0] })
        return s.check(t, signal: SIGTERM, table: fx.table(), context: fx.base.context)
    }

    @Test func refusesRexPanesAndWhatRunsUnderThem() {
        typealias F = RexSignalFixture
        // The pane shell's own group (its parent `login` is not in the table; parentPid finds the server).
        #expect(check(group(F.shell)) == .refused("a Rex pane's process group"))
        // A `rex run` block: the command is the pane's first process.
        #expect(check(group(F.runRoot, F.runChild)) == .refused("a Rex pane's process group"))
        // A dev server started from the pane's shell, in a group of its own.
        #expect(check(group(F.npm, F.node)) == .refused("group runs under a Rex pane process (902)"))
        // A group with the Rex server: the .app rule answers first (existing string and priority).
        #expect(check(group(F.server)) == .refused("group contains an .app process (900)"))
    }

    @Test func serverOutsideAnAppBundleIsStillRefused() {
        let fx = RexSignalFixture(serverPath: "/usr/local/bin/rex")
        #expect(check(group(RexSignalFixture.server), fixture: fx) == .refused("group contains the Rex server (900)"))
        #expect(check(group(RexSignalFixture.npm, RexSignalFixture.node), fixture: fx)
                == .refused("group runs under a Rex pane process (902)"))
    }

    @Test func withoutParentPidThePaneShellIsStillALoginShell() {
        // Defence in depth: even if the hidden `login` cannot be read, the shell's group is refused by the `-` rule.
        #expect(check(group(RexSignalFixture.shell), parentPid: false) == .refused("group contains -zsh (902)"))
    }

    @Test func detachedDevServerIsAllowed() {
        typealias F = RexSignalFixture
        #expect(check(group(F.detached, F.detachedChild)) == nil)
        let sender = RecordingSender()
        let parents = F.parents
        let s = Signaller(env: signalEnv(dryRun: true), sender: sender, args: f.args, parentPid: { parents[$0] })
        #expect(s.send(group(F.detached, F.detachedChild), table: f.table(), context: f.base.context, reason: "t") == .dryRun)
        #expect(sender.calls.isEmpty)
    }

    @Test func sessionsInRexStillGetSIGTERM() {
        // A claude under the pane shell is a session target (a), like a claude in a tmux pane.
        var fx = RexSignalFixture()
        let claude = ProcKey(pid: 903, startSec: 2004)
        fx.samples.append(ProcSample(key: claude, ppid: 902, pgid: 903,
                                     path: "/Users/test/.local/share/claude/versions/2.1.0", footprint: 1, rss: 1))
        fx.argv[903] = ["claude"]
        #expect(check(.session(claude), fixture: fx) == nil)
        // …but a group running under it is refused for the claude, as before.
        let tool = ProcKey(pid: 940, startSec: 2030)
        fx.samples.append(ProcSample(key: tool, ppid: 903, pgid: 940, path: "/bin/sleep", footprint: 1, rss: 1))
        fx.argv[940] = ["sleep", "60"]
        #expect(check(group(tool), fixture: fx) == .refused("group runs under a live claude (903)"))
    }

    @Test func closeCoordinatorWiresSysKitParentPid() {
        let coord = CloseCoordinator(env: signalEnv(dryRun: true), backend: CloseBackend(sys: f.sys), source: "test")
        let t = f.table()
        #expect(coord.signaller.check(group(RexSignalFixture.npm, RexSignalFixture.node), signal: SIGTERM, table: t,
                                      context: f.base.context) == .refused("group runs under a Rex pane process (902)"))
        #expect(coord.signaller.check(group(RexSignalFixture.shell), signal: SIGTERM, table: t, context: f.base.context)
                == .refused("a Rex pane's process group"))
    }
}

// MARK: - Records and mock

@Suite struct RexRecords {
    func item(_ s: ClaudeSession) -> PlanItem { PlanItem(id: s.itemID, protection: .none, bytes: s.total, title: s.title) }

    @Test func closedRecordsCarryTheRexSession() throws {
        let spike = session("rex billing spike")
        for r in [CloseCoordinator.record(item(spike), world, batch: "b", source: "test"),
                  MockExecutor.record(item(spike), world, batch: "b")] {
            #expect(r.rexSessionId == studioId)
            #expect(r.rexSessionLabel == "studio")
            #expect(r.tmuxSession == nil)
            #expect(r.restorable)
        }
        // tmux sessions: no Rex keys.
        let map = session("map directions")
        let t = CloseCoordinator.record(item(map), world, batch: "b", source: "test")
        #expect(t.tmuxSession == map.tmux?.session && t.rexSessionId == nil && t.rexSessionLabel == nil)
        // An unknown label is not recorded as "": Undo then looks the session up by id only.
        let w = worldWith([relocated(spike, rex: rexLoc(placed: false, visible: true, label: "", sessionId: studioId))])
        for r in [CloseCoordinator.record(item(spike), w, batch: "b", source: "test"),
                  MockExecutor.record(item(spike), w, batch: "b")] {
            #expect(r.rexSessionId == studioId && r.rexSessionLabel == nil)
        }
        // closed.jsonl keeps both keys.
        let dir = tempDir("rexrec")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let rc = RecentlyClosed(env: HeadroomEnv(environment: ["HOME": dir, "HEADROOM_SUPPORT_DIR": dir]))
        rc.add([CloseCoordinator.record(item(spike), world, batch: "b", source: "test")])
        let back = try #require(rc.list().first)
        #expect(back.rexSessionId == studioId && back.rexSessionLabel == "studio")
        #expect(try String(contentsOfFile: dir + "/closed.jsonl", encoding: .utf8).contains("\"rexSessionId\""))
    }

    @Test func mockCloseRecordsAndPeek() async {
        let ctx = Headroom.mock(env: HeadroomEnv(environment: ["HOME": "/nonexistent", "HEADROOM_DRY_RUN": "1"]))
        let w = await ctx.world.snapshot()
        let spike = w.claude.sessions.first { $0.title == "rex billing spike" }!
        for await _ in ctx.executor.execute(ctx.executor.plan([spike.itemID], w)) {}
        let rec = await ctx.executor.recentlyClosed().first { $0.itemId == spike.itemID.stringValue }
        #expect(rec?.rexSessionId == studioId && rec?.rexSessionLabel == "studio")
        // Jump has no note in mock (protocol default).
        #expect(await ctx.executor.jumpNote(spike.itemID) == nil)
        let peek = ctx.executor as? PeekProvider
        let text = await peek?.captureRexBlock(sessionId: spike.rex!.sessionId, blockId: spike.rex!.blockId)
        #expect(text?.hasSuffix("(mock Rex pane \(spike.rex!.shortBlockId))") == true)
        #expect(await peek?.capturePane("%201")?.hasSuffix("(mock pane %201)") == true)
    }
}

// MARK: - LiveWorld's Rex cache and LiveExecutor (RexStub only)

private let s1 = "session:0190cccc-0000-7000-8000-000000000001"
private let w1 = "window:0190cccc-0000-7000-8000-0000000000a1"
private let w2 = "window:0190cccc-0000-7000-8000-0000000000a2"
private let b0 = "block:0190cccc-0000-7000-8000-0000000000b0"
private let b1 = "block:0190cccc-0000-7000-8000-0000000000b1"
private let c1 = "client:0190cccc-0000-7000-8000-0000000000c1"

private let lsJSON = #"{"sessions":[{"session_id":"\#(s1)","label":"foundry"}]}"#
private let inspectJSON = """
    {"session_id":"\(s1)","label":"foundry","active_window_id":"\(w1)",
     "windows":[{"window_id":"\(w1)","label":"notes","layers":[{"kind":"tiled","blocks":[{"block_id":"\(b0)"}]}]},
                {"window_id":"\(w2)","label":"api reference","layers":[{"kind":"tiled","blocks":[{"block_id":"\(b1)"}]}]}],
     "clients":[{"client_id":"\(c1)","principal":{"kind":"peer","transport":"unix"},"info":{"kind":"app"},
                 "connected_at":"2026-11-19T10:00:00Z","connection_state":"connected"}]}
    """

@Suite(.serialized) struct RexLiveWiring {
    @Test func stateCacheFollowsItsTTLAndCachesFailures() async {
        let stub = RexStub()
        defer { stub.remove() }
        stub.respond("ls", stdout: #"{"sessions":[]}"#)
        let rex = RexClient(env: HeadroomEnv(environment: ["HOME": "/nonexistent", "HEADROOM_REX": stub.path]))
        let cache = RexStateCache()
        _ = await cache.get(rex)
        let st = await cache.get(rex)
        #expect(stub.commands() == [["ls", "--json"], ["ls", "--json"]])       // TTL 0 (the default): always fresh
        #expect(st.reachable && st.complete && st.blocks.isEmpty)
        cache.setTTL(60)
        _ = await cache.get(rex)
        #expect(stub.commands().count == 2)                                   // within the TTL: no call

        stub.respond("ls", stdout: "", exit: 4)                               // Rex not running
        let down = RexStateCache()
        down.setTTL(60)
        #expect(await down.get(rex) == .empty)
        #expect(await down.get(rex) == .empty)
        #expect(stub.commands().count == 3)                                   // the failure was cached
    }

    @Test func stateCacheIsStaleForANewSessionToPutFirst() async {
        let stub = RexStub()
        defer { stub.remove() }
        stub.respond("ls", stdout: lsJSON)
        stub.respond("inspect \(s1)", stdout: inspectJSON)
        let rex = RexClient(env: HeadroomEnv(environment: ["HOME": "/nonexistent", "HEADROOM_REX": stub.path]))
        let cache = RexStateCache()
        cache.setTTL(60)
        let st = await cache.get(rex)
        #expect(st.appClients.keys.sorted() == [s1] && stub.commands().count == 2)
        // s1 was inspected by the cached pass: still fresh within the TTL.
        _ = await cache.get(rex, sessionsFirst: [s1])
        #expect(stub.commands().count == 2)
        // A claude now names a session the cached pass neither put first nor inspected: fetched again at once,
        // with that session first.
        let other = "session:0190cccc-0000-7000-8000-0000000000ee"
        _ = await cache.get(rex, sessionsFirst: [s1, other])
        #expect(stub.commands().count == 4 && stub.commands()[2] == ["ls", "--json"])
        // That pass put it first, so it is cached (even though `ls` does not list it): one fetch per TTL.
        _ = await cache.get(rex, sessionsFirst: [other])
        _ = await cache.get(rex, sessionsFirst: [s1, other])
        #expect(stub.commands().count == 4)
    }

    /// LiveExecutor's Rex Peek and Jump go through the ClaudeSource's RexClient (here: the stub).
    @Test func liveExecutorPeekAndJumpUseTheStub() async throws {
        let stub = RexStub()
        let dir = tempDir("rexlive")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { stub.remove(); try? FileManager.default.removeItem(atPath: dir) }
        stub.respond("ls", stdout: lsJSON)
        stub.respond("inspect \(s1)", stdout: inspectJSON)
        stub.respond("capture", stdout: (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n")
        let env = HeadroomEnv(environment: ["HOME": dir, "HEADROOM_SUPPORT_DIR": dir + "/support",
                                            "HEADROOM_CLAUDE_DIR": dir + "/dot-claude", "HEADROOM_DRY_RUN": "1",
                                            "HEADROOM_TMUX": "/nonexistent/tmux", "HEADROOM_REX": stub.path])
        let desktop = RecordingDesktop()
        let claude = ClaudeSource(env: env, desktop: desktop, watch: false)
        claude.cpuSettle = 0
        let exec = LiveExecutor(env: env, sys: LiveSysKit(env: env), tmux: TmuxClient(env: env), claude: claude,
                                chrome: ChromeSource(env: env, jxa: nil))

        // Peek: one read-only capture, last 60 lines.
        let text = try #require(await exec.captureRexBlock(sessionId: s1, blockId: b1))
        #expect(stub.commands() == [["capture", "-s", s1, "-b", b1, "--trim"]])
        let lines = text.split(separator: "\n")
        #expect(lines.count == 60 && lines.first == "line 41" && lines.last == "line 100")

        // A claude in a Rex pane (server 700 → hidden login 701 → -zsh 702 → claude 703), placed by a snapshot.
        let server = "/Users/x/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/"
            + "Rex Server.app/Contents/MacOS/rex"
        let k = ProcKey(pid: 703, startSec: 3000)
        let table = ProcessTable(samples: [
            ProcSample(key: ProcKey(pid: 700, startSec: 2900), ppid: 1, pgid: 700, path: server, footprint: 1, rss: 1),
            ProcSample(key: ProcKey(pid: 702, startSec: 2950), ppid: 701, pgid: 702, path: "/bin/zsh", footprint: 1, rss: 1),
            ProcSample(key: k, ppid: 702, pgid: 703, path: dir + "/claude/versions/9.9.9", footprint: 1, rss: 1),
        ])
        let sys = StaticSysKit(table: table, args: [
            700: ProcArgs(argv: [server, "server", "run", "--listen", "unix:///x/s.sock"]),
            702: ProcArgs(argv: ["-zsh"]),
            703: ProcArgs(argv: ["claude"], env: ["REX_BLOCK": b1, "REX_SESSION": s1]),
        ], cwds: [703: dir], parents: [701: 700])
        let own = OwnershipMap(owner: [:], browsers: [], liveSessions: [k])
        let snap = await claude.snapshot(table, own, sys, tmuxState: ([], []))
        #expect(snap.sessions.first?.rex?.label == "foundry:2.1")
        #expect(snap.sessions.first?.rex?.visible == false)                  // tab 2 is not the active tab
        let before = stub.calls().count

        // Jump: fresh state, `focus` on the server, Rex.app forward, then `session.select` on the app client.
        stub.respond("do", stdout: "")
        let note = await exec.jumpNote(.session(k))
        #expect(note == nil)
        let jumpCalls = Array(stub.calls().dropFirst(before))
        #expect(stub.commands().dropFirst(before).filter { $0.first != "session" && $0.first != "ls" } == [
            ["focus", "-s", s1, b1],
            ["do", "session.select", "session_id=\(s1)", "window_id=\(w2)"],
        ])
        #expect(jumpCalls.last.map { $0.contains("-C") && $0.contains(c1) } == true)
        #expect(desktop.calls == ["rex:focus"])

        // The app refuses (Remote Control off): the note reaches the caller through LiveExecutor.jumpNote.
        stub.respond("do", stdout: "", exit: 1)
        let refused = try #require(await exec.jumpNote(.session(k)))
        #expect(refused.contains("Remote Control") && refused.contains("foundry"))

        // Non-session ids: no note, no rex call, no desktop call.
        let n = stub.calls().count
        #expect(await exec.jumpNote(.leftover(pgid: 9, leaderStartSec: 9)) == nil)
        #expect(stub.calls().count == n && desktop.calls.count == 2)
    }
}
