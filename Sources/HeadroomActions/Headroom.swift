// Composition root shared by the App and the CLI. Both obtain a WorldProvider and an
// ActionExecutor the same way:
//
//   let ctx = Headroom.context()          // HEADROOM_MOCK=1 → mock, otherwise live
//   let world = await ctx.world.snapshot()
//   let plan = ctx.executor.plan(selection, world)
//
// The rest of this module: Planner, CloseCoordinator, Signaller, Journal, Undo.

import Foundation
import HeadroomContracts
import HeadroomCore
import HeadroomClaude
import HeadroomChrome

public enum Headroom {
    /// Live or mock, chosen by HEADROOM_MOCK.
    public static func context(env: HeadroomEnv = .current) -> HeadroomContext {
        env.mock ? mock(env: env) : live(env: env)
    }

    public static func live(env: HeadroomEnv = .current) -> HeadroomContext {
        let s = LiveServices(env: env)
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
    public let claude: ClaudeSource
    public let chrome: ChromeSource
    public let world: LiveWorld
    public let executor: LiveExecutor

    public init(env: HeadroomEnv = .current) {
        self.env = env
        sys = LiveSysKit(env: env)
        tmux = TmuxClient(env: env)
        claude = ClaudeSource(env: env, tmux: tmux)
        chrome = ChromeSource(env: env)
        world = LiveWorld(env: env, sys: sys, tmux: tmux, claude: claude, chrome: chrome)
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

/// One refresh: scan → ownership → providers. tmux runs once per refresh (panes + clients, shared by
/// ownership and the Claude source), and the JXA list and tmux state follow the window's cadence (setCadence).
public struct LiveWorld: WorldProvider {
    public let env: HeadroomEnv
    public let sys: LiveSysKit
    public let tmux: TmuxClient
    public let claude: ClaudeSource
    public let chrome: ChromeSource
    public let tmuxCache = TmuxStateCache()

    /// SPEC §9 cadences for the parts that are expensive to run every tick (tmux, osascript).
    public func setCadence(windowKey: Bool) {
        tmuxCache.setTTL(windowKey ? 3 : 10)
        chrome.setCadence(windowKey: windowKey)
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
        async let claudeSnap = claude.snapshot(table, ownership, sys, tmuxState: tmuxNow)
        let me = getpid()
        var selfBytes = table.byPid[me]?.footprint ?? 0
        for h in await hosts { selfBytes += table.byPid[h.hostPid]?.footprint ?? 0 }
        let chromeResult = await chromeSnap
        return WorldSnapshot(system: sys.systemMemory(), chrome: chromeResult, claude: await claudeSnap,
                             ownership: ownership, selfBytes: selfBytes, helperBytes: chromeResult.helperBytes,
                             at: Date())
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
