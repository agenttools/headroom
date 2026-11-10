// LiveSysKit against our OWN children only (spawned here, SIGTERMed here), the KERN_PROCARGS2 parser on
// synthetic buffers, and Shell.
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomCore

@Suite struct ProcArgsParserTests {
    func buffer(argc: Int32, exec: String, argv: [String], env: [String], pad: Int = 3) -> Data {
        var d = Data()
        withUnsafeBytes(of: argc) { d.append(contentsOf: $0) }
        d.append(contentsOf: Array(exec.utf8)); d.append(0)
        d.append(contentsOf: [UInt8](repeating: 0, count: pad))
        for a in argv { d.append(contentsOf: Array(a.utf8)); d.append(0) }
        for e in env { d.append(contentsOf: Array(e.utf8)); d.append(0) }
        d.append(contentsOf: [0, 0, 0, 0])
        return d
    }

    @Test func parsesArgvWithEmptyEntriesAndFiltersEnv() {
        let d = buffer(argc: 4, exec: "/opt/homebrew/bin/node", argv: ["node", "", "server.js", "--port=3"],
                       env: ["PATH=/usr/bin", "CLAUDE_PID=4242", "CLAUDE_CODE_SESSION_ID=abc",
                             "CLAUDE_CODE_OAUTH_TOKEN=secret", "CLAUDE_API_KEY=sk", "ANTHROPIC_API_KEY=sk2",
                             "TMUX_PANE=%3", "CLAUDE_CODE_ENTRYPOINT=cli", "WEIRD"])
        let p = ProcArgsParser.parse(d)
        #expect(p?.execPath == "/opt/homebrew/bin/node")
        #expect(p?.argv == ["node", "", "server.js", "--port=3"])
        #expect(p?.env.count == 9)
        let a = d.withUnsafeBytes { ProcArgsParser.procArgs($0) }
        #expect(a?.env == ["CLAUDE_PID": "4242", "CLAUDE_CODE_SESSION_ID": "abc", "TMUX_PANE": "%3",
                           "CLAUDE_CODE_ENTRYPOINT": "cli"])
    }

    @Test func rejectsMalformed() {
        #expect(ProcArgsParser.parse(Data([1, 0])) == nil)
        var neg = Data(); withUnsafeBytes(of: Int32(-1)) { neg.append(contentsOf: $0) }
        #expect(ProcArgsParser.parse(neg) == nil)
        // argc larger than what is present: returns what exists, no crash.
        let d = buffer(argc: 10, exec: "/bin/x", argv: ["x"], env: [], pad: 0)
        #expect(ProcArgsParser.parse(d)?.argv.first == "x")
    }

    @Test func secretsAreNeverKept() {
        for k in ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_SECRET", "CLAUDE_PASSWORD", "CLAUDE_AUTH_X", "CLAUDE_KEY",
                  "CLAUDE_CODE_SESSION_ACCESS_TOKEN", "AWS_SECRET_ACCESS_KEY", "HOME"] {
            #expect(!ProcArgsParser.keeps(k), "\(k)")
        }
        for k in ["CLAUDE_PID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT", "TMUX", "TMUX_PANE"] {
            #expect(ProcArgsParser.keeps(k), "\(k)")
        }
    }
}

/// A non-Apple sleeper compiled once per test run. Apple platform binaries (/bin/sleep, perl, zsh …) have their
/// environment hidden from KERN_PROCARGS2, so env tests need a binary like this (or node/bun, as in real life).
enum Dummy {
    static let path: String = {
        let dir = makeScratch("dummy")
        write(dir + "/d.c", "#include <unistd.h>\n#include <stdlib.h>\nint main(int c, char **v) { sleep(c > 1 ? atoi(v[1]) : 30); return 0; }\n")
        let r = Shell.runSync("/usr/bin/cc", ["-o", dir + "/hr-dummy", dir + "/d.c"], timeout: 120)
        precondition(r.ok, "cc failed: \(r.stderr)")
        return dir + "/hr-dummy"
    }()
}

