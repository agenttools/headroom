// SPEC §5: Claude Code data collection, plus Jump (§7.6) and session Undo (§7.7).
//
// snapshot(t, o, sys) turns the ownership pass into rows:
//   - one ClaudeSession per live session (OwnershipMap.liveSessions) and per unregistered claude
//     (Owner.unregisteredClaude); memory = claude + children (ppid tree) + background (env-linked units, including
//     automation browsers), all taken from the ownership map so nothing is counted twice;
//   - context from the transcript tail, tmux (live, from the ppid chain) or Rex (REX_BLOCK when the ppid chain reaches
//     a Rex server before any tmux pane; layout from rex ls/session inspect), never from the JSON `tmux` field, and
//     .git/HEAD;
//   - busy from combined evidence (BusyTracker);
//   - one LeftoverGroup per Owner.leftover, titled from closed.jsonl, the dead session's JSON, or its transcript.
// Paths come from HeadroomEnv (claudeDir, sessionsDir, projectsDir, closedLog); never hard-coded.

import Darwin
import Foundation
import HeadroomContracts
import HeadroomCore

public final class ClaudeSource: ClaudeProvider, @unchecked Sendable {
    public let env: HeadroomEnv
    public let tmux: TmuxClient
    public let rex: RexClient
    public let store: SessionStore
    public let tails: TranscriptTail
    public let whereCache = WhereCache()
    public let busyTracker = BusyTracker()
    public let desktop: any ClaudeDesktop
    /// With no CPU history (first snapshot, or a one-shot CLI run) the snapshot re-samples CPU after this delay.
    public var cpuSettle: TimeInterval = 0.3
    /// Test seam: replaces `tmux list-panes` / `list-clients`.
    var tmuxData: (@Sendable () async -> (panes: [TmuxPane], clients: [TmuxClientInfo]))?
    /// Test seam: replaces `rex ls` + `session inspect` (RexClient.state()); the sessions-first set is ignored.
    var rexData: (@Sendable () async -> RexState)?
    /// Test seam: the process table and SysKit Jump's live fallback uses (default LiveSysKit(env: env)).
    var liveSys: (@Sendable () -> any SysKit)?
    /// Test seam: "now" for busy/idle evaluation (defaults to the table's takenAt).
    var clock: (@Sendable () -> Date)?

    private let lock = NSLock()
    /// Where each session's pane was last seen (for jump without a fresh snapshot).
    private var lastPane: [ProcKey: TmuxPane] = [:]
    /// The same for sessions in Rex (their block, from REX_BLOCK).
    private var lastRex: [ProcKey: RexLoc] = [:]
    /// Notes from the last reopen(): a new Rex session that Rex.app could not be asked to show (Remote Control off,
    /// Rex.app not connected …). The app's Undo toast and `headroom undo` show them.
    public var lastReopenNotes: [String] { lock.withLock { _reopenNotes } }
    private var _reopenNotes: [String] = []
    private var closedCache: (stamp: FileStamp, titles: [String: String])?
    private let hostName: String

    public init(env: HeadroomEnv = .current, tmux: TmuxClient? = nil, rex: RexClient? = nil,
                desktop: (any ClaudeDesktop)? = nil, watch: Bool = true) {
        self.env = env
        self.tmux = tmux ?? TmuxClient(env: env)
        self.rex = rex ?? RexClient(env: env)
        self.store = SessionStore(dir: env.sessionsDir, watch: watch)
        self.tails = TranscriptTail(projectsDir: env.projectsDir)
        self.desktop = desktop ?? GhosttyDesktop()
        var buf = [CChar](repeating: 0, count: 256)
        hostName = gethostname(&buf, buf.count) == 0
            ? String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    }

    // MARK: - ClaudeProvider

    public func sessionRecords() async -> [SessionRecord] { store.records() }

    public func snapshot(_ t: ProcessTable, _ o: OwnershipMap, _ sys: any SysKit) async -> ClaudeSnapshot {
        await snapshot(t, o, sys, tmuxState: nil)
    }

