// Composition root shared by the App and the CLI. Both obtain a WorldProvider and an
// ActionExecutor the same way:
//
//   let ctx = Headroom.context()          // HEADROOM_MOCK=1 → mock, otherwise live
//   let world = await ctx.world.snapshot()
//   let plan = ctx.executor.plan(selection, world)
//
// The rest of this module: Planner, CloseCoordinator, Signaller, Journal, Undo. Sessions may run in tmux or Rex;
// both are wired here (LiveServices.tmux / .rex, LiveWorld's two state caches).

import Foundation
import HeadroomContracts
import HeadroomCore
import HeadroomClaude
import HeadroomChrome
import HeadroomDocker

public enum Headroom {
    /// Live or mock, chosen by HEADROOM_MOCK. `mayAskForGhostty`: see LiveServices.init (only the app's window sets it).
    public static func context(env: HeadroomEnv = .current, mayAskForGhostty: Bool = false) -> HeadroomContext {
        env.mock ? mock(env: env) : live(env: env, mayAskForGhostty: mayAskForGhostty)
    }

    public static func live(env: HeadroomEnv = .current, mayAskForGhostty: Bool = false) -> HeadroomContext {
        let s = LiveServices(env: env, mayAskForGhostty: mayAskForGhostty)
        return HeadroomContext(world: s.world, executor: s.executor, env: env, isMock: false)
    }

    /// MockWorld + a mock executor that only pretends (every outcome is .dryRun) but removes closed rows
    /// from later snapshots, and puts them back on undo, so the UI can be exercised end to end.
    public static func mock(env: HeadroomEnv = .current) -> HeadroomContext {
        let state = MockState()
        return HeadroomContext(world: MockWorldProvider(state: state, chromeMode: env.mockChrome ?? "helper",
                                                        jitter: env.mockJitter),
                               executor: MockExecutor(state: state, env: env), env: env, isMock: true)
    }
}

/// The concrete live providers, for callers that need more than the two protocols
/// (e.g. the App's Chrome setup card talks to `chrome` directly, `--selftest` uses `sys`).
public final class LiveServices: Sendable {
    public let env: HeadroomEnv
    public let sys: LiveSysKit
    public let tmux: TmuxClient
    /// The one RexClient (also `claude.rex`): discovery, Peek capture, Jump and Undo all go through it.
    public let rex: RexClient
    public let claude: ClaudeSource
    public let chrome: ChromeSource
    /// Docker containers, VM and disk use (read-only).
    public let docker: DockerSource
    public let world: LiveWorld
    public let executor: LiveExecutor

    /// `mayAskForGhostty`: Jump may show the macOS prompt for Automation ▸ Ghostty, once, the first time it needs the
    /// permission (SPEC §8.5). Only the app's window sets it. The CLI and the app's one-shot modes never prompt.
    public init(env: HeadroomEnv = .current, mayAskForGhostty: Bool = false) {
        self.env = env
        sys = LiveSysKit(env: env)
        tmux = TmuxClient(env: env)
        rex = RexClient(env: env)
        claude = ClaudeSource(env: env, tmux: tmux, rex: rex, desktop: GhosttyDesktop(mayAsk: mayAskForGhostty))
        chrome = ChromeSource(env: env)
        docker = DockerSource(env: env)
        world = LiveWorld(env: env, sys: sys, tmux: tmux, claude: claude, chrome: chrome, docker: docker)
        executor = LiveExecutor(env: env, sys: sys, tmux: tmux, claude: claude, chrome: chrome)
    }
}

/// tmux panes + clients reused between refreshes (SPEC §9: tmux every 3 s while key, 10 s while visible).
/// TTL 0 (the default) = always fresh; only the app's display world sets a cadence. Close-time checks
/// (Signaller context, fresh session re-check) never go through a cached world.
public final class TmuxStateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var ttl: TimeInterval = 0
    private var cached: (at: Date, panes: [TmuxPane], clients: [TmuxClientInfo])?
    public init() {}
    public func setTTL(_ t: TimeInterval) { lock.withLock { ttl = t } }
    func get(_ tmux: TmuxClient) async -> (panes: [TmuxPane], clients: [TmuxClientInfo]) {
        let now = Date()
        if let c = lock.withLock({ cached }), now.timeIntervalSince(c.at) < lock.withLock({ ttl }) {
            return (c.panes, c.clients)
        }
        async let p = tmux.panes()
        async let c = tmux.clients()
        let r = await (panes: p, clients: c)
        lock.withLock { cached = (now, r.panes, r.clients) }
        return r
    }
}

