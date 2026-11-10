// `--selftest sys|ownership` checks (SPEC §8.8), callable from the CLI and the app:
//
//     let report = await CoreSelfTest.run(["sys", "ownership"], env: env,
//                                         sessions: { await claude.sessionRecords() }, hosts: { await chrome.hosts() })
//     print(report.render()); exit(report.passed ? 0 : 1)
//
// Safety: `sys` spawns its own short-lived children (perl/sleep) and SIGTERMs only those. `ownership` is read-only:
// it scans processes, runs `tmux list-panes` (read-only) and reads the sessions JSON. It never signals anything.

import Darwin
import Foundation
import HeadroomContracts

public struct SelfTestCheck: Sendable, Hashable, Codable {
    public let group: String
    public let name: String
    public let passed: Bool
    public let detail: String
    public init(group: String, name: String, passed: Bool, detail: String) {
        self.group = group; self.name = name; self.passed = passed; self.detail = detail
    }
}

public struct SelfTestReport: Sendable, Codable {
    public var checks: [SelfTestCheck] = []
    /// Informational lines (bucket summaries etc.).
    public var notes: [String] = []
    public init() {}
    public var passed: Bool { checks.allSatisfy(\.passed) }
    public mutating func add(_ group: String, _ name: String, _ ok: Bool, _ detail: String) {
        checks.append(SelfTestCheck(group: group, name: name, passed: ok, detail: detail))
    }
    public func render() -> String {
        var lines = checks.map { "\($0.passed ? "PASS" : "FAIL")  \($0.group)/\($0.name): \($0.detail)" }
        if !notes.isEmpty { lines.append(""); lines += notes }
        lines.append("")
        lines.append(passed ? "selftest: all \(checks.count) checks passed"
                            : "selftest: \(checks.filter { !$0.passed }.count) of \(checks.count) checks FAILED")
        return lines.joined(separator: "\n")
    }
}

public enum CoreSelfTest {
    public static let groups = ["sys", "ownership"]

    public static func run(_ groups: [String], env: HeadroomEnv = .current,
                           sessions: (@Sendable () async -> [SessionRecord])? = nil,
                           hosts: (@Sendable () async -> [Wire.HostHello])? = nil) async -> SelfTestReport {
        var r = SelfTestReport()
        let want = groups.isEmpty ? Self.groups : groups
        if want.contains("sys") { await sys(&r, env: env) }
        if want.contains("ownership") {
            let recs = await sessions?() ?? SessionFiles.read(dir: env.sessionsDir)
            let hs = await hosts?() ?? []
            await ownership(&r, env: env, sessions: recs, hosts: hs)
        }
        return r
    }

    // MARK: - sys

    static func sys(_ r: inout SelfTestReport, env: HeadroomEnv) async {
        let sk = LiveSysKit(env: env)

        // Scan budget: 800 pids in < 5 ms (warm path cache, median of 7).
        _ = sk.scan()
        var times: [Double] = []
        var count = 0
        for _ in 0..<7 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let t = sk.scan()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            count = t.byPid.count
        }
        times.sort()
        let median = times[times.count / 2]
        let per800 = median * 800 / Double(max(count, 1))
        r.add("sys", "scan", per800 < 5,
              String(format: "%d pids in %.2f ms (median of 7) = %.2f ms per 800 pids (budget 5 ms)", count, median, per800))