    /// `tmuxState`: panes and clients the caller already fetched this refresh (LiveWorld reuses the ownership
    /// pass's `list-panes` instead of running tmux again); nil = fetch now.
    /// `rexState`: Rex discovery the caller already ran (LiveWorld's cache); nil = run it now, but only when some
    /// claude's ppid chain reaches a Rex server (no rex call otherwise).
    public func snapshot(_ t: ProcessTable, _ o: OwnershipMap, _ sys: any SysKit,
                         tmuxState prefetched: (panes: [TmuxPane], clients: [TmuxClientInfo])?,
                         rexState rexPrefetched: RexState? = nil) async -> ClaudeSnapshot {
        let now = clock?() ?? (t.takenAt == .distantPast ? Date() : t.takenAt)
        let records = store.records(now: now)
        var recByPid: [Int32: SessionRecord] = [:]
        for r in records { if let p = r.pid { recByPid[p] = r } }
        let (panes, clients): ([TmuxPane], [TmuxClientInfo])
        if let prefetched { (panes, clients) = (prefetched.panes, prefetched.clients) } else { (panes, clients) = await tmuxState() }

        // Sessions to show: registered live ones, then unregistered claude processes.
        let keys = Self.sessionKeys(o)

        // Rex: which claudes run in a Rex block (pure ppid walk), then their blocks' layout (rex calls only if any).
        let inRex = Self.rexKeys(keys.map(\.0), in: t, sys: sys, tmuxPanePids: Set(panes.map(\.panePid)))
        let rexNow: RexState
        if inRex.isEmpty {
            rexNow = .empty
        } else if let rexPrefetched {
            rexNow = rexPrefetched
        } else {
            rexNow = await rexState(sessionsFirst: Self.rexSessionIds(inRex, sys: sys))
        }

        // Units per session (children: ppid tree; background: env-linked).
        var childUnits: [ProcKey: [LinkedUnit]] = [:]
        var bgUnits: [ProcKey: [LinkedUnit]] = [:]
        for (k, _) in keys {
            childUnits[k] = Ownership.units(of: .claudeChild(k), in: t, map: o, sys: sys)
            bgUnits[k] = Ownership.units(of: .claudeBackground(k), in: t, map: o, sys: sys)
        }
        func cpuMembers(_ k: ProcKey) -> [ProcKey] { [k] + (childUnits[k] ?? []).flatMap(\.members) }
        let tracked = keys.flatMap { cpuMembers($0.0) }

        // CPU: average over the last 3 samples; without history, take a second sample now.
        var cpuTable = t
        if !busyTracker.hasHistory && cpuSettle > 0 && !keys.isEmpty {
            busyTracker.record(t, keys: tracked)
            try? await Task.sleep(nanoseconds: UInt64(cpuSettle * 1e9))
            cpuTable = sys.scan()
        }
        var cpu: [ProcKey: Double] = [:]
        for (k, _) in keys { cpu[k] = busyTracker.cpuPercent(members: cpuMembers(k), in: cpuTable) }
        busyTracker.record(cpuTable, keys: tracked)

        let myAncestors = Set(t.ancestors(of: getpid()))
        var sessions: [ClaudeSession] = []
        var usedTranscripts: Set<String> = []
        var panesSeen: [ProcKey: TmuxPane] = [:]
        var rexSeen: [ProcKey: RexLoc] = [:]
        for (k, registered) in keys {
            guard let s = t.byPid[k.pid], s.key == k else { continue }
            let rec = registered ? recByPid[k.pid] : nil
            let pane: TmuxPane?
            let rexLoc: RexLoc?
            if inRex.contains(k) {
                // The nearest boundary is a Rex server, so any tmux pane further up is not where it runs.
                let e = sys.args(k)?.env
                rexLoc = RexClient.locate(blockEnv: e?["REX_BLOCK"], sessionEnv: e?["REX_SESSION"], state: rexNow)
                pane = nil
            } else {
                rexLoc = nil
                pane = Self.pane(for: k.pid, in: t, panes: panes)
            }
            if let pane { panesSeen[k] = pane }
            if let rexLoc { rexSeen[k] = rexLoc }
            let argv = sys.args(k)?.argv ?? []
            let sessionId = rec?.sessionId ?? Self.sessionIdFromArgv(argv) ?? ""
            let cwd = rec?.cwd ?? sys.cwd(k.pid) ?? ""
            let whereInfo = whereCache.lookup(cwd: cwd, now: now)
            var tail = TranscriptInfo()
            if !sessionId.isEmpty {
                tail = tails.info(sessionId: sessionId, cwd: cwd, now: now)
                if let p = tail.path { usedTranscripts.insert(p) }
            }
            let kids = childUnits[k] ?? []
            let members = kids.flatMap(\.members)
            let statusUpdated = rec?.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            let (evidence, since) = busyTracker.evaluate(
                key: k, status: rec?.status, registered: registered, statusUpdatedAt: statusUpdated,
                lastActivity: tail.lastActivity, cpuPercent: cpu[k],
                childPaths: members.compactMap { t.byPid[$0.pid]?.path },
                childStarts: members.map(\.startSec), now: now)
            let title = SessionTitle.choose(name: rec?.name, nameSource: rec?.nameSource, customTitle: tail.customTitle,
                                            aiTitle: tail.aiTitle, paneTitle: pane?.paneTitle,
                                            project: whereInfo.project, hostName: hostName)
            let startedAt = rec?.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? Date(timeIntervalSince1970: TimeInterval(k.startSec))
            let isLauncher = env.launcherClaudePid == k.pid || myAncestors.contains(k.pid)
            sessions.append(ClaudeSession(
                key: k, sessionId: sessionId, cwd: cwd, title: title, project: whereInfo.project,
                worktree: whereInfo.worktree, branch: whereInfo.branch, cwdExists: whereInfo.cwdExists,
                hasTranscript: tail.exists, busy: evidence.busy,
                remoteControl: !(rec?.bridgeSessionId ?? "").isEmpty, isLauncher: isLauncher,
                unregistered: !registered, status: registered ? (rec?.status ?? "unknown") : "unknown",
                statusSince: since, lastActivity: tail.lastActivity, startedAt: startedAt,
                cpuPercent: cpu[k] ?? 0, lastPrompt: tail.lastPrompt, lastAssistant: tail.lastAssistant,
                awaySummary: tail.awaySummary, tmux: pane.map { TmuxClient.location(of: $0, clients: clients) },
                rex: rexLoc, kind: rec?.kind ?? (registered ? "interactive" : "unregistered"),
                version: rec?.version ?? Self.versionFromPath(s.path),
                selfFootprint: s.footprint, selfRSS: s.rss, children: kids, background: bgUnits[k] ?? []))
        }

        let leftovers = buildLeftovers(t, o, sys, records: records, now: now, usedTranscripts: &usedTranscripts)

        busyTracker.prune(keeping: Set(keys.map(\.0)))
        tails.prune(keeping: usedTranscripts)
        lock.withLock { lastPane = panesSeen; lastRex = rexSeen }

        sessions.sort { ($0.total, $0.key.pid) > ($1.total, $1.key.pid) }
        return ClaudeSnapshot(sessions: sessions, leftovers: leftovers, staleFiles: o.staleSessionFiles)
    }

