// CloseCoordinator — SPEC §7.4 execution, shared by the App and the CLI. UI-independent.
//
//   1. Plan (Planner) → the caller shows the sheet if needed → execute(plan).
//   2. Tabs: one close per browser with the expected URLs; after 1 s re-check; still present → .stayedOpen.
//   3. Sessions: revalidate (pid, start, claude path) → record background units → journal intent →
//      SIGTERM all in parallel → poll every 100 ms for 5 s → survivors .stillAlive + needsForce.
//      Exited sessions with the box ticked: SIGTERM each surviving recorded background unit
//      (kill(-pgid), or the pid for automation browsers); survivors after 2 s → needsForce.
//      Right before the SIGTERM, each session's protection is re-evaluated on fresh state (freshSessions): a
//      session that became busy, visible or recently active since the plan is skipped (.changedSkipped).
//   4. Leftovers: a fresh scan, then the Signaller revalidates members' startSec right before kill(-pgid);
//      survivors after 2 s → needsForce.
//   Units with an automation browser: kill(-pgid) of the unit (the recorded browsers are allowed .app members),
//   plus SIGTERM to each recorded browser that runs in its own process group. A background unit that could not
//   be stopped is reported as a .failed progress event for its .process id.
//   5. closed.jsonl record per closed item; actions.jsonl line per signal/close (Signaller + here).
// SIGKILL is never sent automatically: only forceQuit(_:) sends it, for ids this coordinator recorded.
// In dry run no tab is closed and no signal is sent (Signaller returns .dryRun after its checks).

import Darwin
import Foundation
import HeadroomContracts

public struct CloseTiming: Sendable {
    public var poll: TimeInterval = 0.1
    public var sessionGrace: TimeInterval = 5
    public var backgroundGrace: TimeInterval = 2
    public var leftoverGrace: TimeInterval = 2
    public var tabVerifyDelay: TimeInterval = 1
    public init() {}
    public static let fast: CloseTiming = { var t = CloseTiming(); t.sessionGrace = 3; t.backgroundGrace = 2; t.tabVerifyDelay = 0; return t }()
}

/// What the coordinator needs from the outside world. LiveExecutor wires the real providers; tests fake it.
public struct CloseBackend: Sendable {
    public var sys: any SysKit
    public var chrome: (any ChromeProvider)?
    public var panes: @Sendable () async -> [TmuxPane]
    public var hostBrowserPids: @Sendable () async -> [Int32]
    /// Re-snapshot for the "asked to stay open" check: which of these tabs still exist.
    public var presentTabs: @Sendable ([TabRef]) async -> Set<TabRef>
    public var reopenSessions: (@Sendable ([ClosedRecord]) async -> [ClosedRecord: Outcome])?
    /// Fresh Claude state for these sessions, taken right before SIGTERM (busy / pane / activity re-check).
    /// nil = trust the plan (tests).
    public var freshSessions: (@Sendable ([ProcKey]) async -> [ProcKey: ClaudeSession])?
    public init(sys: any SysKit, chrome: (any ChromeProvider)? = nil,
                panes: @escaping @Sendable () async -> [TmuxPane] = { [] },
                hostBrowserPids: @escaping @Sendable () async -> [Int32] = { [] },
                presentTabs: @escaping @Sendable ([TabRef]) async -> Set<TabRef> = { _ in [] },
                reopenSessions: (@Sendable ([ClosedRecord]) async -> [ClosedRecord: Outcome])? = nil,
                freshSessions: (@Sendable ([ProcKey]) async -> [ProcKey: ClaudeSession])? = nil) {
        self.sys = sys; self.chrome = chrome; self.panes = panes; self.hostBrowserPids = hostBrowserPids
        self.presentTabs = presentTabs; self.reopenSessions = reopenSessions; self.freshSessions = freshSessions
    }
}

