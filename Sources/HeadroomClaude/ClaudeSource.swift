// SPEC §5: Claude Code data collection, plus Jump (§7.6) and session Undo (§7.7).
//
// snapshot(t, o, sys) turns the ownership pass into rows:
//   - one ClaudeSession per live session (OwnershipMap.liveSessions) and per unregistered claude
//     (Owner.unregisteredClaude); memory = claude + children (ppid tree) + background (env-linked units, including
//     automation browsers), all taken from the ownership map so nothing is counted twice;
//   - context from the transcript tail, tmux (resolved live from the ppid chain, never from the JSON `tmux` field),
//     and .git/HEAD;
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
    public let store: SessionStore
    public let tails: TranscriptTail
    public let whereCache = WhereCache()
    public let busyTracker = BusyTracker()
    public let desktop: any ClaudeDesktop
    /// With no CPU history (first snapshot, or a one-shot CLI run) the snapshot re-samples CPU after this delay.
    public var cpuSettle: TimeInterval = 0.3
    /// Test seam: replaces `tmux list-panes` / `list-clients`.
    var tmuxData: (@Sendable () async -> (panes: [TmuxPane], clients: [TmuxClientInfo]))?
    /// Test seam: "now" for busy/idle evaluation (defaults to the table's takenAt).
    var clock: (@Sendable () -> Date)?

    private let lock = NSLock()
    /// Where each session's pane was last seen (for jump without a fresh snapshot).
    private var lastPane: [ProcKey: TmuxPane] = [:]
    private var closedCache: (stamp: FileStamp, titles: [String: String])?
    private let hostName: String

    public init(env: HeadroomEnv = .current, tmux: TmuxClient? = nil, desktop: (any ClaudeDesktop)? = nil,
                watch: Bool = true) {
        self.env = env
        self.tmux = tmux ?? TmuxClient(env: env)
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
    public func snapshot(_ t: ProcessTable, _ o: OwnershipMap, _ sys: any SysKit,
                         tmuxState prefetched: (panes: [TmuxPane], clients: [TmuxClientInfo])?) async -> ClaudeSnapshot {
        let now = clock?() ?? (t.takenAt == .distantPast ? Date() : t.takenAt)
        let records = store.records(now: now)
        var recByPid: [Int32: SessionRecord] = [:]
        for r in records { if let p = r.pid { recByPid[p] = r } }
        let (panes, clients): ([TmuxPane], [TmuxClientInfo])
        if let prefetched { (panes, clients) = (prefetched.panes, prefetched.clients) } else { (panes, clients) = await tmuxState() }

        // Sessions to show: registered live ones, then unregistered claude processes.
        var keys: [(ProcKey, registered: Bool)] = o.liveSessions.map { ($0, true) }
        let unregistered = Set(o.owner.values.compactMap { if case .unregisteredClaude(let k) = $0 { k } else { nil } })
        keys += unregistered.sorted().map { ($0, false) }

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
        for (k, registered) in keys {
            guard let s = t.byPid[k.pid], s.key == k else { continue }
            let rec = registered ? recByPid[k.pid] : nil
            let pane = Self.pane(for: k.pid, in: t, panes: panes)
            if let pane { panesSeen[k] = pane }
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
                kind: rec?.kind ?? (registered ? "interactive" : "unregistered"),
                version: rec?.version ?? Self.versionFromPath(s.path),
                selfFootprint: s.footprint, selfRSS: s.rss, children: kids, background: bgUnits[k] ?? []))
        }

        let leftovers = buildLeftovers(t, o, sys, records: records, now: now, usedTranscripts: &usedTranscripts)

        busyTracker.prune(keeping: Set(keys.map(\.0)))
        tails.prune(keeping: usedTranscripts)
        lock.withLock { lastPane = panesSeen }

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

    public func jump(_ s: ProcKey) async {
        let (panes, clients) = await tmuxState()
        let remembered = lock.withLock { lastPane[s] }
        var pane: TmuxPane?
        if let r = remembered, let p = panes.first(where: { $0.paneId == r.paneId && $0.panePid == r.panePid }) {
            pane = p
        } else {
            // No fresh snapshot (e.g. the CLI): resolve from the live process table.
            let sk = LiveSysKit(env: env)
            let t = sk.scan()
            if t.byPid[s.pid]?.key == s { pane = Self.pane(for: s.pid, in: t, panes: panes) }
        }
        guard let pane else {
            await desktop.focusTerminal(windowName: nil)       // not in tmux: bring the terminal app forward
            return
        }
        guard !clients.isEmpty else {
            await desktop.noClientAttached(attachCommand: "tmux attach -t \(Self.shellQuote(pane.session))")
            return
        }
        if await tmux.jump(paneId: pane.paneId) {
            await desktop.focusTerminal(windowName: pane.windowName)
        } else {
            await desktop.noClientAttached(attachCommand: "tmux attach -t \(Self.shellQuote(pane.session))")
        }
    }

    // MARK: - Reopen (§7.7 session Undo)

    /// `tmux new-window -d -t '<sess>:' -n '<title>' -c '<cwd>'` + `send-keys 'claude --resume <sid>' Enter`.
    /// If the tmux session is gone it is recreated and then jumped to. HEADROOM_DRY_RUN=1 → .dryRun, nothing runs.
    public func reopen(_ r: [ClosedRecord]) async -> [ClosedRecord: Outcome] {
        var out: [ClosedRecord: Outcome] = [:]
        let live = store.records()
        for rec in r {
            out[rec] = await reopenOne(rec, liveRecords: live)
        }
        return out
    }

    public static let fallbackTmuxSession = "headroom"

    func reopenOne(_ rec: ClosedRecord, liveRecords: [SessionRecord]) async -> Outcome {
        guard rec.kind == "session", let sid = rec.sessionId, TranscriptTail.isSafeId(sid) else {
            return .failed("not a restorable session record")
        }
        if let running = liveRecords.first(where: { $0.sessionId == sid }), let pid = running.pid,
           Self.processLooksLive(pid: pid, startedAtMs: running.startedAt) {
            return .failed("session \(sid) is still running (pid \(pid))")
        }
        guard let cwd = rec.cwd, !cwd.isEmpty else { return .failed("no working directory recorded") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return .failed("working directory \(cwd) no longer exists")
        }
        if env.dryRun { return .dryRun }
        let session = SessionTitle.nonEmpty(rec.tmuxSession) ?? Self.fallbackTmuxSession
        let existed = await tmux.hasSession(session)
        guard let paneId = await tmux.newWindow(session: session, name: Self.windowName(rec.title), cwd: cwd) else {
            return .failed("tmux could not open a window in \(session)")
        }
        guard await tmux.sendKeys(pane: paneId, "claude --resume \(sid)") else {
            return .failed("tmux send-keys failed for \(paneId)")
        }
        if !existed {
            let clients = await tmux.clients()
            if clients.isEmpty {
                await desktop.noClientAttached(attachCommand: "tmux attach -t \(Self.shellQuote(session))")
            } else if await tmux.jump(paneId: paneId) {
                await desktop.focusTerminal(windowName: Self.windowName(rec.title))
            }
        }
        return .done
    }

    /// A tmux window name: one line, at most 30 characters.
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