    // MARK: - tmux

    func tmuxState() async -> ([TmuxPane], [TmuxClientInfo]) {
        if let tmuxData { let d = await tmuxData(); return (d.panes, d.clients) }
        async let p = tmux.panes()
        async let c = tmux.clients()
        return await (p, c)
    }

    /// The pane whose pane_pid is the nearest ancestor of the claude pid (usually its ppid, the pane's shell).
    /// The JSON `tmux` field is stale and is not used to place a session.
    static func pane(for pid: Int32, in t: ProcessTable, panes: [TmuxPane]) -> TmuxPane? {
        guard !panes.isEmpty else { return nil }
        var byPid: [Int32: TmuxPane] = [:]
        for p in panes { byPid[p.panePid] = p }
        if let p = byPid[pid] { return p }                 // claude exec'd as the pane command itself
        for a in t.ancestors(of: pid) { if let p = byPid[a] { return p } }
        return nil
    }

    /// The sessions a snapshot shows: registered live ones, then unregistered claude processes.
    static func sessionKeys(_ o: OwnershipMap) -> [(ProcKey, registered: Bool)] {
        var keys: [(ProcKey, registered: Bool)] = o.liveSessions.map { ($0, true) }
        let unregistered = Set(o.owner.values.compactMap { if case .unregisteredClaude(let k) = $0 { k } else { nil } })
        keys += unregistered.sorted().map { ($0, false) }
        return keys
    }

    // MARK: - Rex

