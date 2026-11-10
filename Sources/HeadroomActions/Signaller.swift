// Signaller — the only code in Headroom that sends signals (SPEC §7.4). Hard allowlist, no exceptions.
//
// A signal is sent only to:
//   (a) .session            a live claude pid whose start time and /claude/versions/ path still match;
//   (b) .group              a recorded background unit or leftover group (kill(-pgid)) that passes the §3
//                           exclusions again, contains no live claude, no tmux server, no pane_pid and is not
//                           a pane's process group, and whose recorded members still have their startSec;
//   (c) .automationBrowser  a Chrome instance that is headless / remote-debugging / non-default
//                           --user-data-dir, is not a host's browserPid nor the main browser, and is owned
//                           by (a) or (b). SIGTERM only, browser pid only.
// Never: pid ≤ 1, Headroom itself or its ancestors (or their process groups), the main Chrome, any other
// .app process. Only SIGTERM and SIGKILL (SIGKILL only from an explicit Force Quit).
//
// Every call is checked first, then journalled. With HEADROOM_DRY_RUN=1 a call that passes the checks
// returns .dryRun instead of sending, so tests exercise the real allowlist without signalling anything.

import Darwin
import Foundation
import HeadroomContracts

public enum SignalTarget: Sendable, Hashable, Codable, CustomStringConvertible {
    case session(ProcKey)
    /// kill(-pgid). `members` are the ProcKeys recorded at plan time; `automationRoots` are recorded
    /// automation browsers inside the group whose .app processes may be signalled with it.
    case group(pgid: Int32, members: [ProcKey], automationRoots: [ProcKey])
    case automationBrowser(ProcKey)

    public var description: String {
        switch self {
        case .session(let k): "session \(k)"
        case let .group(g, m, _): "pgid \(g) (\(m.count) recorded)"
        case .automationBrowser(let k): "automation browser \(k)"
        }
    }
    public var pid: Int32 {
        switch self {
        case .session(let k), .automationBrowser(let k): k.pid
        case .group(let g, _, _): -g
        }
    }
}

/// Live facts the allowlist is checked against. The coordinator fills it right before signalling.
public struct SignalContext: Sendable {
    public var selfPid: Int32
    /// tmux pane_pid of every pane (live, from `tmux list-panes`).
    public var panePids: Set<Int32>
    /// browserPid from each connected host hello.
    public var hostBrowserPids: Set<Int32>
    /// Main (the user's own) browser pids from Ownership.
    public var mainBrowserPids: Set<Int32>
    /// Automation browsers owned by a live session or a leftover group (recorded in the plan's world).
    public var ownedAutomationBrowsers: Set<ProcKey>
    /// Sessions that must never be signalled (the launcher).
    public var protectedPids: Set<Int32>
    public init(selfPid: Int32 = getpid(), panePids: Set<Int32> = [], hostBrowserPids: Set<Int32> = [],
                mainBrowserPids: Set<Int32> = [], ownedAutomationBrowsers: Set<ProcKey> = [],
                protectedPids: Set<Int32> = []) {
        self.selfPid = selfPid; self.panePids = panePids; self.hostBrowserPids = hostBrowserPids
        self.mainBrowserPids = mainBrowserPids; self.ownedAutomationBrowsers = ownedAutomationBrowsers
        self.protectedPids = protectedPids
    }
}

/// The syscall seam. Returns 0 on success, otherwise errno.
public protocol SignalSender: Sendable {
    func send(_ pid: pid_t, _ sig: Int32) -> Int32
}

public struct DarwinSignalSender: SignalSender {
    public init() {}
    public func send(_ pid: pid_t, _ sig: Int32) -> Int32 { kill(pid, sig) == 0 ? 0 : errno }
}

public struct Signaller: Sendable {
    public let env: HeadroomEnv
    public let sender: any SignalSender
    public let journal: Journal?
    /// argv lookup for §3 exclusions (SysKit.args, cached per key).
    public let args: @Sendable (ProcKey) -> ProcArgs?