        // Children we own: three perl processes holding 16/48/96 MB, and one sleep with a CLAUDE_* environment.
        let scratch = realPath(NSTemporaryDirectory())
        var kids: [Process] = []
        defer { for k in kids where k.isRunning { k.terminate() } }   // SIGTERM our own children only
        let sizes = [16, 48, 96]
        for mb in sizes {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = ["-e", "my $x = 'a' x (\(mb) * 1048576); $| = 1; print \"ready\\n\"; sleep 60;"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run(); kids.append(p) } catch {
                r.add("sys", "spawn", false, "could not start /usr/bin/perl: \(error)"); return
            }
            _ = out.fileHandleForReading.availableData   // wait for "ready"
        }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        sleeper.environment = ["CLAUDE_PID": "424242", "CLAUDE_CODE_SESSION_ID": "selftest-session",
                               "CLAUDE_CODE_OAUTH_TOKEN": "must-not-be-kept", "HEADROOM_SELFTEST_OTHER": "x",
                               "TMUX_PANE": "%999"]
        sleeper.currentDirectoryURL = URL(fileURLWithPath: scratch)
        sleeper.standardInput = FileHandle.nullDevice
        do { try sleeper.run(); kids.append(sleeper) } catch {
            r.add("sys", "spawn", false, "could not start /bin/sleep: \(error)"); return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Footprint vs `footprint -p` (within 1%).
        for (i, k) in kids.prefix(sizes.count).enumerated() {
            let pid = k.processIdentifier
            let before = LiveSysKit.footprint(pid) ?? 0
            let fr = await Shell.run("/usr/bin/footprint", ["-p", "\(pid)", "-f", "bytes", "--noCategories"], timeout: 10)
            let after = LiveSysKit.footprint(pid) ?? 0
            let ours = (before + after) / 2
            guard let theirs = parseFootprint(fr.stdout) else {
                r.add("sys", "footprint[\(sizes[i]) MB]", false, "could not parse `footprint -p \(pid)`: \(fr.stderr.prefix(200))")
                continue
            }
            let diff = abs(Double(ours) - Double(theirs)) / Double(max(theirs, 1))
            r.add("sys", "footprint[\(sizes[i]) MB]", diff <= 0.01 && ours > 0,
                  String(format: "pid %d: rusage %llu B vs footprint -p %llu B (%.3f%%)", pid, ours, theirs, diff * 100))
        }

        // The table sees our children with the right parent.
        let t = sk.scan()
        let mine = kids.map(\.processIdentifier)
        let parentsOK = mine.allSatisfy { t.byPid[$0]?.ppid == getpid() }
        r.add("sys", "ppid", parentsOK, "\(mine.count) children found in the table with ppid = \(getpid())")

        // KERN_PROCARGS2: argv, filtered env, cache.
        let sp = sleeper.processIdentifier
        if let key = t.byPid[sp]?.key, let a = sk.args(key) {
            // /bin/sleep is an Apple platform binary: the kernel hides its environment from KERN_PROCARGS2, so only
            // argv is checked here and the token must certainly not appear.
            r.add("sys", "procargs", a.argv == ["/bin/sleep", "60"] && a.env["CLAUDE_CODE_OAUTH_TOKEN"] == nil,
                  "child argv=\(a.argv); env keys=\(a.env.keys.sorted()) (platform binaries hide their environment)")
            let n = sk.cachedArgsCount
            _ = sk.args(key)
            r.add("sys", "procargs-cache", sk.cachedArgsCount == n, "second read served from the ProcKey cache")
            r.add("sys", "cwd", sk.cwd(sp) == scratch, "cwd(\(sp)) = \(sk.cwd(sp) ?? "nil"), expected \(scratch)")
            let stale = ProcKey(pid: key.pid, startSec: key.startSec - 5)
            r.add("sys", "isAlive", sk.isAlive(key) && !sk.isAlive(stale) && sk.args(stale) == nil,
                  "live key alive; same pid with another start time is not (pid-reuse guard)")
        } else {
            r.add("sys", "procargs", false, "could not read KERN_PROCARGS2 of our own child \(sp)")
        }
        // Our own process (not an Apple platform binary, so its environment is readable): argv and the
        // filtered CLAUDE_*/TMUX env must match what we know about ourselves.
        if let own = t.byPid[getpid()].flatMap({ sk.args($0.key) }) {
            let expected = ProcArgsParser.filterEnv(ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })
            r.add("sys", "procargs-self", own.argv == CommandLine.arguments && own.env == expected,
                  "own argv matches CommandLine.arguments; filtered env keys \(own.env.keys.sorted())")
        }