    /// The keys whose nearest multiplexer boundary up the ppid chain is a Rex server (a tmux pane or tmux process
    /// met first means tmux). Pure, no rex call; empty when no Rex server is in the table.
    static func rexKeys(_ keys: [ProcKey], in t: ProcessTable, sys: any SysKit,
                        tmuxPanePids: Set<Int32>) -> Set<ProcKey> {
        let topo = RexProcess.topology(in: t, sys: sys)
        guard !topo.servers.isEmpty else { return [] }
        return Set(keys.filter { k in
            guard t.byPid[k.pid]?.key == k else { return false }
            if case .rex = RexProcess.boundary(of: k.pid, in: t, topology: topo, sys: sys, tmuxPanePids: tmuxPanePids) {
                return true
            }
            return false
        })
    }

    /// The Rex sessions the claudes in `keys` name in their REX_SESSION (discovery inspects these first).
    static func rexSessionIds(_ keys: Set<ProcKey>, sys: any SysKit) -> Set<String> {
        Set(keys.compactMap { sys.args($0)?.env["REX_SESSION"] }.filter { $0.hasPrefix("session:") })
    }

    /// nil when no live or unregistered claude in `o` has RexBoundary .rex (pure; no rex call). Otherwise the Rex
    /// sessions those claudes name (possibly empty), which discovery inspects first. LiveWorld runs Rex discovery
    /// (`rex ls` + `session inspect`) only when this is not nil.
    public static func rexSessionsNeeded(_ t: ProcessTable, _ o: OwnershipMap, _ sys: any SysKit,
                                         tmuxPanes: [TmuxPane]) -> Set<String>? {
        let keys = rexKeys(sessionKeys(o).map(\.0), in: t, sys: sys, tmuxPanePids: Set(tmuxPanes.map(\.panePid)))
        return keys.isEmpty ? nil : rexSessionIds(keys, sys: sys)
    }

    /// Some live or unregistered claude in `o` has RexBoundary .rex (pure; no rex call).
    public static func rexNeeded(_ t: ProcessTable, _ o: OwnershipMap, _ sys: any SysKit, tmuxPanes: [TmuxPane]) -> Bool {
        rexSessionsNeeded(t, o, sys, tmuxPanes: tmuxPanes) != nil
    }

    /// A discovery pass. `sessionsFirst`: the sessions to inspect first and always (RexClient.state(sessionsFirst:)).
    func rexState(sessionsFirst: Set<String> = []) async -> RexState {
        if let rexData { return await rexData() }
        return await rex.state(sessionsFirst: sessionsFirst)
    }

    // MARK: - Leftovers

    func buildLeftovers(_ t: ProcessTable, _ o: OwnershipMap, _ sys: any SysKit, records: [SessionRecord],
                        now: Date, usedTranscripts: inout Set<String>) -> [LeftoverGroup] {
        var owners: Set<Owner> = []
        for v in o.owner.values { if case .leftover = v { owners.insert(v) } }
        guard !owners.isEmpty else { return [] }
        let closedTitles = closedSessionTitles()
        var out: [LeftoverGroup] = []
        for owner in owners {
            guard case let .leftover(pgid, dead) = owner else { continue }
            let units = Ownership.units(of: owner, in: t, map: o, sys: sys)
            guard let unit = Self.merge(units, pgid: pgid) else { continue }
            let id = Ownership.leftoverID(pgid: pgid, members: unit.members, table: t)
            // CLAUDE_CODE_SESSION_ID of the dead session, from any member that shows it.
            var sid: String?
            for m in [unit.root] + unit.members {
                if let v = sys.args(m)?.env["CLAUDE_CODE_SESSION_ID"], !v.isEmpty { sid = v; break }
            }
            let deadRec = records.first { $0.pid == dead && (sid == nil || $0.sessionId == sid) }
            sid = sid ?? deadRec?.sessionId
            let cwd = unit.cwd ?? deadRec?.cwd
            var title: String?
            if let sid, let c = closedTitles[sid] { title = c }
            if title == nil, let r = deadRec, r.nameSource == "user", let n = SessionTitle.nonEmpty(r.name) { title = n }
            if title == nil, let sid {
                let info = tails.info(sessionId: sid, cwd: deadRec?.cwd, now: now)
                if let p = info.path { usedTranscripts.insert(p) }
                title = SessionTitle.nonEmpty(info.aiTitle) ?? SessionTitle.nonEmpty(info.customTitle)
            }
            if title == nil { title = SessionTitle.nonEmpty(deadRec?.name) }
            let startSec: Int
            if case let .leftover(_, s) = id { startSec = s } else { startSec = unit.root.startSec }
            out.append(LeftoverGroup(id: id, unit: unit, deadClaudePid: dead, sessionId: sid, sessionTitle: title,
                                     cwd: cwd, startedAt: Date(timeIntervalSince1970: TimeInterval(startSec))))
        }
        return out.sorted { ($0.unit.footprint, $0.unit.pgid) > ($1.unit.footprint, $1.unit.pgid) }
    }