/// Rex discovery (`rex ls` + one `session inspect` per session) reused between refreshes, with the same cadence and
/// TTL rule as TmuxStateCache: TTL 0 (the default) = always fresh. Every result is cached, failures included, so a Rex
/// server that does not answer costs one bounded fetch per TTL, not one per tick. Close-time checks never use it.
/// `sessionsFirst` (the sessions that hold a claude) are inspected first; a cached pass that neither put a wanted
/// session first nor inspected it is stale, so a new claude in a session the last pass skipped is placed at once.
public final class RexStateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var ttl: TimeInterval = 0
    private var cached: (at: Date, wanted: Set<String>, state: RexState)?
    public init() {}
    public func setTTL(_ t: TimeInterval) { lock.withLock { ttl = t } }
    func get(_ rex: RexClient, sessionsFirst wanted: Set<String> = []) async -> RexState {
        let now = Date()
        if let c = lock.withLock({ cached }), now.timeIntervalSince(c.at) < lock.withLock({ ttl }),
           wanted.subtracting(c.wanted).subtracting(c.state.appClients.keys).isEmpty {
            return c.state
        }
        let s = await rex.state(sessionsFirst: wanted)
        lock.withLock { cached = (now, wanted, s) }
        return s
    }
}

/// One refresh: scan → ownership → providers. tmux runs once per refresh (panes + clients, shared by
/// ownership and the Claude source), and the JXA list and tmux state follow the window's cadence (setCadence).
/// Rex runs only when some claude's ppid chain reaches a Rex server (a pure check, no rex call), on the same cadence.
public struct LiveWorld: WorldProvider {
    public let env: HeadroomEnv
    public let sys: LiveSysKit
    public let tmux: TmuxClient
    public let claude: ClaudeSource
    public let chrome: ChromeSource
    /// Never waited for in snapshot(): it answers from its last background read (the CLI calls docker.refresh()).
    /// nil for the close-time recheck world, which has no use for Docker.
    public var docker: DockerSource? = nil
    public let tmuxCache = TmuxStateCache()
    public let rexCache = RexStateCache()

    /// Notes from the last session Undo (ClaudeSource.lastReopenNotes): a new Rex session that Rex.app could not be
    /// asked to show. The app's Undo toast and `headroom undo` show them.
    public var reopenNotes: [String] { claude.lastReopenNotes }

    /// SPEC §9 cadences for the parts that are expensive to run every tick (tmux, Rex, osascript).
    public func setCadence(windowKey: Bool) {
        tmuxCache.setTTL(windowKey ? 3 : 10)
        rexCache.setTTL(windowKey ? 3 : 10)
        chrome.setCadence(windowKey: windowKey)
        docker?.setCadence(windowKey: windowKey)
    }

    public func snapshot() async -> WorldSnapshot {
        let table = sys.scan()
        async let records = claude.sessionRecords()
        async let hosts = chrome.hosts()
        async let tmuxState = tmuxCache.get(tmux)
        let tmuxNow = await tmuxState
        let ownership = Ownership.assign(table, sessions: await records, hosts: await hosts,
                                         tmuxPanes: tmuxNow.panes, sys: sys, env: env)
        async let chromeSnap = chrome.snapshot(table, ownership, sys)
        // Awaited before the `async let` below so the child task captures a value, not a pending fetch.
        let rexNow: RexState?
        if let wanted = ClaudeSource.rexSessionsNeeded(table, ownership, sys, tmuxPanes: tmuxNow.panes) {
            rexNow = await rexCache.get(claude.rex, sessionsFirst: wanted)
        } else {
            rexNow = nil
        }
        async let claudeSnap = claude.snapshot(table, ownership, sys, tmuxState: tmuxNow, rexState: rexNow)
        let me = getpid()
        var selfBytes = table.byPid[me]?.footprint ?? 0
        for h in await hosts { selfBytes += table.byPid[h.hostPid]?.footprint ?? 0 }
        let chromeResult = await chromeSnap
        return WorldSnapshot(system: sys.systemMemory(), chrome: chromeResult, claude: await claudeSnap,
                             ownership: ownership, selfBytes: selfBytes, helperBytes: chromeResult.helperBytes,
                             at: Date(), docker: docker?.snapshot(table) ?? .empty)
    }
}

/// `--selftest [sys|ownership|claude|chrome]`, shared by the CLI and the app (SPEC §11). Read-only.
public enum HeadroomSelfTest {
    public static let groups = CoreSelfTest.groups + [ClaudeSelfTest.group, ChromeSelfTest.group]

    public static func run(_ groups: [String], services s: LiveServices) async -> SelfTestReport {
        let want = groups.isEmpty ? Self.groups : groups
        let claude = s.claude, chrome = s.chrome, env = s.env
        var report = SelfTestReport()
        let core = want.filter { CoreSelfTest.groups.contains($0) }
        if !core.isEmpty {
            let r = await CoreSelfTest.run(core, env: env, sessions: { await claude.sessionRecords() },
                                           hosts: { await chrome.hosts() })
            report.checks += r.checks; report.notes += r.notes
        }
        if want.contains(ClaudeSelfTest.group) {
            let r = await ClaudeSelfTest.run(env: env, hosts: { await chrome.hosts() })
            report.checks += r.checks; report.notes += r.notes
        }
        if want.contains(ChromeSelfTest.group) {
            let r = await ChromeSelfTest.run(env: env, sessions: { await claude.sessionRecords() })
            report.checks += r.checks; report.notes += r.notes
        }
        return report
    }
}
