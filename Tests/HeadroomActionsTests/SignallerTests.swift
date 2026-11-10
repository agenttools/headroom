// Signaller allowlist (§7.4). Synthetic process tables + a recording sender: no real signal is sent here.
import Darwin
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomActions

final class RecordingSender: SignalSender, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(pid_t, Int32)] = []
    var calls: [(pid_t, Int32)] { lock.withLock { _calls } }
    func send(_ pid: pid_t, _ sig: Int32) -> Int32 { lock.withLock { _calls.append((pid, sig)) }; return 0 }
}

private let home = "/Users/test"
private let claudePath = "/Users/test/.local/share/claude/versions/2.1.0"
private let chromePath = KnownPaths.chromeExecutable

/// A table with this test process, its real parent chain root, a claude, a tmux server + pane shell,
/// a dev-server group, a main Chrome and an automation Chrome.
struct Fixture {
    let me = getpid()
    let parent = getppid()
    let myPgid = getpgrp()
    var samples: [ProcSample] = []
    var argv: [Int32: [String]] = [:]

    static let claude = ProcKey(pid: 50_000, startSec: 1000)
    static let tmuxServer = ProcKey(pid: 50_100, startSec: 900)
    static let paneShell = ProcKey(pid: 50_101, startSec: 901)
    static let devLeader = ProcKey(pid: 50_200, startSec: 1100)
    static let devChild = ProcKey(pid: 50_201, startSec: 1100)
    static let mainChrome = ProcKey(pid: 50_300, startSec: 500)
    static let autoChrome = ProcKey(pid: 50_400, startSec: 1200)
    static let autoHelper = ProcKey(pid: 50_401, startSec: 1200)
    static let appThing = ProcKey(pid: 50_500, startSec: 1300)

    init() {
        func s(_ k: ProcKey, ppid: Int32, pgid: Int32, _ path: String, _ args: [String]) {
            samples.append(ProcSample(key: k, ppid: ppid, pgid: pgid, path: path, footprint: 1, rss: 1))
            argv[k.pid] = args
        }
        s(ProcKey(pid: 1, startSec: 1), ppid: 0, pgid: 1, "/sbin/launchd", ["/sbin/launchd"])
        s(ProcKey(pid: parent, startSec: 10), ppid: 1, pgid: myPgid, "/usr/bin/swift-test", ["swift-test"])
        s(ProcKey(pid: me, startSec: 11), ppid: parent, pgid: myPgid, "/tmp/HeadroomTests", ["xctest"])
        s(Self.tmuxServer, ppid: 1, pgid: Self.tmuxServer.pid, "/opt/homebrew/bin/tmux", ["tmux"])
        s(Self.paneShell, ppid: Self.tmuxServer.pid, pgid: Self.paneShell.pid, "/bin/zsh", ["-zsh"])
        s(Self.claude, ppid: Self.paneShell.pid, pgid: Self.claude.pid, claudePath, ["claude"])
        s(Self.devLeader, ppid: 1, pgid: Self.devLeader.pid, "/opt/homebrew/bin/bun", ["bun", "run", "dev"])
        s(Self.devChild, ppid: Self.devLeader.pid, pgid: Self.devLeader.pid, "/usr/local/bin/node", ["node", "next"])
        s(Self.mainChrome, ppid: 1, pgid: Self.mainChrome.pid, chromePath, [chromePath])
        s(Self.autoChrome, ppid: 1, pgid: Self.autoChrome.pid, chromePath,
          [chromePath, "--headless", "--user-data-dir=/tmp/agent-profile", "--remote-debugging-port=9222"])
        s(Self.autoHelper, ppid: Self.autoChrome.pid, pgid: Self.autoChrome.pid,
          "/Applications/Google Chrome.app/Contents/Frameworks/x/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
          ["Google Chrome Helper", "--type=renderer"])
        s(Self.appThing, ppid: 1, pgid: Self.devLeader.pid, "/Applications/Slack.app/Contents/MacOS/Slack", ["Slack"])
    }

    func table(dropping: Set<Int32> = [], extra: [ProcSample] = []) -> ProcessTable {
        ProcessTable(samples: samples.filter { !dropping.contains($0.pid) } + extra)
    }

    var args: @Sendable (ProcKey) -> ProcArgs? {
        let a = argv
        return { k in a[k.pid].map { ProcArgs(argv: $0) } }
    }

    var context: SignalContext {
        SignalContext(selfPid: me, panePids: [Self.paneShell.pid], hostBrowserPids: [Self.mainChrome.pid],
                      mainBrowserPids: [Self.mainChrome.pid], ownedAutomationBrowsers: [Self.autoChrome])
    }
}