    /// One LinkedUnit for a leftover group: the root is the process-group leader's unit when present, else the
    /// largest unit; members and bytes are the union of all units.
    static func merge(_ units: [LinkedUnit], pgid: Int32) -> LinkedUnit? {
        guard !units.isEmpty else { return nil }
        let main = units.first { $0.root.pid == pgid } ?? units.max { $0.footprint < $1.footprint }!
        if units.count == 1 { return main }
        let members = Array(Set(units.flatMap(\.members))).sorted()
        return LinkedUnit(root: main.root, pgid: pgid, command: main.command, argv: main.argv, cwd: main.cwd,
                          members: members, footprint: units.reduce(0) { $0 + $1.footprint },
                          isAutomationBrowser: units.contains { $0.isAutomationBrowser })
    }

    /// sessionId → title from closed.jsonl (Recently Closed, written by the Journal). Cached by file stamp.
    func closedSessionTitles() -> [String: String] {
        let path = env.closedLog
        guard let st = FileStamp(path: path) else { return [:] }
        lock.lock()
        if let c = closedCache, c.stamp == st { lock.unlock(); return c.titles }
        lock.unlock()
        var titles: [String: String] = [:]
        if let d = FileManager.default.contents(atPath: path), let s = String(data: d, encoding: .utf8) {
            for line in s.split(separator: "\n") {
                guard let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let sid = j["sessionId"] as? String, let title = j["title"] as? String, !title.isEmpty
                else { continue }
                titles[sid] = title
            }
        }
        lock.lock(); closedCache = (st, titles); lock.unlock()
        return titles
    }

    // MARK: - Helpers

    /// `--resume <id>`, `-r <id>`, `--session-id <id>` (and their `=` forms) in a claude argv.
    static func sessionIdFromArgv(_ argv: [String]) -> String? {
        let flags = ["--resume", "-r", "--session-id"]
        for (i, a) in argv.enumerated() {
            for f in flags {
                if a == f, i + 1 < argv.count, TranscriptTail.isSafeId(argv[i + 1]) { return argv[i + 1] }
                if a.hasPrefix(f + "="), case let v = String(a.dropFirst(f.count + 1)), TranscriptTail.isSafeId(v) {
                    return v
                }
            }
        }
        return nil
    }

    /// ".../claude/versions/2.1.284" → "2.1.284".
    static func versionFromPath(_ path: String) -> String {
        guard let r = path.range(of: KnownPaths.claudeVersionsMarker) else { return "" }
        return String(path[r.upperBound...].split(separator: "/").first ?? "")
    }

    // MARK: - Jump (§7.6)

    public func jump(_ s: ProcKey) async { _ = await jumpNote(s) }

