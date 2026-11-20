// SPEC §3: the no-double-count pass. Every pid ends up in at most one bucket.
//
// Order of the passes (each pass only claims pids that are still unowned):
//   1. Chrome browser instances. Main browsers (host hello browserPid, or the no-host heuristics) claim
//      their whole ppid subtree as .chrome. Automation browsers are only *noted* here.
//   2. Live Claude sessions (pid exists, claude binary, procStart ±2 s or startedAt ±60 s): the claude
//      pid is .session, its ppid descendants .claudeChild (never walking into another live session).
//   5. (run before 3) Unregistered claude: a claude-binary process with no live session JSON is
//      .unregisteredClaude; its descendants are .claudeChild of it.
//   3. Environment-linked units (CLAUDE_PID in env), after strict exclusions. Root = the highest ancestor
//      that is still env-linked (same CLAUDE_PID) and not excluded; root + subtree = one unit (an
//      automation browser under it comes with it). Live CLAUDE_PID → .claudeBackground, otherwise
//      .leftover(pgid of root, dead CLAUDE_PID).
//   4. Automation browsers not claimed above → .otherChrome (browser + subtree).
//   6. Session files that failed step 2 → staleSessionFiles.
//
// Exclusions for step-3 roots (strict by design: a missed leftover costs memory, a false one could kill
// the user's work):
//   - path inside any `.app` bundle;
//   - argv0 basename ∈ {tmux, limactl, colima, docker, ssh-agent}, or argv0 starts with "-" (login shell);
//   - the ppid chain (including the pid itself) passes through a tmux process, a tmux pane_pid, a Rex server,
//     a Rex pane process (RexTopology.blockRoots), a live claude, or (extension of §3) any `.app` process — e.g.
//     `aerospace` spawned by Hammerspoon.app;
//   - its CLAUDE_PID (or CLAUDE_CODE_SESSION_ID) equals one found in the env of a tmux process or pane shell, or of
//     a Rex server or Rex pane process: that value was inherited from the terminal, not set by a claude Bash tool.
//
// Other rules worth knowing:
//   - With a host connected, only host-named browsers are main; the argv heuristics apply only without one.
//   - chrome_crashpad_handler is reparented to launchd; it joins the browser whose user-data-dir holds its
//     --database (so the Chrome section includes it, and an automation browser's crashpad goes with its owner).
//   - The claude executable is multi-call (Claude Code runs it as `ugrep`/`rg`); only argv0 "claude" (or the
//     binary's own name) counts as a claude process for steps 2 and 5.
//   - Only the caller's uid can own step-3 units. Apple platform binaries (/bin/zsh, /usr/bin/caffeinate …) have
//     their environment hidden by the kernel, so they are never env-linked roots themselves; they still come
//     along inside a unit's subtree.
//
// Headroom's own pids (the caller's pid and connected hosts) are never assigned, so the footer's
// "Headroom itself" figure is not also counted in a section.

import Foundation
import HeadroomContracts

public enum Ownership {
    /// argv0 basenames that are never a step-3 root.
    public static let excludedArgv0: Set<String> = ["tmux", "limactl", "colima", "docker", "ssh-agent"]
    /// procStart tolerance (seconds) and the startedAt fallback tolerance.
    public static let procStartTolerance = 2
    public static let startedAtTolerance = 60.0