public final class CloseCoordinator: @unchecked Sendable {
    public let env: HeadroomEnv
    public let backend: CloseBackend
    public let journal: Journal
    public let recent: RecentlyClosed
    public let signaller: Signaller
    public let source: String
    public var timing: CloseTiming
    /// Launcher pids (never signalled).
    public var protectedPids: Set<Int32>

    private let lock = NSLock()
    /// Targets that survived SIGTERM, for an explicit Force Quit.
    private var survivors: [ItemID: SignalTarget] = [:]

    public init(env: HeadroomEnv, backend: CloseBackend, journal: Journal? = nil, recent: RecentlyClosed? = nil,
                sender: any SignalSender = DarwinSignalSender(), source: String = "app",
                timing: CloseTiming = CloseTiming(), protectedPids: Set<Int32> = []) {
        self.env = env; self.backend = backend
        let j = journal ?? Journal(env: env, source: source)
        self.journal = j
        self.recent = recent ?? RecentlyClosed(env: env)
        let sys = backend.sys
        self.signaller = Signaller(env: env, sender: sender, journal: j, args: { sys.args($0) })
        self.source = source; self.timing = timing; self.protectedPids = protectedPids
    }

    public func execute(_ plan: ClosePlan) -> AsyncStream<ActionEvent> {
        AsyncStream { continuation in
            let task = Task {
                let records = await self.run(plan) { continuation.yield($0) }
                continuation.yield(.finished(records))
                continuation.finish()
            }
            continuation.onTermination = { _ in _ = task }
        }
    }