    /// Jump, then a note for the user when Jump could not finish the switch (nil = nothing to say): for tmux, when
    /// the session's Ghostty window could not be brought forward, tmux refused, or no client is attached.
    /// Jump is not gated by HEADROOM_DRY_RUN, for tmux or Rex: it changes what is shown, never what runs.
    public func jumpNote(_ s: ProcKey) async -> String? {
        if let r = lock.withLock({ lastRex[s] }) { return await rexJump(blockId: r.blockId) }
        let (panes, clients) = await tmuxState()
        let remembered = lock.withLock { lastPane[s] }
        var pane: TmuxPane?
        if let r = remembered, let p = panes.first(where: { $0.paneId == r.paneId && $0.panePid == r.panePid }) {
            pane = p
        } else {
            // No snapshot placed this session (e.g. no REX_BLOCK at snapshot time, or Jump before any snapshot):
            // resolve from the live process table.
            let sk: any SysKit = liveSys?() ?? LiveSysKit(env: env)
            let t = sk.scan()
            if t.byPid[s.pid]?.key == s {
                let topo = RexProcess.topology(in: t, sys: sk)
                if !topo.servers.isEmpty,
                   case .rex = RexProcess.boundary(of: s.pid, in: t, topology: topo, sys: sk,
                                                   tmuxPanePids: Set(panes.map(\.panePid))) {
                    return await rexJump(blockId: sk.args(s)?.env["REX_BLOCK"])
                }
                pane = Self.pane(for: s.pid, in: t, panes: panes)
            }
        }
        guard let pane else {
            _ = await desktop.focusTerminal(tty: nil)          // not in tmux: bring the terminal app forward
            return nil
        }
        switch await tmux.jump(to: pane, clients: clients) {       // the state read above: no second listing
        case .switched(let tty, let session):
            return Self.tmuxFocusNote(await desktop.focusTerminal(tty: tty), session: session, tty: tty)
        case .noClient(let session):
            return await tmuxNoClient(session: session)
        case .noPane:                                              // not answered by jump(to:clients:)
            _ = await desktop.focusTerminal(tty: nil)
            return "This session's tmux pane is gone, so Ghostty was only brought forward."
        case .failed(let session, let reason):
            _ = await desktop.focusTerminal(tty: nil)
            return "tmux could not switch to “\(session)” (\(reason)), so Ghostty was only brought forward."
        }
    }

    /// SPEC §7.6 step 5: nothing shows the session, so the attach command goes to the clipboard and Ghostty comes
    /// forward. The note says so, because the clipboard changed.
    private func tmuxNoClient(session: String) async -> String {
        let command = "tmux attach -t \(Self.shellQuote(session))"
        await desktop.noClientAttached(attachCommand: command)
        return "No terminal is attached to tmux. Copied “\(command)”: paste it in Ghostty."
    }

    /// The note for a tmux Jump whose client was switched (SPEC §7.6 step 4): nil when the right Ghostty window came
    /// forward, else what happened instead and what to do about it.
    static func tmuxFocusNote(_ focus: TerminalFocus, session: String, tty: String) -> String? {
        switch focus {
        case .exact, .appOnly:
            return nil
        case .notAllowed:
            return "tmux switched to “\(session)”, but Ghostty may show another window. To fix this, allow Headroom "
                + "to control Ghostty in System Settings ▸ Privacy & Security ▸ Automation."
        case .notFound:
            return "tmux switched to “\(session)”, but its terminal (\(tty)) is not a Ghostty window, so Ghostty was "
                + "only brought forward."
        case .failed(let why):
            return "tmux switched to “\(session)”, but Ghostty may show another window (\(why))."
        }
    }

    /// Rex Jump (§7.6): `rex focus -s SID BID` on the server, bring Rex.app forward, then ask the app to show the
    /// session's tab (`do session.select`, a client action that needs Remote Control in Rex). Rex has no attach
    /// command to hand the user, so a failure becomes a note that says why.
    private func rexJump(blockId: String?) async -> String? {
        let st = await rexState()
        guard let id = blockId, let b = st.blocks.first(where: { $0.blockId == id }) else {
            await desktop.focusRex()
            return "Rex could not find this session's pane, so Rex was only brought forward."
        }
        _ = await rex.focus(session: b.sessionId, block: b.blockId)
        await desktop.focusRex()                    // before the client action: it needs the app in front
        guard let why = await rexSelect(session: b.sessionId, window: b.windowId, known: st, action: "Jump") else {
            return nil
        }
        return "If Rex shows another session, open “\(Self.rexSessionName(id: b.sessionId, label: b.sessionLabel))”. "
            + why
    }

