// A replayable process world for ownership tests (SPEC §3 "Unit tests replay the captured ps.txt and
// psargs.txt fixtures"). Other WPs can use it too: `StaticSysKit(fixture:)` serves it as a SysKit.
//
// Inputs:
//   ps.txt      `ps -axo pid,ppid,pgid,tpgid,rss,stat,comm` (with header)
//   psargs.txt  `ps -axo pid=,ppid=,rss=,args=` (newlines inside args escaped as \012)
//   overlay     JSON (Tests/Fixtures/ownership-overlay.json): what `ps` cannot show — the CLAUDE_* environment,
//               start times, claude binary paths, sessions JSON, tmux servers, extra processes.
//
// argv is rebuilt from the `args` column, which loses quoting: a token that does not start with "-" is joined
// back onto a preceding `--flag=value` token (so `--database=/…/Application Support/…` survives), and argv0 is
// taken from the ps `comm` column when the args start with it (so "/Applications/Google Chrome.app/…" survives).

import Foundation
import HeadroomContracts

public struct OwnershipFixture: Sendable {
    public var table: ProcessTable
    public var argsByPid: [Int32: ProcArgs]
    public var cwdByPid: [Int32: String]
    public var system: SystemMemory?
    public var sessions: [SessionRecord]
    public var tmuxPanes: [TmuxPane]
    public var hosts: [Wire.HostHello]
    public var env: HeadroomEnv
    public var uid: UInt32

    public init(table: ProcessTable, argsByPid: [Int32: ProcArgs], cwdByPid: [Int32: String] = [:],
                system: SystemMemory? = nil, sessions: [SessionRecord] = [], tmuxPanes: [TmuxPane] = [],
                hosts: [Wire.HostHello] = [], env: HeadroomEnv, uid: UInt32 = 501) {
        self.table = table; self.argsByPid = argsByPid; self.cwdByPid = cwdByPid; self.system = system
        self.sessions = sessions; self.tmuxPanes = tmuxPanes; self.hosts = hosts; self.env = env; self.uid = uid
    }

    public var sys: StaticSysKit { StaticSysKit(fixture: self) }

    /// Runs Ownership.assign over the fixture (never excludes the test runner's own pid).
    public func assign() -> OwnershipMap {
        Ownership.assign(table, sessions: sessions, hosts: hosts, tmuxPanes: tmuxPanes, sys: sys, env: env,
                         excluding: [], uid: uid)
    }

    // MARK: - Overlay

    public struct Overlay: Codable, Sendable {
        public struct EnvTree: Codable, Sendable { public var root: Int32; public var env: [String: String] }
        public struct Extra: Codable, Sendable {
            public var pid, ppid, pgid: Int32
            public var rssKB: UInt64
            public var startOffset: Int?
            public var path: String
            public var argv: [String]
            public var env: [String: String]?
            public var cwd: String?
        }
        public struct Stale: Codable, Sendable { public var pid: Int32; public var startOffset: Int; public var file: String }
        public var home: String
        public var uid: UInt32?
        public var baseStartSec: Int
        public var claudePath: String
        public var commPaths: [String: String]
        public var tmuxServers: [Int32]
        public var envTrees: [EnvTree]
        public var claudeChildEnv: Bool
        public var extraProcesses: [Extra]
        public var unregisteredClaude: [Int32]
        public var staleSessions: [Stale]
        public var hosts: [Wire.HostHello]?
    }

    // MARK: - Loading

    public static func load(ps: URL, psargs: URL, overlay: URL) throws -> OwnershipFixture {
        let o = try JSONDecoder().decode(Overlay.self, from: Data(contentsOf: overlay))
        return build(ps: try String(contentsOf: ps, encoding: .utf8),
                     psargs: try String(contentsOf: psargs, encoding: .utf8), overlay: o)
    }

    struct PSRow { var pid, ppid, pgid: Int32; var rssKB: UInt64; var comm: String }

    static func parsePS(_ text: String) -> [PSRow] {
        var out: [PSRow] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard f.count == 7, let pid = Int32(f[0]), let ppid = Int32(f[1]), let pgid = Int32(f[2]),
                  let rss = UInt64(f[4]) else { continue }   // skips the header
            out.append(PSRow(pid: pid, ppid: ppid, pgid: pgid, rssKB: rss,
                              comm: f[6].trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    static func parsePSArgs(_ text: String) -> [Int32: String] {
        var out: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]) else { continue }
            out[pid] = f[3].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\012", with: "\n")
        }
        return out
    }