    /// Runs the plan; `emit` receives progress and needsForce events. Returns the closed records.
    public func run(_ plan: ClosePlan, emit: @Sendable (ActionEvent) -> Void) async -> [ClosedRecord] {
        let batch = UUID().uuidString
        let w = plan.world
        let items = PlanMath.effectiveItems(plan)
        var outcomes: [ItemID: Outcome] = [:]

        // 2. Tabs
        let tabItems = items.filter { $0.id.kind == .tab }
        if !tabItems.isEmpty {
            let reqs = tabItems.compactMap { i -> TabCloseRequest? in
                guard case let .chromeTab(b, t) = i.id, let tab = w.chrome.tab(TabRef(browserPid: b, tabId: t)) else { return nil }
                return TabCloseRequest(browserPid: b, id: t, expectedURL: tab.url)
            }
            var res: [ItemID: Outcome] = [:]
            if env.dryRun {
                for r in reqs { res[r.itemID] = .dryRun }
            } else if let chrome = backend.chrome {
                res = await chrome.close(reqs)
                let closed = reqs.filter { res[$0.itemID] == .done }.map { TabRef(browserPid: $0.browserPid, tabId: $0.id) }
                if !closed.isEmpty {
                    if timing.tabVerifyDelay > 0 { try? await Task.sleep(for: .seconds(timing.tabVerifyDelay)) }
                    let still = await backend.presentTabs(closed)
                    for r in still { res[r.itemID] = .stayedOpen }
                }
            } else {
                for r in reqs { res[r.itemID] = .failed("Chrome is not connected") }
            }
            for r in reqs {
                let o = res[r.itemID] ?? .failed("no result")
                outcomes[r.itemID] = o
                journal.log(ActionLogEntry(kind: "closeTab", pid: r.browserPid, reason: "user close",
                                           result: o.name, itemId: r.itemID.stringValue, target: r.expectedURL,
                                           dryRun: env.dryRun))
                emit(.progress(r.itemID, o))
            }
        }

        // 3 + 4. Processes
        let procItems = items.filter { $0.id.kind == .session || $0.id.kind == .leftover }
        if !procItems.isEmpty {
            let table = backend.sys.scan()
            let ctx = await context(w, table)
            var sessionTargets: [(PlanItem, ClaudeSession)] = []
            var needsForce: [ItemID] = []

            for i in procItems {
                if case .session(let k) = i.id {
                    guard let s = w.claude.sessions.first(where: { $0.key == k }) else {
                        outcomes[i.id] = .changedSkipped; emit(.progress(i.id, .changedSkipped)); continue
                    }
                    sessionTargets.append((i, s))
                }
            }
            // Re-check busy / visible pane / recent activity on fresh state: the sheet or the CLI's y/N prompt
            // may have been open for a while, and "Skip Busy" only knew about sessions busy at plan time.
            if let fresh = backend.freshSessions, !sessionTargets.isEmpty {
                let now = await fresh(sessionTargets.map { $0.1.key })
                sessionTargets = sessionTargets.filter { (i, s) in
                    guard let f = now[s.key] else { return true }          // gone: the Signaller reports it
                    let added = Self.newlyProtected(plan: i, fresh: f)
                    guard !added.isEmpty else { return true }
                    outcomes[i.id] = .changedSkipped
                    journal.log(ActionLogEntry(kind: "skip", pid: s.key.pid, startSec: s.key.startSec,
                                               reason: "session changed since the plan: " + added.joined(separator: ", "),
                                               result: Outcome.changedSkipped.name, itemId: i.id.stringValue,
                                               dryRun: env.dryRun))
                    emit(.progress(i.id, .changedSkipped))
                    return false
                }
            }
            for (i, s) in sessionTargets {
                let k = s.key
                journal.log(ActionLogEntry(kind: "intent", pid: k.pid, startSec: k.startSec,
                                           pgid: table.byPid[k.pid]?.pgid,
                                           reason: "close session \(s.sessionId); background: "
                                               + s.background.map { "\($0.pgid):\($0.command)" }.joined(separator: ", "),
                                           result: "planned", itemId: i.id.stringValue, dryRun: env.dryRun))
            }
            // SIGTERM all sessions at once.
            var sent: [(PlanItem, ClaudeSession)] = []
            for (i, s) in sessionTargets {
                let r = signaller.send(.session(s.key), table: table, context: ctx, itemId: i.id, reason: "close session")
                let o = outcome(r)
                if r == .sent { sent.append((i, s)) } else { outcomes[i.id] = o; emit(.progress(i.id, o)) }
                if r == .dryRun && plan.stopBackground {
                    for u in s.background {
                        let (br, _) = signalUnit(u, w: w, table: table, ctx: ctx, reason: "background of closed session")
                        reportBackground(u, br, &outcomes, emit)
                    }
                }
            }
            // Poll for exit.
            if !sent.isEmpty {
                let alive = await waitForExit(sent.map { $0.1.key }, grace: timing.sessionGrace)
                var exited: [ClaudeSession] = []
                for (i, s) in sent {
                    if alive.contains(s.key) {
                        outcomes[i.id] = .stillAlive; needsForce.append(i.id)
                        setSurvivor(i.id, .session(s.key))
                    } else {
                        outcomes[i.id] = .done; exited.append(s)
                    }
                    emit(.progress(i.id, outcomes[i.id]!))
                }
                // Background units of exited sessions.
                if plan.stopBackground {
                    let table2 = backend.sys.scan()
                    var bgSent: [(LinkedUnit, SignalTarget)] = []
                    for s in exited {
                        for u in s.background {
                            let (r, t) = signalUnit(u, w: w, table: table2, ctx: ctx, reason: "background of closed session")
                            if r == .sent { bgSent.append((u, t)) } else { reportBackground(u, r, &outcomes, emit) }
                        }
                    }
                    if !bgSent.isEmpty {
                        let alive = await waitForExit(bgSent.flatMap { $0.0.members }, grace: timing.backgroundGrace)
                        for (u, t) in bgSent where u.members.contains(where: alive.contains) {
                            needsForce.append(u.itemID); setSurvivor(u.itemID, t)
                        }
                    }
                }
            }
            // Leftovers: revalidate against a fresh table (the session grace above can take seconds).
            let leftoverItems = procItems.filter { $0.id.kind == .leftover }
            var leftTable = table
            var leftCtx = ctx
            if !leftoverItems.isEmpty && !sessionTargets.isEmpty {
                leftTable = backend.sys.scan()
                leftCtx = await context(w, leftTable)
            }
            var leftSent: [(PlanItem, LeftoverGroup, SignalTarget)] = []
            for i in leftoverItems {
                guard let l = w.claude.leftovers.first(where: { $0.id == i.id }) else {
                    outcomes[i.id] = .changedSkipped; emit(.progress(i.id, .changedSkipped)); continue
                }
                let (r, t) = signalUnit(l.unit, w: w, table: leftTable, ctx: leftCtx, itemId: i.id, reason: "stop leftover")
                if r == .sent { leftSent.append((i, l, t)) } else { outcomes[i.id] = outcome(r); emit(.progress(i.id, outcomes[i.id]!)) }
            }
            if !leftSent.isEmpty {
                let alive = await waitForExit(leftSent.flatMap { $0.1.unit.members }, grace: timing.leftoverGrace)
                for (i, l, t) in leftSent {
                    if l.unit.members.contains(where: alive.contains) {
                        outcomes[i.id] = .stillAlive; needsForce.append(i.id); setSurvivor(i.id, t)
                    } else {
                        outcomes[i.id] = .done
                    }
                    emit(.progress(i.id, outcomes[i.id]!))
                }
            }
            if !needsForce.isEmpty { emit(.needsForce(needsForce)) }
        }

        // 5. Records (closed or, in dry run, would-be closed; stillAlive sessions are recorded too because
        // they have been asked to quit and usually do; the user can Force Quit or Undo).
        var records: [ClosedRecord] = []
        for i in items {
            guard let o = outcomes[i.id], o.isClosed || o == .stillAlive else { continue }
            records.append(Self.record(i, w, batch: batch, source: source))
        }
        recent.add(records)
        return records
    }