    /// Asks Rex.app on this Mac (already brought forward) to show `window` of `session` with `do session.select`,
    /// sent to a connected LOCAL app client (RexClient.jumpClient). `known`: a discovery pass made before Rex.app came
    /// forward; when it has no local client, the state is read again (Rex.app may have just connected). With no local
    /// client while another device's app is connected, nothing is sent: rex's default client would be that device.
    /// nil when Rex.app switched; otherwise the reason, for the note (`action`: "Jump" or "Undo").
    private func rexSelect(session: String, window: String, known: RexState?, action: String) async -> String? {
        let st: RexState
        if let known, RexClient.jumpClient(session: session, state: known) != nil {
            st = known
        } else {
            st = await rexState()
        }
        let c = RexClient.jumpClient(session: session, state: st)
        if c == nil, RexClient.remoteAppConnected(st) {
            return "Rex.app on this Mac is not connected to the Rex server, and Headroom does not switch Rex on "
                + "another device."
        }
        let r = await rex.select(session: session, window: window, client: c?.clientId)
        return r.ok ? nil : RexClient.selectFailureReason(r, action: action)
    }

    /// A Rex session's label, or "…" + the last 6 characters of its id when it has none (as RexLoc.sessionName).
    static func rexSessionName(id: String, label: String) -> String {
        label.isEmpty ? "…" + String(id.suffix(6)) : label
    }

    // MARK: - Reopen (§7.7 session Undo)

    /// `tmux new-window -d -t '<sess>:' -n '<title>' -c '<cwd>'` + `send-keys 'claude --resume <sid>' Enter`.
    /// If the tmux session is gone it is recreated and then jumped to. HEADROOM_DRY_RUN=1 → .dryRun, nothing runs.
    /// A record of a session that ran in Rex (rexSessionId/rexSessionLabel), or one in neither multiplexer when only
    /// rex is installed, reopens in Rex instead (reopenRex). Notes for the user (a new Rex session Rex.app could not
    /// be asked to show) replace lastReopenNotes.
    public func reopen(_ r: [ClosedRecord]) async -> [ClosedRecord: Outcome] {
        var out: [ClosedRecord: Outcome] = [:]
        var notes: [String] = []
        let live = store.records()
        for rec in r {
            let (o, n) = await reopenOne(rec, liveRecords: live)
            out[rec] = o
            if let n { notes.append(n) }
        }
        lock.withLock { _reopenNotes = notes }
        return out
    }

    public static let fallbackTmuxSession = "headroom"
    /// The Rex session Undo opens a tab in when the record names none (created when missing).
    public static let fallbackRexSession = "headroom"

    /// The outcome, and a note for the user when there is something to say (Rex only).
    func reopenOne(_ rec: ClosedRecord, liveRecords: [SessionRecord]) async -> (Outcome, String?) {
        guard rec.kind == "session", let sid = rec.sessionId, TranscriptTail.isSafeId(sid) else {
            return (.failed("not a restorable session record"), nil)
        }
        if let running = liveRecords.first(where: { $0.sessionId == sid }), let pid = running.pid,
           Self.processLooksLive(pid: pid, startedAtMs: running.startedAt) {
            return (.failed("session \(sid) is still running (pid \(pid))"), nil)
        }
        guard let cwd = rec.cwd, !cwd.isEmpty else { return (.failed("no working directory recorded"), nil) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return (.failed("working directory \(cwd) no longer exists"), nil)
        }
        if env.dryRun { return (.dryRun, nil) }
        let rexRecorded = SessionTitle.nonEmpty(rec.rexSessionId) != nil || SessionTitle.nonEmpty(rec.rexSessionLabel) != nil
        let tmuxRecorded = SessionTitle.nonEmpty(rec.tmuxSession) != nil
        let fm = FileManager.default
        let useRex = rexRecorded || (!tmuxRecorded && !fm.isExecutableFile(atPath: env.tmuxPath)
                                     && fm.isExecutableFile(atPath: env.rexPath))
        if !useRex {
            let session = SessionTitle.nonEmpty(rec.tmuxSession) ?? Self.fallbackTmuxSession
            let existed = await tmux.hasSession(session)
            guard let paneId = await tmux.newWindow(session: session, name: Self.windowName(rec.title), cwd: cwd) else {
                return (.failed("tmux could not open a window in \(session)"), nil)
            }
            guard await tmux.sendKeys(pane: paneId, "claude --resume \(sid)") else {
                return (.failed("tmux send-keys failed for \(paneId)"), nil)
            }
            if !existed {
                let clients = await tmux.clients()
                if clients.isEmpty {
                    await desktop.noClientAttached(attachCommand: "tmux attach -t \(Self.shellQuote(session))")
                } else if let tty = await tmux.jump(paneId: paneId).tty {
                    _ = await desktop.focusTerminal(tty: tty)
                }
            }
            return (.done, nil)
        }
        return await reopenRex(rec, sid: sid, cwd: cwd)
    }