    /// Assigns every pid to at most one Owner (SPEC §3 steps 1–6).
    /// - sessions: parsed ~/.claude/sessions/*.json (ClaudeProvider.sessionRecords())
    /// - hosts: connected native-messaging hosts (ChromeProvider.hosts()); browserPid marks the main browser
    /// - tmuxPanes: TmuxClient.panes(), for the tmux-server / pane_pid exclusions (Rex servers and panes need no
    ///   input: RexProcess.topology finds them in `t`, using sys.parentPid for the hidden root-owned `login`)
    /// - excluding: pids never assigned (defaults to this process: Headroom counts itself in the footer)
    /// - uid: only this user's processes can become step-3 units (nil = any uid; fixtures)
    public static func assign(_ t: ProcessTable, sessions: [SessionRecord], hosts: [Wire.HostHello],
                              tmuxPanes: [TmuxPane], sys: any SysKit, env: HeadroomEnv,
                              excluding: Set<Int32> = [getpid()], uid: UInt32? = getuid()) -> OwnershipMap {
        var pass = Pass(t: t, sys: sys, env: env)
        pass.never = excluding.union(hosts.map(\.hostPid))

        // Step 1 — browsers.
        // A connected host names the main browser(s); the argv heuristics apply only when no host is connected
        // (or every hello names a pid that is gone).
        let hostBrowserPids = Set(hosts.map(\.browserPid)).filter { t.byPid[$0] != nil }
        var automation: [BrowserInstance] = []
        var browsers: [BrowserInstance] = []
        for pid in t.byPid.keys.sorted() {
            let s = t.byPid[pid]!
            guard let b = browserInstance(s, pass: &pass, hostBrowserPids: hostBrowserPids, env: env) else { continue }
            browsers.append(b)
            if b.isMain {
                pass.claimTree(pid, as: .chrome(browserPid: pid))
            } else {
                automation.append(b)
            }
        }

        // Step 1b — crashpad handlers reparented to launchd belong to the browser whose user-data-dir holds
        // their --database (main browsers now; automation browsers once their owner is known, below).
        let crashpads = crashpadHandlers(t, pass: &pass, browsers: browsers, env: env)
        for (pid, b) in crashpads where b.isMain { pass.claimTree(pid, as: .chrome(browserPid: b.key.pid)) }

        // Step 2 — live sessions.
        var liveByPid: [Int32: ProcKey] = [:]
        var stale: [String] = []
        for rec in sessions.sorted(by: { ($0.pid ?? 0, $0.filePath ?? "") < ($1.pid ?? 0, $1.filePath ?? "") }) {
            let file = rec.filePath ?? rec.pid.map { "\($0).json" } ?? "?"
            guard let pid = rec.pid, let s = t.byPid[pid], liveByPid[pid] == nil,
                  isLive(rec, sample: s, pass: &pass, env: env) else {
                stale.append(file); continue
            }
            liveByPid[pid] = s.key
        }
        let sessionPids = Set(liveByPid.keys)
        for (pid, key) in liveByPid { pass.set(pid, .session(key)) }
        for (pid, key) in liveByPid.sorted(by: { $0.key < $1.key }) {
            pass.claimDescendants(of: pid, as: .claudeChild(key), stopAt: sessionPids)
        }

        // Step 5 (before 3, so CLAUDE_PID can point at an unregistered-but-alive claude).
        var claudeByPid = liveByPid
        let unregistered = t.byPid.values
            .filter { pass.owner[$0.pid] == nil && !pass.never.contains($0.pid) }
            .filter { isClaudeProcess($0, pass: &pass, env: env) }
            .sorted { ($0.key.startSec, $0.pid) < ($1.key.startSec, $1.pid) }
        for s in unregistered where pass.owner[s.pid] == nil {
            pass.set(s.pid, .unregisteredClaude(s.key))
            claudeByPid[s.pid] = s.key
            pass.claimDescendants(of: s.pid, as: .claudeChild(s.key), stopAt: sessionPids)
        }

        // Step 3 — env-linked units.
        let panePids = Set(tmuxPanes.map(\.panePid))
        var tmuxPids = Set(panePids.compactMap { t.byPid[$0]?.ppid }.filter { $0 > 1 })
        for s in t.byPid.values where pass.argv0Base(s.pid) == "tmux" { tmuxPids.insert(s.pid) }
        // Rex servers and each block's first process (the counterpart of the tmux server and pane_pids). Pure:
        // argv is read only for executables named `rex`, and no rex command runs.
        let rex = RexProcess.topology(in: t, sys: sys)
        let claudePids = Set(claudeByPid.keys)

        func selfExcluded(_ pid: Int32) -> Bool {
            guard let s = t.byPid[pid] else { return true }
            if isInsideApp(s.path) { return true }
            let a0 = pass.argv0(pid)
            if a0.hasPrefix("-") { return true }
            return excludedArgv0.contains(basename(a0))
        }
        // Strict: an ancestor that is itself excluded (tmux, limactl, a login shell, any .app) excludes the
        // whole branch, so e.g. a child of colima's hostagent never becomes a unit root.
        func chainExcluded(_ pid: Int32) -> Bool {
            for p in [pid] + t.ancestors(of: pid) {
                if tmuxPids.contains(p) || panePids.contains(p) || claudePids.contains(p) { return true }
                if rex.servers.contains(p) || rex.blockRoots.contains(p) { return true }
                if p != pid, t.byPid[p] != nil, selfExcluded(p) { return true }
            }
            return false
        }
        // A terminal environment can itself carry CLAUDE_PID: a tmux server started from a claude Bash tool keeps
        // that claude's CLAUDE_PID (and CLAUDE_CODE_SESSION_ID) forever, and every pane — and everything the user
        // types there — inherits it. Once such a process is reparented to launchd (nohup, a daemonizing
        // postgres/redis, a killed window) its ppid chain no longer shows the tmux server, so the chain
        // exclusion cannot catch it. Values found on any tmux process or pane shell are therefore "inherited"
        // and never make a process env-linked (review finding, 2026-09-30). The same holds for a Rex server (the
        // rex CLI autostarts one, possibly from a claude Bash tool) and Rex pane processes.
        var inheritedClaudePids: Set<Int32> = []
        var inheritedSessionIds: Set<String> = []
        for p in tmuxPids.union(panePids).union(rex.servers).union(rex.blockRoots) where t.byPid[p] != nil {
            guard let e = pass.args(p)?.env else { continue }
            if let cp = e["CLAUDE_PID"].flatMap({ Int32($0) }), cp > 0 { inheritedClaudePids.insert(cp) }
            if let sid = e["CLAUDE_CODE_SESSION_ID"], !sid.isEmpty { inheritedSessionIds.insert(sid) }
        }
        // Candidates: unowned, env-linked, not excluded.
        var linkedPid: [Int32: Int32] = [:]
        for s in t.byPid.values where pass.owner[s.pid] == nil && !pass.never.contains(s.pid) {
            guard uid == nil || s.uid == uid!, s.pid > 1,
                  !isInsideApp(s.path),                       // cheap check before reading env
                  let e = pass.args(s.pid)?.env,
                  let cp = e["CLAUDE_PID"].flatMap({ Int32($0) }), cp > 0 else { continue }
            guard !inheritedClaudePids.contains(cp),
                  !(e["CLAUDE_CODE_SESSION_ID"].map { inheritedSessionIds.contains($0) } ?? false) else { continue }
            guard !selfExcluded(s.pid), !chainExcluded(s.pid) else { continue }
            linkedPid[s.pid] = cp
        }
        // Roots: climb while the parent is a candidate with the same CLAUDE_PID.
        var roots: Set<Int32> = []
        for (pid, cp) in linkedPid {
            var cur = pid
            var seen: Set<Int32> = [pid]
            while let pp = t.byPid[cur]?.ppid, pp > 1, linkedPid[pp] == cp, seen.insert(pp).inserted { cur = pp }
            roots.insert(cur)
        }
        let orderedRoots = roots.compactMap { t.byPid[$0] }
            .sorted { ($0.key.startSec, $0.pid) < ($1.key.startSec, $1.pid) }
        for r in orderedRoots where pass.owner[r.pid] == nil {
            let cp = linkedPid[r.pid]!
            let o: Owner
            if let ck = claudeByPid[cp], ck.startSec <= r.key.startSec + procStartTolerance {
                o = .claudeBackground(ck)
            } else {
                o = .leftover(pgid: r.pgid, deadClaudePid: cp)
            }
            pass.claimTree(r.pid, as: o, stopAt: claudePids)
        }

        // Step 4 — automation browsers nobody claimed.
        for b in automation where pass.owner[b.key.pid] == nil {
            pass.claimTree(b.key.pid, as: .otherChrome(browserPid: b.key.pid), stopAt: claudePids)
        }
        for (pid, b) in crashpads where !b.isMain {
            if let o = pass.owner[b.key.pid] { pass.claimTree(pid, as: o) }
        }

        return OwnershipMap(owner: pass.owner, browsers: browsers,
                            liveSessions: liveByPid.values.sorted(), staleSessionFiles: stale.sorted())
    }