        // System memory sanity.
        let m = sk.systemMemory()
        var hw: UInt64 = 0; var sz = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &hw, &sz, nil, 0)
        let memOK = m.total == hw && m.total > 0 && m.used <= m.total && m.swapUsed <= m.swapTotal
            && m.appMemory + m.wired + m.compressed == m.used
        r.add("sys", "systemMemory", memOK,
              "total \(ByteFormat.short(m.total)), used \(ByteFormat.short(m.used)) (app \(ByteFormat.short(m.appMemory)), wired \(ByteFormat.short(m.wired)), compressed \(ByteFormat.short(m.compressed))), swap \(ByteFormat.short(m.swapUsed))/\(ByteFormat.short(m.swapTotal)), pressure \(m.pressure.name)")

        // Clean up and confirm our children are gone.
        let keys = kids.compactMap { t.byPid[$0.processIdentifier]?.key }
        for k in kids where k.isRunning { k.terminate() }
        // Poll instead of waitUntilExit(), which can hang on a cooperative-pool thread with no run loop.
        for _ in 0..<40 where kids.contains(where: \.isRunning) { try? await Task.sleep(nanoseconds: 50_000_000) }
        r.add("sys", "cleanup", keys.allSatisfy { !sk.isAlive($0) }, "\(keys.count) own children stopped (SIGTERM)")
    }

    /// realpath(3): the form the kernel reports for a cwd (/private/var/…, not /var/…).
    public static func realPath(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    /// Parses `phys_footprint: N B` from `footprint -f bytes`.
    public static func parseFootprint(_ s: String) -> Bytes? {
        for line in s.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("phys_footprint:") {
                let num = l.dropFirst("phys_footprint:".count).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first
                return num.flatMap { Bytes($0) }
            }
        }
        return nil
    }

    // MARK: - ownership (read-only on live data)

    static func ownership(_ r: inout SelfTestReport, env: HeadroomEnv, sessions: [SessionRecord],
                          hosts: [Wire.HostHello]) async {
        let sk = LiveSysKit(env: env)
        let panes = await TmuxClient(env: env).panes()
        let t = sk.scan()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let map = Ownership.assign(t, sessions: sessions, hosts: hosts, tmuxPanes: panes, sys: sk, env: env)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        r.add("ownership", "assign", true, String(format: "%d pids, %d owned, first pass %.1f ms (reads argv/env)",
                                                  t.byPid.count, map.owner.count, ms))
        let t1 = DispatchTime.now().uptimeNanoseconds
        _ = Ownership.assign(t, sessions: sessions, hosts: hosts, tmuxPanes: panes, sys: sk, env: env)
        let ms2 = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6
        r.notes.append(String(format: "assign with a warm argv cache: %.1f ms", ms2))

        let problems = Ownership.verify(map, table: t, tmuxPanes: panes, env: env, sys: sk)
        r.add("ownership", "invariants", problems.isEmpty,
              problems.isEmpty ? "no pid in two buckets; no live claude, pane pid or main browser inside a unit"
                               : problems.prefix(5).joined(separator: "; "))

        let liveOK = map.liveSessions.allSatisfy { map.owner[$0.pid] == .session($0) }
        r.add("ownership", "sessions", liveOK,
              "\(map.liveSessions.count) live of \(sessions.count) session files; \(map.staleSessionFiles.count) stale")
        let mains = map.browsers.filter(\.isMain)
        let autos = map.browsers.filter { !$0.isMain }
        let autoInMain = autos.filter { if case .chrome = map.owner[$0.key.pid] { true } else { false } }
        r.add("ownership", "automation-browsers", autoInMain.isEmpty,
              "\(mains.count) main, \(autos.count) automation; none counted in the Chrome section")

        // Summary by bucket kind.
        var byKind: [String: (n: Int, b: Bytes)] = [:]
        for (pid, o) in map.owner {
            let k: String
            switch o {
            case .chrome: k = "chrome"; case .session: k = "session"; case .claudeChild: k = "claudeChild"
            case .claudeBackground: k = "claudeBackground"; case .leftover: k = "leftover"
            case .otherChrome: k = "otherChrome"; case .unregisteredClaude: k = "unregisteredClaude"
            case .unowned: k = "unowned"
            }
            let f = t.byPid[pid]?.footprint ?? 0
            byKind[k, default: (0, 0)].n += 1
            byKind[k, default: (0, 0)].b += f
        }
        r.notes.append("buckets:")
        for (k, v) in byKind.sorted(by: { $0.value.b > $1.value.b }) {
            r.notes.append("  \(k.padding(toLength: 18, withPad: " ", startingAt: 0)) \(String(v.n).leftPad(4)) pids  \(ByteFormat.short(v.b).leftPad(8))")
        }
        let leftovers = Set(map.owner.values.filter { if case .leftover = $0 { true } else { false } })
        if !leftovers.isEmpty { r.notes.append("leftovers:") }
        for o in leftovers.sorted(by: { "\($0)" < "\($1)" }) {
            guard case let .leftover(pgid, dead) = o else { continue }
            for u in Ownership.units(of: o, in: t, map: map, sys: sk) {
                r.notes.append("  pgid \(pgid) (dead CLAUDE_PID \(dead)) \(ByteFormat.short(u.footprint).leftPad(8))  \(u.members.count) procs  \(u.command.prefix(80))")
            }
        }
        for b in autos {
            let owner = map.owner[b.key.pid].map { "\($0)" } ?? "unowned"
            r.notes.append("automation browser \(b.key.pid): owner \(owner), headless \(b.headless), remote-debugging \(b.remoteDebugging), user-data-dir \(b.userDataDir ?? "-")")
        }
    }
}

/// Minimal lenient reader for ~/.claude/sessions/*.json, used only when the caller does not pass
/// ClaudeProvider.sessionRecords() (HeadroomClaude provides the real one).
enum SessionFiles {
    static func read(dir: String) -> [SessionRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [SessionRecord] = []
        for n in names.sorted() where n.hasSuffix(".json") {
            let path = dir + "/" + n
            guard let d = fm.contents(atPath: path),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            func str(_ k: String) -> String? { j[k] as? String }
            func num(_ k: String) -> Double? { (j[k] as? NSNumber)?.doubleValue ?? (j[k] as? String).flatMap(Double.init) }
            out.append(SessionRecord(pid: num("pid").flatMap { Int32(exactly: $0) }, sessionId: str("sessionId"), cwd: str("cwd"),
                                     startedAt: num("startedAt"), procStart: str("procStart"), version: str("version"),
                                     kind: str("kind"), entrypoint: str("entrypoint"), tmux: str("tmux"),
                                     name: str("name"), nameSource: str("nameSource"), status: str("status"),
                                     statusUpdatedAt: num("statusUpdatedAt"), updatedAt: num("updatedAt"),
                                     bridgeSessionId: str("bridgeSessionId"), filePath: path))
        }
        return out
    }
}

extension String {
    fileprivate func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