    /// Rex Undo (§7.7): a new tab (`window new … --focus=false`) in the recorded session (by id, else by label), or a
    /// new session (`new`) when neither exists; then `send 'claude --resume <sid>'` + `send-key enter` into its block.
    /// A `window new`/`new` that failed or timed out may still have worked, so the session is compared before and
    /// after the call and the one new tab (or session) is adopted rather than opening a second one. A created
    /// session is then shown (Rex.app forward, `do session.select`); when Rex.app cannot be asked to show it, the
    /// outcome stays .done (the session was reopened) and a note names the new session. Rex is never started: when it
    /// is not running Undo fails and the record stays restorable.
    func reopenRex(_ rec: ClosedRecord, sid: String, cwd: String) async -> (Outcome, String?) {
        guard FileManager.default.isExecutableFile(atPath: env.rexPath) else {
            return (.failed("rex is not installed (\(env.rexPath))"), nil)
        }
        guard let refs = await rex.sessions() else {
            return (.failed("Rex is not running (open Rex, then Undo again)"), nil)
        }
        let label = SessionTitle.nonEmpty(rec.rexSessionLabel) ?? Self.fallbackRexSession
        let name = Self.windowName(rec.title)
        let recordedId = SessionTitle.nonEmpty(rec.rexSessionId)
        let target = refs.first { recordedId != nil && $0.sessionId == recordedId } ?? refs.first { $0.label == label }
        let made: RexNewTerminal
        let created: Bool
        if let target {
            // Recovery needs a known "before": with a failed inspect, an older tab of the same name could be adopted.
            let before = await rex.inspect(target.sessionId)?.blocks
            var m = await rex.newWindow(session: target.sessionId, name: name, cwd: cwd)
            if m == nil, let before {
                m = RexClient.recoverNewWindow(before: before, after: await rex.inspect(target.sessionId)?.blocks ?? [],
                                               sessionId: target.sessionId, name: name)
            }
            guard let m else {
                return (.failed("Rex could not open a tab in “\(Self.rexSessionName(id: target.sessionId, label: target.label))”"), nil)
            }
            (made, created) = (m, false)
        } else {
            var m = await rex.newSession(label: label, cwd: cwd, windowName: name)
            if m == nil,
               let id = RexClient.recoverNewSession(before: refs, after: await rex.sessions() ?? [], label: label),
               let ins = await rex.inspect(id), let b = ins.blocks.first {
                m = RexNewTerminal(sessionId: id, windowId: b.windowId, blockId: b.blockId)
            }
            guard let m else { return (.failed("Rex could not create session “\(label)”"), nil) }
            (made, created) = (m, true)
        }
        guard await rex.sendLine(session: made.sessionId, block: made.blockId, "claude --resume \(sid)") else {
            return (.failed("Rex opened a tab but could not type the resume command"), nil)
        }
        if created {
            // A new session is not shown by any app yet (window new into an existing one leaves the view alone).
            await desktop.focusRex()
            if let why = await rexSelect(session: made.sessionId, window: made.windowId, known: nil, action: "Undo") {
                let n = Self.rexSessionName(id: made.sessionId, label: label)
                return (.done, "Resumed in the new Rex session “\(n)”; open it in Rex. " + why)
            }
        }
        return (.done, nil)
    }

    /// A tmux window name (and a Rex tab label): one line, at most 30 characters.
    static func windowName(_ title: String) -> String {
        let one = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let s = one.isEmpty ? "claude" : one
        return s.count > 30 ? String(s.prefix(29)) + "…" : s
    }

    /// Read-only liveness probe (proc_pidinfo, no signal): pid exists and started near `startedAtMs`.
    static func processLooksLive(pid: Int32, startedAtMs: Double?) -> Bool {
        guard let bi = LiveSysKit.bsdInfo(pid) else { return false }
        guard let ms = startedAtMs else { return true }
        return abs(Double(bi.pbi_start_tvsec) - ms / 1000) <= Ownership.startedAtTolerance
    }

    static func shellQuote(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.".unicodeScalars.contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