    // MARK: - Step helpers

    /// Step 1 classification, or nil if `s` is not a browser instance.
    static func browserInstance(_ s: ProcSample, pass: inout Pass, hostBrowserPids: Set<Int32>,
                                env: HeadroomEnv) -> BrowserInstance? {
        let isChromePath = s.path == KnownPaths.chromeExecutable
        let fromHost = hostBrowserPids.contains(s.pid)
        guard isChromePath || fromHost else { return nil }
        let a = pass.args(s.pid)
        if let a {
            if a.hasFlag("type") { return nil }
        } else if !fromHost {
            // argv unreadable: a browser's parent is never another Chrome-bundle process.
            if let parent = pass.t.byPid[s.ppid], parent.path.contains("/Google Chrome.app/") { return nil }
        }
        let udd = a?.flag("user-data-dir").map(normalizePath)
        let headless = a?.hasFlag("headless") ?? false
        let remote = (a?.hasFlag("remote-debugging-port") ?? false) || (a?.hasFlag("remote-debugging-pipe") ?? false)
        let defaultDir = normalizePath(env.defaultChromeUserDataDir)
        let heuristicMain = hostBrowserPids.isEmpty && isChromePath && !headless && !remote
            && (udd == nil || udd == defaultDir)
        return BrowserInstance(key: s.key, isMain: fromHost || heuristicMain, userDataDir: udd,
                               headless: headless, remoteDebugging: remote)
    }