    // MARK: Force Quit

    /// SIGKILL for ids that survived SIGTERM in an earlier execute (automation browsers get SIGTERM again).
    @discardableResult
    public func forceQuit(_ ids: [ItemID]) async -> [ItemID: SignalResult] {
        let targets: [(ItemID, SignalTarget)] = lock.withLock { ids.compactMap { id in survivors[id].map { (id, $0) } } }
        guard !targets.isEmpty else { return [:] }
        let table = backend.sys.scan()
        // Ownership of automation browsers was established when they were recorded.
        var ctx = await context(nil, table)
        for (_, t) in targets { if case .automationBrowser(let k) = t { ctx.ownedAutomationBrowsers.insert(k) } }
        var out: [ItemID: SignalResult] = [:]
        for (id, t) in targets {
            var sig = SIGKILL
            if case .automationBrowser = t { sig = SIGTERM }
            if case let .group(_, _, roots) = t { ctx.ownedAutomationBrowsers.formUnion(roots) }
            out[id] = signaller.send(t, signal: sig, table: table, context: ctx, itemId: id, reason: "Force Quit (user)")
            if out[id] == .sent || out[id] == .gone || out[id] == .dryRun { lock.withLock { _ = survivors.removeValue(forKey: id) } }
        }
        return out
    }

    public func pendingForce() -> [ItemID] { lock.withLock { Array(survivors.keys) } }

    // MARK: Undo

