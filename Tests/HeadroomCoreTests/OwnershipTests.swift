// SPEC §3 ownership: replay of the captured ps.txt/psargs.txt world (+ ownership-overlay.json), and small
// synthetic tables for each exclusion rule.
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomCore

enum OwnershipWorld {
    static let fixture: OwnershipFixture = {
        try! OwnershipFixture.load(ps: Fixtures.url("ps.txt"), psargs: Fixtures.url("psargs.txt"),
                                   overlay: Fixtures.url("ownership-overlay.json"))
    }()
    static let map: OwnershipMap = fixture.assign()
    static func key(_ pid: Int32) -> ProcKey { fixture.table.byPid[pid]!.key }
}

@Suite struct OwnershipFixtureTests {
    let fx = OwnershipWorld.fixture
    let map = OwnershipWorld.map

    @Test func fixtureLoads() {
        #expect(fx.table.byPid.count == 813 + 5)
        #expect(fx.sessions.count == 22 - 2 + 2)   // 22 claudes − unregistered 61153 − stale 74094 + 2 stale files
        #expect(fx.tmuxPanes.count == 25)
        // argv0 with spaces and a --flag=value with a space both survive the ps round trip.
        #expect(fx.argsByPid[41259]?.argv0 == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        #expect(fx.argsByPid[41262]?.flag("database") == "/Users/jappleseed/Library/Application Support/Google/Chrome/Crashpad")
        #expect(fx.argsByPid[7170]?.env["CLAUDE_PID"] == "5210")
        #expect(fx.argsByPid[79154]?.env["CLAUDE_PID"] == "21630")
        #expect(fx.argsByPid[67594]?.env["CLAUDE_PID"] == "80876")      // caffeinate started by claude 80876
    }