private func env(dryRun: Bool) -> HeadroomEnv {
    var e = HeadroomEnv(environment: ["HOME": home])
    e.dryRun = dryRun
    return e
}

@Suite struct SignallerAllowlist {
    let f = Fixture()

    func check(_ t: SignalTarget, signal: Int32 = SIGTERM, table: ProcessTable? = nil,
               context: SignalContext? = nil) -> SignalResult? {
        Signaller(env: env(dryRun: false), sender: RecordingSender(), args: f.args)
            .check(t, signal: signal, table: table ?? f.table(), context: context ?? f.context)
    }

    func isRefused(_ r: SignalResult?) -> Bool { if case .refused = r { true } else { false } }

    @Test func allowsTheThreeTargetKinds() {
        #expect(check(.session(Fixture.claude)) == nil)
        #expect(check(.group(pgid: Fixture.devLeader.pid, members: [Fixture.devLeader, Fixture.devChild], automationRoots: []),
                      table: f.table(dropping: [Fixture.appThing.pid])) == nil)
        #expect(check(.automationBrowser(Fixture.autoChrome)) == nil)
    }

    @Test func refusesPidOneOrLess() {
        for pid: Int32 in [1, 0, -1, -50_200] {
            #expect(isRefused(check(.session(ProcKey(pid: pid, startSec: 1)))), "pid \(pid)")
        }
        #expect(isRefused(check(.group(pgid: 1, members: [], automationRoots: []))))
        #expect(isRefused(check(.group(pgid: 0, members: [], automationRoots: []))))
    }

    @Test func refusesSelfAndAncestors() {
        #expect(check(.session(ProcKey(pid: f.me, startSec: 11))) == .refused("Headroom itself"))
        #expect(check(.session(ProcKey(pid: f.parent, startSec: 10))) == .refused("an ancestor of Headroom"))
        #expect(isRefused(check(.group(pgid: f.myPgid, members: [ProcKey(pid: f.me, startSec: 11)], automationRoots: []))))
        #expect(isRefused(check(.automationBrowser(ProcKey(pid: f.parent, startSec: 10)))))
    }

    @Test func refusesAppProcesses() {
        // The dev-server group also contains Slack (an .app process) → refused.
        let r = check(.group(pgid: Fixture.devLeader.pid, members: [Fixture.devLeader], automationRoots: []))
        #expect(r == .refused("group contains an .app process (\(Fixture.appThing.pid))"))
        // A claude-looking path inside an .app bundle is refused as a session too.
        let inApp = ProcKey(pid: 50_600, startSec: 1)
        let t = f.table(extra: [ProcSample(key: inApp, ppid: 1, pgid: 50_600,
                                           path: "/Applications/Claude.app/Contents/claude/versions/1/claude",
                                           footprint: 1, rss: 1)])
        #expect(check(.session(inApp), table: t) == .refused(".app process"))
        // …and an .app process that is not a claude at all.
        #expect(isRefused(check(.session(Fixture.appThing))))
    }

    @Test func refusesMainChrome() {
        #expect(check(.automationBrowser(Fixture.mainChrome)) == .refused("the main Chrome"))
        #expect(isRefused(check(.session(Fixture.mainChrome))))
        #expect(isRefused(check(.group(pgid: Fixture.mainChrome.pid, members: [Fixture.mainChrome], automationRoots: []))))
        // An automation browser that no session/leftover owns is refused.
        var c = f.context; c.ownedAutomationBrowsers = []
        #expect(check(.automationBrowser(Fixture.autoChrome), context: c) == .refused("not owned by a session or leftover"))
        // Automation browsers never get SIGKILL.
        #expect(isRefused(check(.automationBrowser(Fixture.autoChrome), signal: SIGKILL)))
        // A default-profile Chrome not known as main is still refused by the argv check.
        var c2 = f.context; c2.mainBrowserPids = []; c2.hostBrowserPids = []; c2.ownedAutomationBrowsers = [Fixture.mainChrome]
        #expect(check(.automationBrowser(Fixture.mainChrome), context: c2) == .refused("looks like the main Chrome"))
    }

    @Test func mismatchedStartTime() {
        #expect(check(.session(ProcKey(pid: Fixture.claude.pid, startSec: 999))) == .mismatch)
        #expect(check(.automationBrowser(ProcKey(pid: Fixture.autoChrome.pid, startSec: 1))) == .mismatch)
        let stale = ProcKey(pid: Fixture.devChild.pid, startSec: 1)
        #expect(check(.group(pgid: Fixture.devLeader.pid, members: [Fixture.devLeader, stale], automationRoots: []),
                      table: f.table(dropping: [Fixture.appThing.pid])) == .mismatch)
        // pgid reused by something never recorded.
        #expect(check(.group(pgid: Fixture.devLeader.pid, members: [ProcKey(pid: 1234, startSec: 5)], automationRoots: []),
                      table: f.table(dropping: [Fixture.appThing.pid])) == .mismatch)
        #expect(check(.session(ProcKey(pid: 59_999, startSec: 1))) == .gone)
    }

    @Test func refusesGroupsWithPanesTmuxOrClaude() {
        // The pane shell's own process group.
        #expect(check(.group(pgid: Fixture.paneShell.pid, members: [Fixture.paneShell], automationRoots: []))
                == .refused("a tmux pane's process group"))
        // A group that contains a pane pid.
        let t = f.table(dropping: [Fixture.appThing.pid], extra: [
            ProcSample(key: ProcKey(pid: 50_700, startSec: 1), ppid: Fixture.paneShell.pid, pgid: 50_700, path: "/bin/zsh",
                       footprint: 1, rss: 1)])
        var c = f.context; c.panePids.insert(50_700)
        #expect(isRefused(check(.group(pgid: 50_700, members: [ProcKey(pid: 50_700, startSec: 1)], automationRoots: []),
                                table: t, context: c)))
        // The tmux server's group.
        #expect(isRefused(check(.group(pgid: Fixture.tmuxServer.pid, members: [Fixture.tmuxServer], automationRoots: []))))
        // A group containing a live claude.
        #expect(isRefused(check(.group(pgid: Fixture.claude.pid, members: [Fixture.claude], automationRoots: []))))
        // A group running under a live claude (its ppid chain passes through it).
        let under = f.table(dropping: [Fixture.appThing.pid], extra: [
            ProcSample(key: ProcKey(pid: 50_800, startSec: 1), ppid: Fixture.claude.pid, pgid: 50_800, path: "/usr/bin/node",
                       footprint: 1, rss: 1)])
        #expect(isRefused(check(.group(pgid: 50_800, members: [ProcKey(pid: 50_800, startSec: 1)], automationRoots: []),
                                table: under)))
    }

    @Test func refusesLauncherAndOddSignals() {
        var c = f.context; c.protectedPids = [Fixture.claude.pid]
        #expect(check(.session(Fixture.claude), context: c) == .refused("the session that launched Headroom"))
        #expect(isRefused(check(.session(Fixture.claude), signal: SIGHUP)))
    }

    @Test func dryRunSendsNothingAndJournals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hr-sig-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var e = HeadroomEnv(environment: ["HOME": home, "HEADROOM_SUPPORT_DIR": dir, "HEADROOM_DRY_RUN": "1"])
        e.dryRun = true
        let sender = RecordingSender()
        let j = Journal(env: e, source: "test")
        let s = Signaller(env: e, sender: sender, journal: j, args: f.args)
        #expect(s.send(.session(Fixture.claude), table: f.table(), context: f.context, reason: "t") == .dryRun)
        #expect(s.send(.session(ProcKey(pid: 1, startSec: 1)), table: f.table(), context: f.context, reason: "t")
                == .refused("pid 1 ≤ 1"))
        #expect(sender.calls.isEmpty)
        let entries = j.entries()
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.dryRun && $0.kind == "signal" && $0.source == "test" })
        #expect(entries[0].result == "dryRun" && entries[0].pid == Fixture.claude.pid && entries[0].startSec == 1000)
    }

    @Test func liveModeUsesSenderOnlyWhenAllowed() {
        let sender = RecordingSender()
        let s = Signaller(env: env(dryRun: false), sender: sender, args: f.args)
        #expect(s.send(.session(Fixture.claude), table: f.table(), context: f.context, reason: "t") == .sent)
        #expect(s.send(.session(ProcKey(pid: f.me, startSec: 11)), table: f.table(), context: f.context, reason: "t")
                == .refused("Headroom itself"))
        #expect(s.send(.group(pgid: Fixture.devLeader.pid, members: [Fixture.devLeader], automationRoots: []),
                       table: f.table(dropping: [Fixture.appThing.pid]), context: f.context, reason: "t") == .sent)
        #expect(sender.calls.map(\.0) == [Fixture.claude.pid, -Fixture.devLeader.pid])
        #expect(sender.calls.allSatisfy { $0.1 == SIGTERM })
    }
}