    public init(env: HeadroomEnv, sender: any SignalSender = DarwinSignalSender(), journal: Journal? = nil,
                args: @escaping @Sendable (ProcKey) -> ProcArgs?) {
        self.env = env; self.sender = sender; self.journal = journal; self.args = args
    }

    static let excludedArgv0 = ["tmux", "limactl", "colima", "docker", "ssh-agent"]

    /// Checks `target` against the allowlist and the live table. nil = allowed; otherwise the result to report
    /// (.refused, .mismatch or .gone).
    public func check(_ target: SignalTarget, signal: Int32, table: ProcessTable, context c: SignalContext) -> SignalResult? {
        guard signal == SIGTERM || signal == SIGKILL else { return .refused("signal \(signal) is not allowed") }
        // Headroom's ancestors, launchd excluded (it is an ancestor of every orphaned dev server).
        let ancestors = Set(table.ancestors(of: c.selfPid).filter { $0 > 1 })
        let forbiddenPgids = Set(([c.selfPid] + Array(ancestors)).compactMap { table.byPid[$0]?.pgid })
            .union([getpgrp()])

        func basicRefusal(_ pid: Int32) -> String? {
            if pid <= 1 { return "pid \(pid) ≤ 1" }
            if pid == c.selfPid { return "Headroom itself" }
            if ancestors.contains(pid) { return "an ancestor of Headroom" }
            if c.mainBrowserPids.contains(pid) || c.hostBrowserPids.contains(pid) { return "the main Chrome" }
            if c.protectedPids.contains(pid) { return "the session that launched Headroom" }
            return nil
        }

        switch target {
        case .session(let k):
            if let r = basicRefusal(k.pid) { return .refused(r) }
            guard let s = table.byPid[k.pid] else { return .gone }
            guard s.key.startSec == k.startSec else { return .mismatch }
            let a = args(s.key)
            guard env.isClaudeBinary(path: s.path) || a?.argv0 == "claude" else {
                return .refused("pid \(k.pid) is not a claude binary")
            }
            if isInsideApp(s.path) { return .refused(".app process") }
            // A claude that is itself a pane's process (`tmux new-window claude`) is still a session (a):
            // SIGTERM ends it and tmux closes the pane. Only process *groups* containing a pane are refused.
            return nil

        case .automationBrowser(let k):
            if signal != SIGTERM { return .refused("automation browsers only get SIGTERM") }
            if let r = basicRefusal(k.pid) { return .refused(r) }
            guard let s = table.byPid[k.pid] else { return .gone }
            guard s.key.startSec == k.startSec else { return .mismatch }
            guard c.ownedAutomationBrowsers.contains(k) else { return .refused("not owned by a session or leftover") }
            guard Self.isChromeBinary(s.path) else { return .refused("not a Chrome process") }
            guard let a = args(s.key) else { return .refused("cannot read the browser's argv") }
            if a.hasFlag("type") { return .refused("a Chrome helper, not a browser") }
            guard Self.isAutomation(a, home: env.home) else { return .refused("looks like the main Chrome") }
            return nil

        case let .group(pgid, recorded, autoRoots):
            if pgid <= 1 { return .refused("pgid \(pgid) ≤ 1") }
            if forbiddenPgids.contains(pgid) { return .refused("Headroom's own process group") }
            // Recorded members must still be who they were.
            var anyRecordedAlive = false
            for m in recorded {
                guard let s = table.byPid[m.pid] else { continue }
                if s.key.startSec != m.startSec { return .mismatch }
                if s.pgid == pgid { anyRecordedAlive = true }
            }
            let members = table.byPid.values.filter { $0.pgid == pgid }
            if members.isEmpty { return .gone }
            // pgid reused by something we never recorded.
            if !anyRecordedAlive { return .mismatch }
            let panePgids = Set(c.panePids.compactMap { table.byPid[$0]?.pgid })
            if panePgids.contains(pgid) { return .refused("a tmux pane's process group") }
            let memberPids = Set(members.map(\.pid))
            // Allowed .app members: recorded automation browsers and their descendants.
            var autoPids: Set<Int32> = []
            for r in autoRoots where table.byPid[r.pid]?.key.startSec == r.startSec && c.ownedAutomationBrowsers.contains(r) {
                autoPids.insert(r.pid); autoPids.formUnion(table.descendants(of: r.pid))
            }
            let livePaneOrClaude: (ProcSample) -> String? = { p in
                if c.panePids.contains(p.pid) { return "a tmux pane process (\(p.pid))" }
                if self.env.isClaudeBinary(path: p.path) || self.args(p.key)?.argv0 == "claude" {
                    return "a live claude (\(p.pid))"
                }
                if Self.isTmux(p, self.args(p.key)) { return "the tmux server (\(p.pid))" }
                return nil
            }
            for m in members {
                if let r = basicRefusal(m.pid) { return .refused("group contains \(r)") }
                if let r = livePaneOrClaude(m) { return .refused("group contains \(r)") }
                if isInsideApp(m.path) && !autoPids.contains(m.pid) { return .refused("group contains an .app process (\(m.pid))") }
                if let a = args(m.key) {
                    let a0 = (a.argv0 as NSString).lastPathComponent
                    if a0.hasPrefix("-") || Self.excludedArgv0.contains(a0) {
                        return .refused("group contains \(a0) (\(m.pid))")
                    }
                }
                // ppid chain outside the group must not pass through tmux, a pane or a live claude.
                for anc in table.ancestors(of: m.pid) where !memberPids.contains(anc) {
                    guard let p = table.byPid[anc] else { continue }
                    if anc == c.selfPid { return .refused("group descends from Headroom") }
                    if let r = livePaneOrClaude(p) { return .refused("group runs under \(r)") }
                }
            }
            return nil
        }
    }