    @Test func invariantsHold() {
        let problems = Ownership.verify(map, table: fx.table, tmuxPanes: fx.tmuxPanes, env: fx.env, sys: fx.sys)
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func noPidInTwoBuckets() {
        // Independent of the dictionary shape: expand every owner into its units and check they are disjoint,
        // and that the per-bucket sums add up to the owned total.
        var seen: [Int32: Owner] = [:]
        for o in Ownership.owners(in: map) {
            for u in Ownership.units(of: o, in: fx.table, map: map, sys: fx.sys) {
                for m in u.members {
                    #expect(seen[m.pid] == nil, "pid \(m.pid) in \(o) and \(String(describing: seen[m.pid]))")
                    seen[m.pid] = o
                }
            }
        }
        #expect(seen.count == map.owner.count)
        let bucketSum = Ownership.owners(in: map).reduce(Bytes(0)) { $0 + fx.table.footprint(of: map.pids(ownedBy: $1)) }
        #expect(bucketSum == fx.table.footprint(of: map.owner.keys))
    }

    @Test func strictExclusions() {
        // tmux server, every pane shell (CLAUDE_PID 21630, dead), AeroSpace, SwiftBar, Hammerspoon (+ its aerospace
        // child), limactl ×2, and an orphaned login shell with its gitstatusd.
        let panes = fx.table.children[51951] ?? []
        #expect(panes.count == 25)
        let excluded: [Int32] = [51951, 36302, 29487, 79599, 79705, 88624, 88642, 79165, 79492] + panes
        for p in excluded {
            #expect(map.owner[p] == nil, "pid \(p) should be excluded but is \(String(describing: map.owner[p]))")
        }
        // Nothing with the dead tmux CLAUDE_PID became a leftover.
        #expect(!map.owner.values.contains { if case .leftover(_, 21630) = $0 { true } else { false } })
    }

    @Test func leftoversFound() {
        let bun = Owner.leftover(pgid: 7164, deadClaudePid: 5210)
        #expect(map.pids(ownedBy: bun) == [7167, 7170, 7172, 7508, 7509, 7516, 7536, 7537])
        let doppler = Owner.leftover(pgid: 40363, deadClaudePid: 38112)
        #expect(map.pids(ownedBy: doppler) == [40369, 40373, 40374])
        let leftoverOwners = Ownership.owners(in: map).filter { if case .leftover = $0 { true } else { false } }
        #expect(leftoverOwners == [bun, doppler])

        let u = Ownership.units(of: bun, in: fx.table, map: map, sys: fx.sys)
        #expect(u.count == 1)
        #expect(u.first?.root.pid == 7167)
        #expect(u.first?.pgid == 7164)
        #expect(u.first?.command.hasPrefix("bun") == true)
        // The pgid leader (7164) is gone, so the id uses the earliest member start time and stays stable.
        let id = Ownership.leftoverID(pgid: 7164, members: u.first!.members, table: fx.table)
        #expect(id == .leftover(pgid: 7164, leaderStartSec: fx.table.byPid[7167]!.key.startSec))
        #expect(id.stringValue == "leftover:7164:\(fx.table.byPid[7167]!.key.startSec)")
    }

    @Test func agentBrowserAttachesTo80876() {
        let owner = Owner.claudeBackground(OwnershipWorld.key(80876))
        for p: Int32 in [85289, 85291, 85299, 85303, 85310] {   // daemon, Chrome, GPU, renderer, crashpad
            #expect(map.owner[p] == owner, "pid \(p): \(String(describing: map.owner[p]))")
        }
        let b = map.browsers.first { $0.key.pid == 85291 }
        #expect(b != nil && b!.isMain == false && b!.headless && b!.remoteDebugging)
        #expect(b?.userDataDir?.contains("agent-browser-chrome") == true)
        let units = Ownership.units(of: owner, in: fx.table, map: map, sys: fx.sys)
        #expect(units.count == 2)                               // daemon tree + reparented crashpad
        #expect(units.contains { $0.root.pid == 85289 && $0.isAutomationBrowser })
    }

    @Test func chromeSectionIsOnlyTheMainBrowser() {
        #expect(map.mainBrowsers.map(\.key.pid) == [41259])
        let chrome = Set(map.pids(ownedBy: .chrome(browserPid: 41259)))
        let tree = Set([41259] + fx.table.descendants(of: 41259))
        #expect(chrome == tree.union([41262]))                   // + crashpad reparented to launchd
        for b in map.browsers where !b.isMain { #expect(!chrome.contains(b.key.pid)) }
        #expect(!map.owner.values.contains(.chrome(browserPid: 85291)))
        #expect(map.owner.values.allSatisfy { if case .otherChrome = $0 { false } else { true } })
    }

    @Test func sessionsChildrenAndUnregistered() {
        #expect(map.liveSessions.count == 20)
        #expect(map.staleSessionFiles == ["21630.json", "74094.json"])
        for k in map.liveSessions { #expect(map.owner[k.pid] == .session(k)) }
        #expect(map.owner[61153] == .unregisteredClaude(OwnershipWorld.key(61153)))   // no JSON
        #expect(map.owner[74094] == .unregisteredClaude(OwnershipWorld.key(74094)))   // JSON with wrong procStart
        #expect(map.owner[67594] == .claudeChild(OwnershipWorld.key(80876)))          // caffeinate
        // Playwright's headless shell under claude 73669 is a child, not a browser instance.
        #expect(map.owner[82283] == .claudeChild(OwnershipWorld.key(73669)))
        #expect(!map.browsers.contains { $0.key.pid == 82283 })
    }

    @Test func assignIsFast() {
        let t0 = Date()
        for _ in 0..<5 { _ = fx.assign() }
        let ms = Date().timeIntervalSince(t0) * 1000 / 5
        #expect(ms < 50, "assign took \(ms) ms on the fixture")
    }
}

// MARK: - Synthetic tables, one rule at a time

struct MiniWorld {
    var samples: [ProcSample] = []
    var args: [Int32: ProcArgs] = [:]
    var sessions: [SessionRecord] = []
    var panes: [TmuxPane] = []
    var hosts: [Wire.HostHello] = []
    /// Parents of processes left out of the table (Rex's root-owned `login`), served by StaticSysKit.parentPid.
    var parents: [Int32: Int32] = [:]
    var env = HeadroomEnv(environment: ["HOME": "/Users/t"])
    static let t0 = 1_790_000_000
    static let claudePath = "/Users/t/.local/share/claude/versions/2.1.0"

    mutating func proc(_ pid: Int32, ppid: Int32 = 1, pgid: Int32? = nil, path: String, argv: [String]? = nil,
                       env e: [String: String] = [:], start: Int = 0, fp: Bytes = 1 << 20, uid: UInt32 = 501) {
        samples.append(ProcSample(key: ProcKey(pid: pid, startSec: Self.t0 + start), ppid: ppid, pgid: pgid ?? pid,
                                  uid: uid, path: path, footprint: fp, rss: fp))
        args[pid] = ProcArgs(argv: argv ?? [path], env: e)
    }
    mutating func claude(_ pid: Int32, ppid: Int32 = 1, start: Int = 0, registered: Bool = true) {
        proc(pid, ppid: ppid, path: Self.claudePath, argv: ["claude"], start: start)
        if registered {
            sessions.append(SessionRecord(pid: pid, sessionId: "s\(pid)",
                                          procStart: OwnershipFixture.procStartString(Self.t0 + start),
                                          filePath: "\(pid).json"))
        }
    }
    func assign(uid: UInt32? = 501, excluding: Set<Int32> = []) -> (OwnershipMap, ProcessTable) {
        let t = ProcessTable(samples: samples)
        return (Ownership.assign(t, sessions: sessions, hosts: hosts, tmuxPanes: panes, sys: sys(t), env: env,
                                 excluding: excluding, uid: uid), t)
    }
    func sys(_ t: ProcessTable) -> StaticSysKit { StaticSysKit(table: t, args: args, parents: parents) }
    func key(_ pid: Int32) -> ProcKey { samples.first { $0.pid == pid }!.key }
}

@Suite struct OwnershipRuleTests {
    let chromePath = KnownPaths.chromeExecutable
    let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"

    @Test func liveClaudeBackgroundVsDeadLeftover() {
        var w = MiniWorld()
        w.claude(100)
        w.proc(200, path: "/opt/homebrew/bin/bun", argv: ["bun", "run", "dev"], env: ["CLAUDE_PID": "100"], start: 10)
        w.proc(201, ppid: 200, pgid: 200, path: "/opt/homebrew/bin/node", env: ["CLAUDE_PID": "100"], start: 11)
        w.proc(300, path: "/opt/homebrew/bin/bun", env: ["CLAUDE_PID": "999"], start: 10)
        let (m, _) = w.assign()
        #expect(m.owner[200] == .claudeBackground(w.key(100)))
        #expect(m.owner[201] == .claudeBackground(w.key(100)))
        #expect(m.owner[300] == .leftover(pgid: 300, deadClaudePid: 999))
    }

    @Test func reusedClaudePidMakesALeftover() {
        // CLAUDE_PID=100 names a claude that started AFTER the unit (pid reuse) → leftover, not background.
        var w = MiniWorld()
        w.claude(100, start: 500)
        w.proc(200, path: "/usr/local/bin/server", env: ["CLAUDE_PID": "100"], start: 10)
        let (m, _) = w.assign()
        #expect(m.owner[200] == .leftover(pgid: 200, deadClaudePid: 100))
    }

    @Test func rootIsHighestEnvLinkedAncestor() {
        var w = MiniWorld()
        w.proc(200, path: "/usr/local/bin/doppler", env: ["CLAUDE_PID": "7"])
        w.proc(201, ppid: 200, pgid: 200, path: "/opt/homebrew/bin/node", env: ["CLAUDE_PID": "7"])
        w.proc(202, ppid: 201, pgid: 200, path: "/opt/homebrew/bin/next-server")          // no env: comes with root
        let (m, t) = w.assign()
        let o = Owner.leftover(pgid: 200, deadClaudePid: 7)
        #expect(m.pids(ownedBy: o) == [200, 201, 202])
        let units = Ownership.units(of: o, in: t, map: m, sys: StaticSysKit(table: t, args: w.args))
        #expect(units.count == 1 && units[0].root.pid == 200 && units[0].members.count == 3)
    }

    @Test func exclusionsByPathArgv0AndAncestry() {
        var w = MiniWorld()
        let e = ["CLAUDE_PID": "7"]
        w.proc(10, path: "/Applications/Foo.app/Contents/MacOS/Foo", env: e)                  // inside .app
        w.proc(11, ppid: 10, path: "/usr/local/bin/helper", env: e)                            // under .app
        w.proc(20, path: "/opt/homebrew/bin/limactl", argv: ["limactl", "hostagent"], env: e)  // argv0 limactl
        w.proc(21, ppid: 20, path: "/usr/bin/ssh", env: e)                                     // under limactl
        w.proc(30, path: "/bin/zsh", argv: ["-zsh"], env: e)                                   // login shell
        w.proc(31, ppid: 30, path: "/usr/local/bin/gitstatusd", env: e)                        // under login shell
        w.proc(40, path: "/usr/bin/ssh-agent", argv: ["ssh-agent", "-l"], env: e)
        // The tmux server carries another claude's CLAUDE_PID (8): values on tmux/panes are "inherited" and
        // never link anything (see claudePidInheritedFromTmuxIsNotEnvLinked), so 7 must still link the control.
        let e8 = ["CLAUDE_PID": "8"]
        w.proc(50, path: "/opt/homebrew/bin/tmux", argv: ["tmux", "new-session", "-d"], env: e8) // tmux server
        w.proc(51, ppid: 50, path: "/bin/zsh", argv: ["zsh"], env: e8)                         // pane shell
        w.proc(52, ppid: 51, path: "/opt/homebrew/bin/bun", argv: ["bun", "dev"], env: e)      // dev server in a pane
        w.proc(60, path: "/usr/local/bin/colima", argv: ["colima", "start"], env: e)
        w.proc(70, path: "/usr/local/bin/docker", argv: ["/usr/local/bin/docker", "run"], env: e)
        w.panes = [TmuxPane(paneId: "%1", panePid: 51, paneActive: true, windowActive: true, sessionAttached: 1,
                            session: "s", windowIndex: 1, paneIndex: 1, windowName: "w", paneTitle: "",
                            currentCommand: "zsh")]
        w.proc(80, path: "/usr/local/bin/ok-server", env: e)                                   // control: a leftover
        let (m, _) = w.assign()
        for p: Int32 in [10, 11, 20, 21, 30, 31, 40, 50, 51, 52, 60, 70] {
            #expect(m.owner[p] == nil, "pid \(p) should be excluded, got \(String(describing: m.owner[p]))")
        }
        #expect(m.owner[80] == .leftover(pgid: 80, deadClaudePid: 7))
    }

    /// Review finding: a tmux server started from a claude Bash tool carries that claude's CLAUDE_PID, and every
    /// pane inherits it. A daemon started in a pane and reparented to launchd must not become a leftover of the
    /// (dead) claude, nor background of a new claude that reused the pid.
    @Test func claudePidInheritedFromTmuxIsNotEnvLinked() {
        var w = MiniWorld()
        let e = ["CLAUDE_PID": "21630", "CLAUDE_CODE_SESSION_ID": "sess-tmux"]
        w.proc(50, path: "/opt/homebrew/bin/tmux", argv: ["tmux", "new-session", "-d", "-s", "fleet"], env: e)
        w.proc(51, ppid: 50, path: "/bin/zsh", argv: ["zsh"], env: e)
        w.panes = [TmuxPane(paneId: "%1", panePid: 51, paneActive: true, windowActive: true, sessionAttached: 1,
                            session: "s", windowIndex: 1, paneIndex: 1, windowName: "w", paneTitle: "",
                            currentCommand: "zsh")]
        w.proc(60, path: "/opt/homebrew/bin/postgres", argv: ["postgres", "-D", "x"], env: e, start: 10)   // daemonized
        w.proc(61, path: "/opt/homebrew/bin/redis-server", env: ["CLAUDE_CODE_SESSION_ID": "sess-tmux", "CLAUDE_PID": "4444"],
               start: 10)                                                                               // same session id
        w.proc(80, path: "/usr/local/bin/ok-server", env: ["CLAUDE_PID": "7"])                          // control
        var (m, _) = w.assign()
        #expect(m.owner[60] == nil, "\(String(describing: m.owner[60]))")
        #expect(m.owner[61] == nil, "\(String(describing: m.owner[61]))")
        #expect(m.owner[80] == .leftover(pgid: 80, deadClaudePid: 7))
        // pid reuse: a live claude now has pid 21630 and started before the daemon → still not its background.
        w.claude(21630, start: 0)
        (m, _) = w.assign()
        #expect(m.owner[60] == nil, "\(String(describing: m.owner[60]))")
    }

    static let rexServerPath = "/Users/t/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

    /// The Rex counterpart of claudePidInheritedFromTmuxIsNotEnvLinked: the rex CLI autostarts the server, so a server
    /// first started from a claude Bash tool keeps that claude's CLAUDE_PID; values on the server or a pane's first
    /// process never env-link a daemon that was reparented to launchd.
    @Test func claudePidInheritedFromRexIsNotEnvLinked() {
        var w = MiniWorld()
        let e = ["CLAUDE_PID": "21630", "CLAUDE_CODE_SESSION_ID": "X"]
        w.proc(700, path: Self.rexServerPath, argv: [Self.rexServerPath, "server", "run", "--listen", "unix:///x/s.sock"],
               env: e)
        w.parents[701] = 700                                                   // root-owned login, not in the table
        w.proc(702, ppid: 701, path: "/bin/zsh", argv: ["-zsh"])               // platform binary: env hidden
        // A `rex run` block whose command (not a platform binary) carries another inherited value.
        w.proc(710, ppid: 700, path: "/opt/homebrew/bin/bun", argv: ["bun", "run", "dev"], env: ["CLAUDE_PID": "5555"])
        w.proc(60, path: "/opt/homebrew/bin/postgres", argv: ["postgres", "-D", "x"], env: e, start: 10)    // daemonized
        w.proc(61, path: "/opt/homebrew/bin/redis-server", env: ["CLAUDE_CODE_SESSION_ID": "X", "CLAUDE_PID": "4444"],
               start: 10)                                                                                 // same session id
        w.proc(62, path: "/opt/homebrew/bin/node", env: ["CLAUDE_PID": "5555"], start: 10)               // from the block
        w.proc(80, path: "/usr/local/bin/ok-server", env: ["CLAUDE_PID": "7"])                           // control
        let (m, _) = w.assign()
        for p: Int32 in [60, 61, 62, 700, 702, 710] {
            #expect(m.owner[p] == nil, "pid \(p): \(String(describing: m.owner[p]))")
        }
        #expect(m.owner[80] == .leftover(pgid: 80, deadClaudePid: 7))
    }

    /// Already true before Rex support (the `-zsh` login-shell rule); kept as a regression guard.
    @Test func devServerInARexPaneIsNotALeftover() {
        var w = MiniWorld()
        w.proc(700, path: Self.rexServerPath, argv: [Self.rexServerPath, "server", "run"])
        w.parents[701] = 700
        w.proc(702, ppid: 701, path: "/bin/zsh", argv: ["-zsh"])
        w.proc(703, ppid: 702, pgid: 703, path: "/opt/homebrew/bin/bun", argv: ["bun", "dev"], env: ["CLAUDE_PID": "7"])
        let (m, _) = w.assign()
        #expect(m.owner[703] == nil, "\(String(describing: m.owner[703]))")
    }

    /// The Rex chain rule on its own: a server outside any `.app` (a custom build) and a `rex run` block whose first
    /// process is not a login shell. Neither the .app nor the login-shell rule applies, so only the Rex rule excludes.
    @Test func rexServerAndBlockRootExcludeTheirSubtree() {
        var w = MiniWorld()
        w.proc(700, path: "/opt/rex/bin/rex", argv: ["rex", "server", "run"])
        w.proc(710, ppid: 700, pgid: 710, path: "/opt/homebrew/bin/bun", argv: ["bun", "run", "dev"], env: ["CLAUDE_PID": "7"])
        w.proc(711, ppid: 710, pgid: 710, path: "/opt/homebrew/bin/node", env: ["CLAUDE_PID": "7"])
        w.proc(720, path: "/opt/rex/bin/rex", argv: ["rex", "server", "logs", "--follow"])        // not a server
        w.proc(721, ppid: 720, pgid: 721, path: "/opt/homebrew/bin/node", env: ["CLAUDE_PID": "8"])  // control
        let (m, t) = w.assign()
        #expect(m.owner[710] == nil && m.owner[711] == nil, "\(String(describing: m.owner[710]))")
        #expect(m.owner[721] == .leftover(pgid: 721, deadClaudePid: 8))
        #expect(Ownership.verify(m, table: t, tmuxPanes: [], env: w.env, sys: w.sys(t)).isEmpty)
        // verify() reports a Rex server or pane process found inside a unit.
        let bad = OwnershipMap(owner: [710: .leftover(pgid: 710, deadClaudePid: 7), 711: .leftover(pgid: 710, deadClaudePid: 7)],
                               browsers: [])
        let problems = Ownership.verify(bad, table: t, tmuxPanes: [], env: w.env, sys: w.sys(t))
        #expect(problems == ["Rex server or pane process 710 inside a unit leftover(pgid: 710, deadClaudePid: 7)"])
    }

    @Test func otherUsersAndSelfAreNeverUnits() {
        var w = MiniWorld()
        w.proc(10, path: "/usr/local/bin/x", env: ["CLAUDE_PID": "7"], uid: 0)
        w.proc(20, path: "/usr/local/bin/y", env: ["CLAUDE_PID": "7"])
        let (m, _) = w.assign(uid: 501, excluding: [20])
        #expect(m.owner[10] == nil)
        #expect(m.owner[20] == nil)
    }

    @Test func mainBrowserHeuristicsAndHost() {
        var w = MiniWorld()
        w.proc(100, path: chromePath, argv: [chromePath])                                               // main
        w.proc(101, ppid: 100, pgid: 100, path: helper, argv: [helper, "--type=renderer", "--renderer-client-id=4"])
        w.proc(200, path: chromePath, argv: [chromePath, "--user-data-dir=/tmp/profile-x"])             // automation
        w.proc(201, ppid: 200, pgid: 200, path: helper, argv: [helper, "--type=renderer"])
        w.proc(300, path: chromePath, argv: [chromePath, "--remote-debugging-port=9222",
                                             "--user-data-dir=/Users/t/Library/Application Support/Google/Chrome/"])
        w.proc(400, path: chromePath, argv: [chromePath, "--headless"])
        let (m, _) = w.assign()
        #expect(m.mainBrowsers.map(\.key.pid) == [100])
        #expect(m.pids(ownedBy: .chrome(browserPid: 100)) == [100, 101])
        #expect(m.pids(ownedBy: .otherChrome(browserPid: 200)) == [200, 201])
        #expect(m.owner[300] == .otherChrome(browserPid: 300))
        #expect(m.owner[400] == .otherChrome(browserPid: 400))
        #expect(m.browsers.first { $0.key.pid == 300 }?.remoteDebugging == true)

        // A connected host names the main browser, even one the heuristics would call automation.
        var w2 = w
        w2.hosts = [Wire.HostHello(hostPid: 999, browserPid: 300, hostVersion: "1")]
        let (m2, _) = w2.assign()
        #expect(Set(m2.mainBrowsers.map(\.key.pid)) == [300])
        #expect(m2.owner[300] == .chrome(browserPid: 300))
        #expect(m2.owner[100] == .otherChrome(browserPid: 100))
    }

    /// Live finding (integration): an automation Chrome with its own --user-data-dir still starts a crashpad
    /// whose --database is the DEFAULT Chrome folder. It must follow its own browser (by start time), not main.
    @Test func crashpadFollowsTheBrowserItStartedWith() {
        var w = MiniWorld()
        let pad = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/154.0.8037.58/Helpers/chrome_crashpad_handler"
        let db = "--database=/Users/t/Library/Application Support/Google/Chrome/Crashpad"
        w.proc(100, path: chromePath, argv: [chromePath])                                         // main, t0
        w.proc(101, path: pad, argv: [pad, db], start: 0)                                          // main's crashpad
        w.proc(200, path: "/usr/local/bin/agent-browser", env: ["CLAUDE_PID": "50"], start: 5000)
        w.claude(50)
        w.proc(210, ppid: 200, pgid: 210, path: chromePath,
               argv: [chromePath, "--headless=new", "--remote-debugging-port=0", "--user-data-dir=/tmp/agent-browser-chrome-x"],
               start: 5001)
        w.proc(211, path: pad, argv: [pad, db], start: 5001)                                       // default db, reparented
        let (m, _) = w.assign()
        #expect(m.owner[101] == .chrome(browserPid: 100))
        #expect(m.owner[210] == .claudeBackground(w.key(50)))
        #expect(m.owner[211] == .claudeBackground(w.key(50)), "\(String(describing: m.owner[211]))")
    }

    @Test func defaultUserDataDirTrailingSlashIsMain() {
        var w = MiniWorld()
        w.proc(100, path: chromePath, argv: [chromePath, "--user-data-dir=/Users/t/Library/Application Support/Google/Chrome/"])
        let (m, _) = w.assign()
        #expect(m.mainBrowsers.map(\.key.pid) == [100])
    }

    @Test func sessionLivenessRules() {
        var w = MiniWorld()
        w.claude(100)                                                    // procStart matches
        w.proc(200, path: MiniWorld.claudePath, argv: ["claude"], start: 5)
        w.sessions.append(SessionRecord(pid: 200, procStart: OwnershipFixture.procStartString(MiniWorld.t0 + 7),
                                        filePath: "200.json"))           // ±2 s: 2 s off → live
        w.proc(300, path: MiniWorld.claudePath, argv: ["claude"], start: 5)
        w.sessions.append(SessionRecord(pid: 300, procStart: OwnershipFixture.procStartString(MiniWorld.t0 + 9),
                                        filePath: "300.json"))           // 4 s off → stale, unregistered
        w.proc(400, path: MiniWorld.claudePath, argv: ["claude"], start: 0)
        w.sessions.append(SessionRecord(pid: 400, startedAt: Double(MiniWorld.t0 + 45) * 1000,
                                        filePath: "400.json"))           // no procStart: startedAt ±60 s → live
        w.proc(500, path: "/usr/bin/vim", argv: ["vim"])
        w.sessions.append(SessionRecord(pid: 500, procStart: OwnershipFixture.procStartString(MiniWorld.t0),
                                        filePath: "500.json"))           // not a claude binary → stale
        w.sessions.append(SessionRecord(pid: 600, filePath: "600.json")) // pid gone → stale
        w.proc(700, path: "/usr/local/bin/other", argv: ["claude", "--resume"])
        w.sessions.append(SessionRecord(pid: 700, procStart: OwnershipFixture.procStartString(MiniWorld.t0),
                                        filePath: "700.json"))           // argv[0] == claude → live
        let (m, _) = w.assign()
        #expect(Set(m.liveSessions.map(\.pid)) == [100, 200, 400, 700])
        #expect(m.staleSessionFiles == ["300.json", "500.json", "600.json"])
        #expect(m.owner[300] == .unregisteredClaude(w.key(300)))
        #expect(m.owner[500] == nil)
    }

    @Test func claudeMultiCallHelpersAreNotSessions() {
        // Claude Code runs its own binary as `ugrep` for searches; an orphaned one is a leftover, not a claude.
        var w = MiniWorld()
        w.proc(10, path: MiniWorld.claudePath, argv: ["ugrep", "-E", "x"], env: ["CLAUDE_PID": "4242"])
        w.proc(20, path: "/tmp/x/claude/versions/9.9.9", argv: ["/tmp/x/claude/versions/9.9.9", "30"])
        w.env.claudeVersionsGlobs = ["/tmp/x/claude/versions/*"]
        let (m, _) = w.assign()
        #expect(m.owner[10] == .leftover(pgid: 10, deadClaudePid: 4242))
        #expect(m.owner[20] == .unregisteredClaude(w.key(20)))     // the SPEC's test dummy counts as claude
    }

    @Test func sessionChildrenStopAtNestedSessions() {
        var w = MiniWorld()
        w.claude(100)
        w.proc(101, ppid: 100, pgid: 101, path: "/bin/zsh", argv: ["zsh", "-c", "x"])
        w.claude(102, ppid: 101)                                          // a nested registered claude
        w.proc(103, ppid: 102, path: "/usr/local/bin/mcp")
        let (m, _) = w.assign()
        #expect(m.owner[101] == .claudeChild(w.key(100)))
        #expect(m.owner[102] == .session(w.key(102)))
        #expect(m.owner[103] == .claudeChild(w.key(102)))
    }

    @Test func automationBrowserUnderLeftoverComesWithIt() {
        var w = MiniWorld()
        w.proc(10, path: "/Users/t/.bun/bin/agent-browser", env: ["CLAUDE_PID": "4242"])
        w.proc(11, ppid: 10, pgid: 11, path: chromePath, argv: [chromePath, "--remote-debugging-port=0", "--headless=new"])
        w.proc(12, ppid: 11, pgid: 11, path: helper, argv: [helper, "--type=gpu-process"])
        let (m, _) = w.assign()
        let o = Owner.leftover(pgid: 10, deadClaudePid: 4242)
        #expect(m.pids(ownedBy: o) == [10, 11, 12])
        #expect(!m.owner.values.contains(.otherChrome(browserPid: 11)))
    }

    @Test func procStartParsing() {
        #expect(Ownership.parseProcStart("Tue Sep 29 16:28:53 2026").map { Int($0.timeIntervalSince1970) } == 1_790_699_333)
        #expect(Ownership.parseProcStart("Wed Sep  2 01:02:03 2026") != nil)   // ctime pads the day
        #expect(Ownership.parseProcStart("garbage") == nil)
        #expect(OwnershipFixture.procStartString(1_790_699_333) == "Tue Sep 29 16:28:53 2026")
    }

    @Test func commandLabel() {
        #expect(Ownership.commandLabel(argv: ["/opt/homebrew/bin/bun", "run", "dev", "--port", "3217"])
                == "bun run dev --port 3217")
        #expect(Ownership.commandLabel(argv: [], path: "/usr/bin/x") == "x")
        #expect(Ownership.commandLabel(argv: [String(repeating: "a", count: 300)]).count == 120)
    }
}