/// Spawns `/bin/sleep` children we own; they are always SIGTERMed by the test that started them.
final class OwnChild {
    let p = Process()
    init(_ args: [String] = ["30"], env: [String: String] = [:], cwd: String? = nil,
         exe: String = "/bin/sleep") throws {
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
    var pid: Int32 { p.processIdentifier }
    func stop() {
        if p.isRunning { p.terminate() }
        // Poll rather than waitUntilExit(), which can hang off the main thread (no run loop).
        for _ in 0..<200 where p.isRunning { usleep(10_000) }
    }
    deinit { stop() }
}

@Suite(.serialized) struct LiveSysKitTests {
    let sk = LiveSysKit(env: HeadroomEnv(environment: ProcessInfo.processInfo.environment))

    @Test func scanSeesSelfAndChildren() throws {
        let c = try OwnChild()
        defer { c.stop() }
        let t = sk.scan()
        #expect(t.byPid.count > 50)
        let me = try #require(t.byPid[getpid()])
        #expect(me.footprint > 0 && me.rss > 0 && me.uid == getuid())
        #expect(me.path.hasPrefix("/"))
        let kid = try #require(t.byPid[c.pid])
        #expect(kid.ppid == getpid())
        #expect(kid.path == "/bin/sleep")
        #expect(t.children[getpid()]?.contains(c.pid) == true)
        #expect(t.ancestors(of: c.pid).first == getpid())
        #expect(abs(kid.key.startSec - Int(Date().timeIntervalSince1970)) < 60)
    }

    @Test func argsEnvCwdAndPidReuseGuard() throws {
        let dir = makeScratch("cwd")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let c = try OwnChild(["31"], env: ["CLAUDE_PID": "777", "CLAUDE_CODE_OAUTH_TOKEN": "nope", "FOO": "bar"],
                             cwd: dir, exe: Dummy.path)
        defer { c.stop() }
        let t = sk.scan()
        let key = try #require(t.byPid[c.pid]?.key)
        #expect(t.byPid[c.pid]?.path == Dummy.path)
        let a = try #require(sk.args(key))
        #expect(a.argv.count == 2 && a.argv[0].hasSuffix("/hr-dummy") && a.argv[1] == "31")
        #expect(a.env == ["CLAUDE_PID": "777"])              // token and FOO dropped

        // A platform binary's environment is hidden by the kernel (documented behaviour we rely on knowing).
        let p = try OwnChild(["32"], env: ["CLAUDE_PID": "778"])
        defer { p.stop() }
        let pk = try #require(sk.scan().byPid[p.pid]?.key)
        #expect(sk.args(pk)?.argv == ["/bin/sleep", "32"])
        #expect(sk.args(pk)?.env == [:])
        #expect(sk.cwd(c.pid) == dir)
        #expect(sk.isAlive(key))
        let wrong = ProcKey(pid: key.pid, startSec: key.startSec + 3)
        #expect(!sk.isAlive(wrong))
        #expect(sk.args(wrong) == nil)
        c.stop()
        #expect(!sk.isAlive(key))
        #expect(sk.cwd(424_242_4) == nil)
    }

    @Test func footprintMatchesFootprintTool() async throws {
        let c = try OwnChild(["-e", "my $x = 'a' x (32 * 1048576); sleep 30;"], exe: "/usr/bin/perl")
        defer { c.stop() }
        try await Task.sleep(nanoseconds: 400_000_000)
        let ours = try #require(LiveSysKit.footprint(c.pid))
        let r = await Shell.run("/usr/bin/footprint", ["-p", "\(c.pid)", "-f", "bytes", "--noCategories"], timeout: 10)
        let theirs = try #require(CoreSelfTest.parseFootprint(r.stdout))
        #expect(ours >= 32 << 20)
        #expect(abs(Double(ours) - Double(theirs)) / Double(theirs) <= 0.01, "\(ours) vs \(theirs)")
    }

    @Test func systemMemoryIsSane() {
        let m = sk.systemMemory()
        #expect(m.total >= 8 << 30)
        #expect(m.used > 0 && m.used <= m.total)
        #expect(m.used == m.appMemory + m.wired + m.compressed)
        #expect(m.swapUsed <= m.swapTotal)
        #expect(Pressure.allCases.contains(m.pressure))
    }

    @Test func argsCacheIsPrunedToLiveKeys() throws {
        let local = LiveSysKit(env: HeadroomEnv(environment: [:]))
        let t = local.scan()
        for s in t.byPid.values.prefix(200) { _ = local.args(s.key) }
        let fake = (0..<2000).map { ProcKey(pid: 900_000 + Int32($0), startSec: 1) }
        for k in fake { _ = local.args(k) }
        #expect(local.cachedArgsCount >= 2000)
        _ = local.scan()
        #expect(local.cachedArgsCount <= 200)                // only keys of live processes survive
    }