    /// A crashpad handler starts in the same second as its browser (or one second later).
    static let crashpadStartTolerance = 1

    /// Unowned `chrome_crashpad_handler`s whose `--database` lies inside a browser's user-data-dir.
    static func crashpadHandlers(_ t: ProcessTable, pass: inout Pass, browsers: [BrowserInstance],
                                 env: HeadroomEnv) -> [(Int32, BrowserInstance)] {
        guard !browsers.isEmpty else { return [] }
        let defaultDir = normalizePath(env.defaultChromeUserDataDir)
        var out: [(Int32, BrowserInstance)] = []
        for s in t.byPid.values.sorted(by: { $0.pid < $1.pid })
        where pass.owner[s.pid] == nil && s.path.contains("/Google Chrome") && s.path.hasSuffix("chrome_crashpad_handler") {
            guard let db = pass.args(s.pid)?.flag("database").map(normalizePath) else { continue }
            let matches = browsers.filter { db.hasPrefix((($0.userDataDir ?? defaultDir)) + "/") }
            // Chrome 154 writes every instance's crash reports to the default Crashpad folder, even with a
            // --user-data-dir (seen live: agent-browser's headless Chrome). A handler started within a second of a
            // browser was spawned by it, so that browser wins over the folder match (integration, 2026-09-30).
            let sameStart = browsers
                .filter { abs($0.key.startSec - s.key.startSec) <= crashpadStartTolerance && s.key.startSec >= $0.key.startSec }
                .min { abs($0.key.startSec - s.key.startSec) < abs($1.key.startSec - s.key.startSec) }
            if let b = sameStart ?? matches.first {
                out.append((s.pid, b))
            }
        }
        return out
    }

    /// Step 2 liveness for one record whose pid exists.
    static func isLive(_ rec: SessionRecord, sample s: ProcSample, pass: inout Pass, env: HeadroomEnv) -> Bool {
        let isClaude = env.isClaudeBinary(path: s.path) || basename(pass.argv0(s.pid)) == "claude"
        guard isClaude else { return false }
        if let ps = rec.procStart, let d = parseProcStart(ps) {
            return abs(Int(d.timeIntervalSince1970.rounded()) - s.key.startSec) <= procStartTolerance
        }
        if let ms = rec.startedAt {
            return abs(Double(s.key.startSec) - ms / 1000) <= startedAtTolerance
        }
        return false
    }

    /// Parses a sessions-JSON `procStart` ("Tue Sep 29 16:28:53 2026", UTC, en_US_POSIX).
    public static func parseProcStart(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        // ctime-style strings pad the day with a space ("Wed Sep  2 …").
        let collapsed = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return f.date(from: collapsed)
    }