    public func undo(_ records: [ClosedRecord]) async -> [ClosedRecord: Outcome] {
        var out: [ClosedRecord: Outcome] = [:]
        // A record restored already (by Recently Closed, `headroom undo`, or an earlier ⌘Z) is not restored
        // again: a second chrome.sessions.restore falls back to tabs.create and opens a duplicate tab.
        let restored = recent.restoredIds()
        let pending = records.filter { !restored.contains($0.id) }
        for r in records where restored.contains(r.id) { out[r] = .failed("already restored") }
        let tabs = pending.filter { $0.kind == ItemKind.tab.rawValue && $0.restorable }
        let sessions = pending.filter { $0.kind == ItemKind.session.rawValue && $0.restorable }
        for r in pending where !r.restorable { out[r] = .failed(r.kind == "leftover" ? "leftovers cannot be undone" : "not restorable") }
        if env.dryRun {
            for r in tabs { out[r] = .dryRun }
            // Sessions still go through reopen: it runs the real refusals (still running, cwd missing) and
            // returns .dryRun only after them, without touching tmux.
            if !sessions.isEmpty {
                if let reopen = backend.reopenSessions { out.merge(await reopen(sessions)) { $1 } }
                else { for r in sessions { out[r] = .dryRun } }
            }
        } else {
            if !tabs.isEmpty {
                if let chrome = backend.chrome { out.merge(await chrome.restore(tabs)) { $1 } }
                else { for r in tabs { out[r] = .failed("Chrome is not connected") } }
            }
            if !sessions.isEmpty {
                if let reopen = backend.reopenSessions { out.merge(await reopen(sessions)) { $1 } }
                else { for r in sessions { out[r] = .failed("tmux is not available") } }
            }
        }
        let ok = out.filter { $0.value == .done || $0.value == .dryRun }.map(\.key.id)
        recent.markRestored(ok)
        journal.log(out.map { r, o in
            ActionLogEntry(kind: "restore", reason: "undo \(r.kind)", result: o.name, itemId: r.itemId,
                           target: r.url ?? r.sessionId, dryRun: env.dryRun)
        })
        return out
    }

    // MARK: helpers

    private func setSurvivor(_ id: ItemID, _ t: SignalTarget) { lock.withLock { survivors[id] = t } }

    private func context(_ w: WorldSnapshot?, _ table: ProcessTable) async -> SignalContext {
        async let panes = backend.panes()
        async let hosts = backend.hostBrowserPids()
        var owned: Set<ProcKey> = []
        if let w {
            for s in w.claude.sessions {
                for u in s.background where u.isAutomationBrowser { owned.formUnion(Self.automationMembers(u, w)) }
            }
            for l in w.claude.leftovers where l.unit.isAutomationBrowser { owned.formUnion(Self.automationMembers(l.unit, w)) }
        }
        var main = Set(w?.ownership.mainBrowsers.map(\.key.pid) ?? [])
        // Anything running the default-profile Chrome without automation flags counts as main too.
        for p in table.byPid.values where Signaller.isChromeBinary(p.path) {
            if let a = backend.sys.args(p.key), !a.hasFlag("type"), !Signaller.isAutomation(a, home: env.home) {
                main.insert(p.pid)
            }
        }
        var protected = protectedPids
        if let l = env.launcherClaudePid { protected.insert(l) }
        return SignalContext(panePids: Set(await panes.map(\.panePid)), hostBrowserPids: Set(await hosts),
                             mainBrowserPids: main, ownedAutomationBrowsers: owned, protectedPids: protected)
    }

    /// Automation browsers (non-main BrowserInstances) recorded in the plan's world.
    static func automationKeys(_ w: WorldSnapshot?) -> Set<ProcKey> {
        Set(w?.ownership.browsers.filter { !$0.isMain }.map(\.key) ?? [])
    }

    /// The recorded automation browsers inside a unit. A unit's root is never an .app (Ownership excludes them
    /// as roots), so the browser is a member, not the root; the root is only used when the world does not list
    /// the browser (mock worlds).
    static func automationMembers(_ u: LinkedUnit, _ w: WorldSnapshot?) -> [ProcKey] {
        guard u.isAutomationBrowser else { return [] }
        let keys = automationKeys(w)
        let found = u.members.filter(keys.contains)
        return found.isEmpty ? [u.root] : found
    }