    @Test func selftestSysPasses() async {
        let r = await CoreSelfTest.run(["sys"], env: HeadroomEnv(environment: ProcessInfo.processInfo.environment))
        // The scan budget is for release builds; in a debug test build only the correctness checks must pass.
        let failures = r.checks.filter { !$0.passed && $0.name != "scan" }
        #expect(failures.isEmpty, "\(r.render())")
        #expect(r.checks.count >= 10)
    }
}

@Suite struct ShellTests {
    @Test func stdoutStderrStatus() async {
        let r = await Shell.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(r.stdout == "out\n" && r.stderr == "err\n" && r.status == 3 && !r.ok && !r.timedOut)
    }

    @Test func stdinIsWritten() async {
        let r = await Shell.run("/bin/cat", [], stdin: Data("hello\n".utf8))
        #expect(r.ok && r.stdout == "hello\n")
        // A child that ignores stdin and exits must not kill us with SIGPIPE.
        let big = Data(repeating: 65, count: 4 << 20)
        let r2 = await Shell.run("/usr/bin/true", [], stdin: big)
        #expect(r2.ok)
    }

    @Test func largeOutputDoesNotDeadlock() async {
        let r = await Shell.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero | tr '\\0' a"], timeout: 10)
        #expect(r.ok && r.stdout.utf8.count == 3_000_000)
    }

    @Test func timeoutStopsOnlyOurChild() async {
        let t0 = Date()
        let r = await Shell.run("/bin/sleep", ["30"], timeout: 0.3)
        #expect(r.timedOut && !r.ok)
        #expect(Date().timeIntervalSince(t0) < 3)
    }

    @Test func cancellationStopsTheChild() async {
        let t0 = Date()
        let task = Task { await Shell.run("/bin/sleep", ["30"], timeout: 20) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let r = await task.value
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(t0) < 5)
    }

    @Test func missingExecutable() async {
        let r = await Shell.run("/nonexistent/binary", [])
        #expect(r.status == -1 && !r.ok)
    }

    @Test func environmentAndCwd() async {
        let dir = makeScratch("shell")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = await Shell.run("/bin/sh", ["-c", "echo $HR_X; pwd -P"], environment: ["HR_X": "42"], cwd: dir)
        #expect(r.stdout == "42\n\(dir)\n")
    }
}

@Suite struct StaticSysKitTests {
    @Test func servesFixtureAndGuardsKeys() {
        let fx = OwnershipWorld.fixture
        let sys = fx.sys
        let k = fx.table.byPid[41259]!.key
        #expect(sys.args(k)?.argv0 == KnownPaths.chromeExecutable)
        #expect(sys.args(ProcKey(pid: 41259, startSec: 1)) == nil)
        #expect(sys.isAlive(k))
        #expect(sys.scan().byPid.count == fx.table.byPid.count)
    }
}

@Suite struct ScanBudgetTests {
    /// SPEC §11: a scan of 800 pids in under 5 ms. Enforced in optimised builds
    /// (`swift test -c release -Xswiftc -enable-testing`); debug builds only report the figure.
    @Test func scanBudget() {
        let sk = LiveSysKit(env: HeadroomEnv(environment: [:]))
        _ = sk.scan()
        var times: [Double] = []
        var n = 0
        for _ in 0..<9 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            n = sk.scan().byPid.count
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        times.sort()
        let per800 = times[4] * 800 / Double(n)
        print(String(format: "scan: %d pids, median %.2f ms, %.2f ms per 800 pids", n, times[4], per800))
        #if !DEBUG
        #expect(per800 < 5)
        #endif
    }
}

/// Read-only live checks, opt-in: HEADROOM_LIVE_SELFTEST=1 swift test --filter LiveSelfTest
@Suite struct LiveSelfTest {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEADROOM_LIVE_SELFTEST"] == "1"))
    func ownershipOnLiveSystem() async {
        let r = await CoreSelfTest.run(["ownership"], env: HeadroomEnv(environment: ProcessInfo.processInfo.environment))
        print(r.render())
        #expect(r.passed)
    }
}