    /// A claude binary running AS claude. The claude executable is multi-call: Claude Code also runs it as
    /// `ugrep`/`rg` (argv0) for searches, and those helpers are not sessions. Accepts argv0 "claude", argv0 equal
    /// to the binary's own name (e.g. a test dummy at …/claude/versions/9.9.9), or unreadable argv.
    static func isClaudeProcess(_ s: ProcSample, pass: inout Pass, env: HeadroomEnv) -> Bool {
        guard env.isClaudeBinary(path: s.path) else { return false }
        guard let a = pass.args(s.pid), !a.argv0.isEmpty else { return true }
        let a0 = basename(a.argv0)
        return a0 == "claude" || a0 == basename(s.path)
    }

    static func isInsideApp(_ path: String) -> Bool { path.contains(".app/") }
    static func basename(_ s: String) -> String {
        guard let i = s.lastIndex(of: "/") else { return s }
        return String(s[s.index(after: i)...])
    }
    static func normalizePath(_ p: String) -> String {
        var s = (p as NSString).expandingTildeInPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Mutable state of one assign() run.
    struct Pass {
        let t: ProcessTable
        let sys: any SysKit
        let env: HeadroomEnv
        var owner: [Int32: Owner] = [:]
        var never: Set<Int32> = []
        private var argsMemo: [Int32: ProcArgs?] = [:]

        init(t: ProcessTable, sys: any SysKit, env: HeadroomEnv) { self.t = t; self.sys = sys; self.env = env }

        mutating func args(_ pid: Int32) -> ProcArgs? {
            if let m = argsMemo[pid] { return m }
            let a = t.byPid[pid].flatMap { sys.args($0.key) }
            argsMemo[pid] = .some(a)
            return a
        }
        /// argv0, or the executable path when argv is unreadable.
        mutating func argv0(_ pid: Int32) -> String {
            if let a = args(pid), !a.argv0.isEmpty { return a.argv0 }
            return t.byPid[pid]?.path ?? ""
        }
        mutating func argv0Base(_ pid: Int32) -> String { Ownership.basename(argv0(pid)) }

        /// Sets an owner only if the pid is unowned and assignable. Returns false otherwise.
        @discardableResult
        mutating func set(_ pid: Int32, _ o: Owner) -> Bool {
            guard owner[pid] == nil, !never.contains(pid), t.byPid[pid] != nil else { return false }
            owner[pid] = o
            return true
        }
        /// Claims `root` and its unowned subtree. Does not descend into owned pids or `stopAt` pids.
        mutating func claimTree(_ root: Int32, as o: Owner, stopAt: Set<Int32> = []) {
            guard set(root, o) else { return }
            claimDescendants(of: root, as: o, stopAt: stopAt)
        }
        mutating func claimDescendants(of root: Int32, as o: Owner, stopAt: Set<Int32>) {
            var queue = t.children[root] ?? []
            var seen: Set<Int32> = [root]
            while let p = queue.popLast() {
                guard seen.insert(p).inserted, !stopAt.contains(p) else { continue }
                guard set(p, o) else { continue }
                queue.append(contentsOf: t.children[p] ?? [])
            }
        }
    }
}

// MARK: - Units (for the LinkedUnit rows and the signaller)

extension Ownership {
    /// Connected components (by ppid) of the pids owned by `o`. Root = the member whose parent is not a member.
    /// For `.claudeChild(k)` every direct child subtree of the claude is one unit.
    public static func units(of o: Owner, in t: ProcessTable, map: OwnershipMap, sys: any SysKit) -> [LinkedUnit] {
        let members = Set(map.pids(ownedBy: o))
        guard !members.isEmpty else { return [] }
        let automation = Set(map.browsers.filter { !$0.isMain }.map(\.key.pid))
        var out: [LinkedUnit] = []
        let roots = members.filter { p in !(t.byPid[p].map { members.contains($0.ppid) } ?? false) }
        for r in roots.sorted() {
            guard let rs = t.byPid[r] else { continue }
            let tree = [r] + t.descendants(of: r).filter { members.contains($0) }
            let keys = tree.compactMap { t.byPid[$0]?.key }.sorted()
            let argv = sys.args(rs.key)?.argv ?? []
            out.append(LinkedUnit(root: rs.key, pgid: rs.pgid, command: commandLabel(argv: argv, path: rs.path),
                                  argv: argv, cwd: sys.cwd(r), members: keys, footprint: t.footprint(of: tree),
                                  isAutomationBrowser: tree.contains { automation.contains($0) }))
        }
        return out.sorted { $0.footprint > $1.footprint }
    }