    /// Rebuilds argv from a `ps args` string (see the file header for the heuristics).
    public static func splitArgs(_ args: String, comm: String) -> [String] {
        var rest = Substring(args)
        var argv: [String] = []
        if comm.hasPrefix("/"), args.hasPrefix(comm) {
            argv.append(comm); rest = rest.dropFirst(comm.count)
        }
        for tok in rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if let last = argv.last, !tok.hasPrefix("-"), last.hasPrefix("--"), last.contains("="),
               last.contains("/") {
                argv[argv.count - 1] = last + " " + tok
            } else {
                argv.append(tok)
            }
        }
        return argv
    }

    static func build(ps: String, psargs: String, overlay o: Overlay) -> OwnershipFixture {
        let rows = parsePS(ps)
        let argsText = parsePSArgs(psargs)
        let uid = o.uid ?? 501
        let base = o.baseStartSec
        var samples: [ProcSample] = []
        var argvByPid: [Int32: [String]] = [:]
        var envByPid: [Int32: [String: String]] = [:]
        var cwdByPid: [Int32: String] = [:]
        var claudePids: Set<Int32> = []

        for r in rows {
            let argv = argsText[r.pid].map { splitArgs($0, comm: r.comm) } ?? [r.comm]
            let path: String
            if r.comm == "claude" || Ownership.basename(argv.first ?? "") == "claude" {
                path = o.claudePath; claudePids.insert(r.pid)
            } else if r.comm.hasPrefix("/") {
                path = r.comm
            } else if let a0 = argv.first, a0.hasPrefix("/") {
                path = a0
            } else {
                path = o.commPaths[r.comm] ?? "/usr/local/bin/\(r.comm)"
            }
            samples.append(ProcSample(key: ProcKey(pid: r.pid, startSec: base), ppid: r.ppid, pgid: r.pgid,
                                      uid: uid, path: path, footprint: r.rssKB * 1024, rss: r.rssKB * 1024))
            argvByPid[r.pid] = argv
        }
        for e in o.extraProcesses {
            samples.append(ProcSample(key: ProcKey(pid: e.pid, startSec: base + (e.startOffset ?? 0)), ppid: e.ppid,
                                      pgid: e.pgid, uid: uid, path: e.path,
                                      footprint: e.rssKB * 1024, rss: e.rssKB * 1024))
            argvByPid[e.pid] = e.argv
            if let cwd = e.cwd { cwdByPid[e.pid] = cwd }
        }
        let table = ProcessTable(samples: samples, takenAt: Date(timeIntervalSince1970: TimeInterval(base + 86_400)))

        // Environment: inherited trees first, then each claude's CLAUDE_PID for its descendants, then extras.
        for tree in o.envTrees {
            for p in [tree.root] + table.descendants(of: tree.root) {
                envByPid[p, default: [:]].merge(tree.env) { _, new in new }
            }
        }
        if o.claudeChildEnv {
            for pid in table.byPid.keys {
                if let c = table.ancestors(of: pid).first(where: { claudePids.contains($0) }) {
                    envByPid[pid, default: [:]]["CLAUDE_PID"] = String(c)
                }
            }
        }
        for e in o.extraProcesses {
            if let env = e.env { envByPid[e.pid] = env } else { envByPid[e.pid] = nil }
        }

        var args: [Int32: ProcArgs] = [:]
        for (pid, argv) in argvByPid {
            args[pid] = ProcArgs(argv: argv, env: envByPid[pid] ?? [:])
        }

        // Sessions JSON: every claude except the unregistered ones; stale files with the wrong start time.
        let unregistered = Set(o.unregisteredClaude)
        let staleByPid = Dictionary(o.staleSessions.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var sessions: [SessionRecord] = []
        for pid in claudePids.sorted() where !unregistered.contains(pid) && staleByPid[pid] == nil {
            let start = table.byPid[pid]!.key.startSec
            sessions.append(SessionRecord(pid: pid, sessionId: "fixture-\(pid)", cwd: o.home + "/work",
                                          startedAt: Double(start) * 1000 + 250,
                                          procStart: procStartString(start), status: "idle",
                                          filePath: "\(pid).json"))
        }
        for s in o.staleSessions {
            sessions.append(SessionRecord(pid: s.pid, sessionId: "stale-\(s.pid)", cwd: o.home + "/work",
                                          startedAt: Double(base + s.startOffset) * 1000,
                                          procStart: procStartString(base + s.startOffset), status: "idle",
                                          filePath: s.file))
        }

        // tmux panes: every direct child of a tmux server is a pane shell.
        var panes: [TmuxPane] = []
        var n = 0
        for server in o.tmuxServers {
            for child in table.children[server] ?? [] {
                n += 1
                panes.append(TmuxPane(paneId: "%\(n)", panePid: child, paneActive: true, windowActive: n == 1,
                                      sessionAttached: 1, session: "fixture", windowIndex: n, paneIndex: 1,
                                      windowName: "w\(n)", paneTitle: "", currentCommand: "zsh"))
            }
        }

        var env = HeadroomEnv(environment: ["HOME": o.home])
        env.claudeVersionsGlobs = []
        return OwnershipFixture(table: table, argsByPid: args, cwdByPid: cwdByPid, system: nil, sessions: sessions,
                                tmuxPanes: panes, hosts: o.hosts ?? [], env: env, uid: uid)
    }

    /// Formats a start time the way Claude writes `procStart` ("Tue Sep 29 16:28:53 2026", UTC).
    public static func procStartString(_ sec: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(sec)))
    }
}
