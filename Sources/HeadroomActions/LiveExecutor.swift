// LiveExecutor — the real ActionExecutor used by the App and the CLI.
// Planner (§7.3) + CloseCoordinator (§7.4) + Signaller (allowlist, dry run) + Journal + RecentlyClosed.

import Darwin
import Foundation
import HeadroomContracts
import HeadroomCore
import HeadroomClaude
import HeadroomChrome

/// Extra read-only data for Peek (§6.2). Both executors conform; callers use `executor as? PeekProvider`.
public protocol PeekProvider: Sendable {
    /// Read-only `tmux capture-pane -p -t <pane> -S -15`.
    func capturePane(_ paneId: String) async -> String?
    /// Read-only `rex capture -s <session> -b <block> --trim`, last 60 lines; nil when unavailable.
    func captureRexBlock(sessionId: String, blockId: String) async -> String?
    /// `lsof -nP -iTCP -sTCP:LISTEN -a -p <pids>` lines (run only when Peek opens).
    func listeningPorts(_ pids: [Int32]) async -> [String]
}

public final class LiveExecutor: ActionExecutor, PeekProvider, @unchecked Sendable {
    public let env: HeadroomEnv
    let sys: LiveSysKit
    let tmux: TmuxClient
    let claude: ClaudeSource
    let chrome: ChromeSource
    public let journal: Journal
    public let recent: RecentlyClosed
    public let coordinator: CloseCoordinator
    private let lock = NSLock()
    private var cachedLauncherPids: Set<Int32>?

    /// `source` is "app" or "cli" (written to closed.jsonl / actions.jsonl).
    public init(env: HeadroomEnv, sys: LiveSysKit, tmux: TmuxClient, claude: ClaudeSource, chrome: ChromeSource,
                source: String = LiveExecutor.defaultSource) {
        self.env = env; self.sys = sys; self.tmux = tmux; self.claude = claude; self.chrome = chrome
        journal = Journal(env: env, source: source)
        recent = RecentlyClosed(env: env)
        // Never given a cadence: tmux and Rex caches keep TTL 0, so freshSessions re-derives pane visibility (tmux
        // visible/current, Rex visible or unplaced) from fresh state right before SIGTERM.
        let world = LiveWorld(env: env, sys: sys, tmux: tmux, claude: claude, chrome: chrome)
        let backend = CloseBackend(
            sys: sys, chrome: chrome,
            panes: { await tmux.panes() },
            hostBrowserPids: { await chrome.hosts().map(\.browserPid) },
            presentTabs: { refs in
                let w = await world.snapshot()
                let present = Set(w.chrome.tabs.map(\.ref))
                return Set(refs.filter(present.contains))
            },
            reopenSessions: { await claude.reopen($0) },
            freshSessions: { keys in
                let w = await world.snapshot()
                let want = Set(keys)
                return Dictionary(w.claude.sessions.filter { want.contains($0.key) }.map { ($0.key, $0) },
                                  uniquingKeysWith: { a, _ in a })
            })
        coordinator = CloseCoordinator(env: env, backend: backend, journal: journal, recent: recent, source: source)
        recent.prune()
    }

    /// "cli" when running as the `headroom` binary, else "app".
    public static var defaultSource: String {
        (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } == "headroom") ? "cli" : "app"
    }

    /// env CLAUDE_PID plus Headroom's own ancestors (computed once; ancestors do not change).
    var launcherPids: Set<Int32> {
        lock.withLock {
            if let c = cachedLauncherPids { return c }
            var s = Set(sys.scan().ancestors(of: getpid()))
            if let l = env.launcherClaudePid { s.insert(l) }
            cachedLauncherPids = s
            return s
        }
    }

    var planner: Planner {
        let sys = self.sys
        return Planner(launcherPids: launcherPids, isAlive: { sys.isAlive($0) })
    }

    public func protections(_ w: WorldSnapshot) -> [ItemID: Protection] { planner.protections(w) }

    public func plan(_ sel: Set<ItemID>, _ w: WorldSnapshot) -> ClosePlan { planner.plan(sel, w) }

    public func execute(_ p: ClosePlan) -> AsyncStream<ActionEvent> {
        coordinator.protectedPids = launcherPids
        return coordinator.execute(p)
    }

    public func forceQuit(_ ids: [ItemID]) async { await coordinator.forceQuit(ids) }

    public func sleep(_ tabs: [ItemID]) async -> [ItemID: Outcome] {
        let out: [ItemID: Outcome]
        if env.dryRun {
            out = Dictionary(uniqueKeysWithValues: tabs.map { ($0, Outcome.dryRun) })
        } else {
            out = await chrome.discard(tabs)
        }
        journal.log(out.map { ActionLogEntry(kind: "discard", reason: "Sleep tab", result: $0.value.name,
                                             itemId: $0.key.stringValue, dryRun: env.dryRun) })
        return out
    }

    public func undo(_ r: [ClosedRecord]) async -> [ClosedRecord: Outcome] { await coordinator.undo(r) }

    public func jump(_ id: ItemID) async {
        switch id {
        case .chromeTab: await chrome.activate(id)
        case .session(let k): await claude.jump(k)
        default: break
        }
    }

    /// Jump, plus the note a Rex jump returns when it could not finish the switch (no pane found, or the app refused
    /// `session.select`, e.g. Remote Control is off). tmux and tabs never have a note.
    public func jumpNote(_ id: ItemID) async -> String? {
        if case .session(let k) = id { return await claude.jumpNote(k) }
        await jump(id)
        return nil
    }

    public func recentlyClosed() async -> [ClosedRecord] { recent.list() }

    // MARK: PeekProvider

    public func capturePane(_ paneId: String) async -> String? { await tmux.capture(pane: paneId, lines: 15) }

    public func captureRexBlock(sessionId: String, blockId: String) async -> String? {
        await claude.rex.capture(session: sessionId, block: blockId, lines: 60)
    }

    public func listeningPorts(_ pids: [Int32]) async -> [String] {
        guard !pids.isEmpty else { return [] }
        let r = await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p",
                                                   pids.map(String.init).joined(separator: ",")], timeout: 3)
        return r.stdout.split(separator: "\n").dropFirst().map(String.init)
    }
}