    /// Every distinct owner in the map (sessions, leftovers, …), for iteration.
    public static func owners(in map: OwnershipMap) -> Set<Owner> { Set(map.owner.values) }

    /// Stable ItemID for a leftover group: `.leftover(pgid, leaderStartSec)`. The leader is the process whose
    /// pid == pgid when it still exists, otherwise the earliest-started member.
    public static func leftoverID(pgid: Int32, members: [ProcKey], table t: ProcessTable) -> ItemID {
        if let leader = t.byPid[pgid] { return .leftover(pgid: pgid, leaderStartSec: leader.key.startSec) }
        let start = members.map(\.startSec).min() ?? 0
        return .leftover(pgid: pgid, leaderStartSec: start)
    }

    /// "bun run dev --port 3217": argv with argv0 shortened to its basename, capped at `limit` characters.
    public static func commandLabel(argv: [String], path: String = "", limit: Int = 120) -> String {
        var parts = argv
        if parts.isEmpty { parts = [path] }
        if let first = parts.first { parts[0] = basename(first) }
        let s = parts.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
        return s.count > limit ? String(s.prefix(limit - 1)) + "…" : s
    }
}

// MARK: - Invariant check (selftest and tests)

extension Ownership {
    /// Checks the §3 invariants that the map's shape does not already guarantee. Returns problems (empty = ok).
    public static func verify(_ map: OwnershipMap, table t: ProcessTable, tmuxPanes: [TmuxPane],
                              env: HeadroomEnv, sys: (any SysKit)? = nil) -> [String] {
        var problems: [String] = []
        let panePids = Set(tmuxPanes.map(\.panePid))
        let rex = RexProcess.topology(in: t, argv: { sys?.args($0)?.argv }, parentPid: { sys?.parentPid($0) })
        let liveClaude = Set(map.liveSessions.map(\.pid))
        let mains = Set(map.browsers.filter(\.isMain).map(\.key.pid))
        for (pid, o) in map.owner {
            guard let s = t.byPid[pid] else { problems.append("pid \(pid) owned but not in table"); continue }
            switch o {
            case .leftover, .claudeBackground:
                if liveClaude.contains(pid) { problems.append("live claude \(pid) inside a unit \(o)") }
                if panePids.contains(pid) { problems.append("tmux pane pid \(pid) inside a unit \(o)") }
                if rex.servers.contains(pid) || rex.blockRoots.contains(pid) {
                    problems.append("Rex server or pane process \(pid) inside a unit \(o)")
                }
                if mains.contains(pid) { problems.append("main browser \(pid) inside a unit \(o)") }
                if env.isClaudeBinary(path: s.path), let sys, let a = sys.args(s.key),
                   ["claude", basename(s.path)].contains(basename(a.argv0)) {
                    problems.append("claude process \(pid) inside a unit \(o)")
                }
            case .session(let k):
                if k != s.key { problems.append("session key mismatch for \(pid)") }
            case .chrome(let b):
                if !mains.contains(b) { problems.append("pid \(pid) owned by non-main browser \(b)") }
            default: break
            }
        }
        for m in mains where map.owner[m] != nil && map.owner[m] != .chrome(browserPid: m) {
            problems.append("main browser \(m) owned by \(map.owner[m]!)")
        }
        let owned = t.footprint(of: map.owner.keys)
        let byBucket = Dictionary(grouping: map.owner, by: \.value).values
            .reduce(Bytes(0)) { $0 + t.footprint(of: $1.map(\.key)) }
        if owned != byBucket { problems.append("bucket sum \(byBucket) ≠ owned sum \(owned)") }
        return problems
    }
}