    /// kill(-pgid) for the unit (recorded automation browsers are allowed .app members), then SIGTERM to each
    /// recorded automation browser that runs in a process group of its own. The group's result is returned
    /// (or .sent when the group was already gone but a browser was signalled).
    private func signalUnit(_ u: LinkedUnit, w: WorldSnapshot?, table: ProcessTable, ctx: SignalContext,
                            itemId: ItemID? = nil, reason: String) -> (SignalResult, SignalTarget) {
        let autos = Self.automationMembers(u, w)
        let t: SignalTarget = .group(pgid: u.pgid, members: u.members, automationRoots: autos)
        let id = itemId ?? u.itemID
        var r = signaller.send(t, table: table, context: ctx, itemId: id, reason: reason)
        for a in autos {
            guard let p = table.byPid[a.pid], p.key.startSec == a.startSec, p.pgid != u.pgid else { continue }
            let br = signaller.send(.automationBrowser(a), table: table, context: ctx, itemId: id,
                                    reason: reason + " (automation browser)")
            if r == .gone && (br == .sent || br == .dryRun) { r = br }
        }
        return (r, t)
    }

    /// A background unit that was not stopped is reported (toast / CLI), not silently dropped.
    private func reportBackground(_ u: LinkedUnit, _ r: SignalResult, _ outcomes: inout [ItemID: Outcome],
                                  _ emit: @Sendable (ActionEvent) -> Void) {
        let why: String
        switch r {
        case .sent, .dryRun, .gone: return
        case .mismatch: why = "it changed since the plan"
        case .refused(let s): why = "refused: \(s)"
        case .failed(let e): why = "errno \(e)"
        }
        let o = Outcome.failed("background process \(u.command) was not stopped (\(why))")
        outcomes[u.itemID] = o
        emit(.progress(u.itemID, o))
    }

    /// Protection reasons a session gained since the plan that make closing it unsafe now.
    static func newlyProtected(plan i: PlanItem, fresh: ClaudeSession, now: Date = Date()) -> [String] {
        let watched: Set<String> = ["busy", "visiblePane", "recentActivity"]
        let before = Set(i.protection.reasons.map(\.code))
        let after = Planner().sessionProtection(fresh, now: now).reasons.map(\.code)
        return after.filter { watched.contains($0) && !before.contains($0) }
    }

    private func outcome(_ r: SignalResult) -> Outcome {
        switch r {
        case .sent: .done
        case .dryRun: .dryRun
        case .gone: .alreadyGone
        case .mismatch: .changedSkipped
        case .refused(let s): .failed("refused: \(s)")
        case .failed(let e): .failed("errno \(e)")
        }
    }

    /// Polls isAlive every `timing.poll` until none is alive or `grace` passes. Returns the survivors.
    private func waitForExit(_ keys: [ProcKey], grace: TimeInterval) async -> Set<ProcKey> {
        let deadline = Date().addingTimeInterval(grace)
        var alive = Set(keys.filter(backend.sys.isAlive))
        while !alive.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .seconds(timing.poll))
            alive = alive.filter(backend.sys.isAlive)
        }
        return alive
    }

    static func record(_ item: PlanItem, _ w: WorldSnapshot, batch: String, source: String) -> ClosedRecord {
        var r = ClosedRecord(batchId: batch, kind: item.id.kind.rawValue, itemId: item.id.stringValue,
                             closedAt: Date(), title: item.title, bytes: item.bytes, source: source)
        switch item.id {
        case let .chromeTab(b, t):
            if let tab = w.chrome.tab(TabRef(browserPid: b, tabId: t)) {
                r.url = tab.incognito ? nil : tab.url; r.browserPid = b; r.windowId = tab.windowId
                r.index = tab.index; r.incognito = tab.incognito
            }
        case .session(let k):
            if let s = w.claude.sessions.first(where: { $0.key == k }) {
                r.sessionId = s.hasTranscript && !s.unregistered ? s.sessionId : nil
                r.cwd = s.cwd; r.tmuxSession = s.tmux?.session
            }
        case .leftover:
            if let l = w.claude.leftovers.first(where: { $0.id == item.id }) {
                r.argv = l.unit.argv; r.cwd = l.unit.cwd ?? l.cwd; r.sessionId = nil
            }
        default: break
        }
        return r
    }
}