    /// Check, journal, then send (or .dryRun).
    @discardableResult
    public func send(_ target: SignalTarget, signal: Int32 = SIGTERM, table: ProcessTable, context: SignalContext,
                     itemId: ItemID? = nil, reason: String) -> SignalResult {
        let result: SignalResult
        if let refusal = check(target, signal: signal, table: table, context: context) {
            result = refusal
        } else if env.dryRun {
            result = .dryRun
        } else {
            let err = sender.send(target.pid, signal)
            result = err == 0 ? .sent : err == ESRCH ? .gone : .failed(err)
        }
        journal?.log(.signal(target: target, signal: signal, itemId: itemId, reason: reason, result: result,
                             dryRun: env.dryRun, table: table))
        return result
    }

    // MARK: classification helpers

    func isInsideApp(_ path: String) -> Bool { path.contains(".app/") }

    static func isChromeBinary(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.contains(".app/Contents/MacOS/")
            && (name == "Google Chrome" || name == "Google Chrome for Testing" || name == "Chromium"
                || name.hasPrefix("Google Chrome"))
    }

    static func isAutomation(_ a: ProcArgs, home: String) -> Bool {
        if a.hasFlag("headless") || a.hasFlag("remote-debugging-port") || a.hasFlag("remote-debugging-pipe") { return true }
        if let dir = a.flag("user-data-dir"), !dir.isEmpty,
           (dir as NSString).standardizingPath != KnownPaths.defaultChromeUserDataDir(home: home) { return true }
        return false
    }

    static func isTmux(_ p: ProcSample, _ a: ProcArgs?) -> Bool {
        let name = (p.path as NSString).lastPathComponent
        if name == "tmux" { return true }
        if let a0 = a?.argv0 { return (a0 as NSString).lastPathComponent.hasPrefix("tmux") }
        return false
    }
}
