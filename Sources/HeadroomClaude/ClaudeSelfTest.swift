// `--selftest claude` (SPEC §11), read-only on live data:
//
//     let r = await ClaudeSelfTest.run(env: env, hosts: { await chrome.hosts() })
//     print(r.render()); exit(r.passed ? 0 : 1)
//
// It scans processes, reads ~/.claude/sessions and transcript tails, and runs `tmux list-panes` / `list-clients`.
// It never signals, writes, or runs a mutating tmux command.

import Darwin
import Foundation
import HeadroomContracts
import HeadroomCore

public enum ClaudeSelfTest {
    /// Tail budget: 22 transcript tails in under 20 ms (cold cache).
    public static let group = "claude"
    public static let tailBudgetMs = 20.0
    public static let tailBudgetCount = 22
    /// Footprint total must be within 2% of a separate ps-based sum of the same process trees.
    public static let footprintTolerance = 0.02

    public static func run(env: HeadroomEnv = .current,
                           hosts: (@Sendable () async -> [Wire.HostHello])? = nil) async -> SelfTestReport {
        var r = SelfTestReport()
        let sk = LiveSysKit(env: env)
        let source = ClaudeSource(env: env, watch: false)
        source.cpuSettle = 0.5
        let g = "claude"

        // Session files.
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: env.sessionsDir)) ?? []).filter { $0.hasSuffix(".json") }
        let records = await source.sessionRecords()
        r.add(g, "session-files", records.count == names.count,
              "\(records.count) of \(names.count) JSON files in \(env.sessionsDir) decoded")

        // Ownership over one table (the same table feeds every comparison below).
        let panes = await source.tmux.panes()
        let clients = await source.tmux.clients()
        let t = sk.scan()
        let hs = await hosts?() ?? []
        let map = Ownership.assign(t, sessions: records, hosts: hs, tmuxPanes: panes, sys: sk, env: env)

        // No false stale entries: a stale file must not belong to a running claude.
        var falseStale: [String] = []
        var staleWhy: [String] = []
        for f in map.staleSessionFiles {
            let rec = records.first { $0.filePath == f }
            let base = (f as NSString).lastPathComponent
            guard let pid = rec?.pid, let s = t.byPid[pid] else { staleWhy.append("\(base): pid gone"); continue }
            if isClaude(s, sk: sk, env: env) {
                falseStale.append("\(base): pid \(pid) is a running claude (procStart \(rec?.procStart ?? "-"), started \(s.key.startSec))")
            } else {
                staleWhy.append("\(base): pid \(pid) reused by \((s.path as NSString).lastPathComponent)")
            }
        }
        r.add(g, "no-false-stale", falseStale.isEmpty,
              falseStale.isEmpty ? "\(map.liveSessions.count) live, \(map.staleSessionFiles.count) stale (\(staleWhy.joined(separator: "; ")))"
                                 : falseStale.joined(separator: "; "))

        // Every running claude process is either a live session or an unregistered row.
        let runningClaude = t.byPid.values.filter { $0.uid == getuid() && isClaude($0, sk: sk, env: env) }
        let unaccounted = runningClaude.filter { s in
            switch map.owner[s.pid] { case .session, .unregisteredClaude: false; default: s.pid != getpid() }
        }
        r.add(g, "every-claude-listed", unaccounted.isEmpty,
              "\(runningClaude.count) claude processes; unaccounted: \(unaccounted.map(\.pid).sorted())")

        // The snapshot.
        let snap = await source.snapshot(t, map, sk)
        let registered = snap.sessions.filter { !$0.unregistered }
        let listedKeys = Set(registered.map(\.key))
        let missing = map.liveSessions.filter { !listedKeys.contains($0) }
        let incomplete = registered.filter { $0.title.isEmpty || $0.sessionId.isEmpty || $0.cwd.isEmpty }
        r.add(g, "sessions-listed", missing.isEmpty && incomplete.isEmpty,
              "\(registered.count) sessions + \(snap.sessions.count - registered.count) unregistered listed; missing \(missing.map(\.pid)); without title/id/cwd \(incomplete.map(\.key.pid))")

        // Footprint vs a separate ps-based sum: Σ over live claude sessions of (self + every ppid descendant), on the
        // same table. That raw sum counts a nested session's subtree twice and counts this selftest process; both are
        // removed here so
        // the comparison is like for like (the adjustments are printed).
        let nestedRoots = Set(map.liveSessions.map(\.pid))
        var ccRaw: Bytes = 0, ccAdj: Bytes = 0
        for k in map.liveSessions {
            guard let s = t.byPid[k.pid] else { continue }
            let d = t.descendants(of: k.pid)
            ccRaw += s.footprint + t.footprint(of: d)
            // Adjusted: skip nested sessions' subtrees and ourselves.
            var skip: Set<Int32> = [getpid()]
            for p in d where nestedRoots.contains(p) { skip.insert(p); skip.formUnion(t.descendants(of: p)) }
            ccAdj += s.footprint + t.footprint(of: d.filter { !skip.contains($0) })
        }
        let ours = registered.reduce(Bytes(0)) { $0 + $1.selfFootprint + $1.childrenBytes }
        let diff = ccAdj == 0 ? 0 : abs(Double(ours) - Double(ccAdj)) / Double(ccAdj)
        r.add(g, "footprint-vs-ps-sum", diff <= footprintTolerance,
              String(format: "self+children %@ vs ps-sum method %@ (%.2f%%); ps-sum raw %@; background adds %@",
                     ByteFormat.short(ours), ByteFormat.short(ccAdj), diff * 100, ByteFormat.short(ccRaw),
                     ByteFormat.short(registered.reduce(0) { $0 + $1.backgroundBytes })))
        // Headroom's own process chain inside a session (this process and e.g. `swift test` when run from a claude
        // shell) is tooling noise in both methods.
        let tooling = ([getpid()] + t.ancestors(of: getpid())).filter {
            if case .claudeChild = map.owner[$0] { true } else { $0 == getpid() }
        }
        r.notes.append("self exact: \(registered.reduce(Bytes(0)) { $0 + $1.selfFootprint }) B; children exact: \(registered.reduce(Bytes(0)) { $0 + $1.childrenBytes }) B; Headroom's own chain under a session: \(t.footprint(of: tooling)) B (pids \(tooling))")
        r.notes.append("self+children exact: \(ours) B (ps-sum method \(ccAdj) B, raw \(ccRaw) B)")

        // Transcript tails: cold read of every live session's tail.
        let cold = TranscriptTail(projectsDir: env.projectsDir)
        let targets = snap.sessions.filter { !$0.sessionId.isEmpty }
        let paths = targets.compactMap { cold.locate(sessionId: $0.sessionId, cwd: $0.cwd) }
        var infos: [TranscriptInfo] = []
        let t0 = DispatchTime.now().uptimeNanoseconds
        for p in paths { infos.append(cold.info(path: p)) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let t1 = DispatchTime.now().uptimeNanoseconds
        for p in paths { _ = cold.info(path: p) }
        let warm = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6
        let per22 = paths.isEmpty ? 0 : ms * Double(tailBudgetCount) / Double(paths.count)
        let bytes = infos.reduce(0) { $0 + $1.bytesRead }
        let sizes = infos.reduce(Int64(0)) { $0 + $1.size }
        r.add(g, "transcript-tails", per22 < tailBudgetMs,
              String(format: "%d tails in %.2f ms (= %.2f ms per 22, budget %.0f); read %@ of %@; warm re-read %.3f ms; %d with activity",
                     paths.count, ms, per22, tailBudgetMs, ByteFormat.short(Bytes(bytes)), ByteFormat.short(Bytes(sizes)),
                     warm, infos.filter { $0.lastActivity != nil }.count))

        // tmux: `current` is at most one pane; every placed session's pane really is its ancestor.
        let inTmux = snap.sessions.filter { $0.tmux != nil }
        let current = inTmux.filter { $0.tmux!.current }
        let wrong = inTmux.filter { s in !(t.ancestors(of: s.key.pid) + [s.key.pid]).contains(s.tmux!.panePid) }
        r.add(g, "tmux", current.count <= 1 && wrong.isEmpty,
              "\(panes.count) panes, \(clients.count) clients; \(inTmux.count) sessions placed, \(inTmux.filter { $0.tmux!.visible }.count) visible, \(current.count) current; not in tmux: \(snap.sessions.filter { $0.tmux == nil }.map(\.key.pid))")

        // No process counted twice across sessions and leftovers.
        var seen: [ProcKey: String] = [:]
        var dup: [String] = []
        func claim(_ k: ProcKey, _ who: String) { if let o = seen[k] { dup.append("\(k) in \(o) and \(who)") } else { seen[k] = who } }
        for s in snap.sessions {
            claim(s.key, "session \(s.key.pid)")
            for u in s.children + s.background { for m in u.members { claim(m, "session \(s.key.pid)") } }
        }
        for l in snap.leftovers { for m in l.unit.members { claim(m, "leftover \(l.unit.pgid)") } }
        let ownedBytes = map.owner.reduce(Bytes(0)) { acc, e in
            switch e.value {
            case .session, .claudeChild, .claudeBackground, .unregisteredClaude, .leftover: acc + (t.byPid[e.key]?.footprint ?? 0)
            default: acc
            }
        }
        let shown = snap.sessionsTotal + snap.leftoversTotal
        r.add(g, "no-double-count", dup.isEmpty && shown == ownedBytes,
              dup.isEmpty ? "sessions \(ByteFormat.short(snap.sessionsTotal)) + leftovers \(ByteFormat.short(snap.leftoversTotal)) = Claude-owned pids \(ByteFormat.short(ownedBytes))"
                          : dup.prefix(5).joined(separator: "; "))

        // Timing: a warm snapshot (CPU history present, caches filled) on a fresh scan.
        let t2 = sk.scan()
        let map2 = Ownership.assign(t2, sessions: records, hosts: hs, tmuxPanes: panes, sys: sk, env: env)
        let s0 = DispatchTime.now().uptimeNanoseconds
        let snap2 = await source.snapshot(t2, map2, sk)
        let snapMs = Double(DispatchTime.now().uptimeNanoseconds - s0) / 1e6
        r.notes.append(String(format: "warm snapshot: %.1f ms for %d sessions (includes tmux list-panes + list-clients)",
                              snapMs, snap2.sessions.count))

        // Notes: the session table.
        let now = t.takenAt
        r.notes.append("sessions (total = self + children + background):")
        for s in snap.sessions {
            let whereLabel = WhereLabel.make(tmux: s.tmux, project: s.project, branch: s.branch, worktree: s.worktree)
            let age: String
            if s.busy { age = "busy " + ago(s.statusSince, now) } else { age = "idle " + ago(s.idleSince, now) }
            var flags: [String] = []
            if s.unregistered { flags.append("unregistered") }
            if s.remoteControl { flags.append("remote") }
            if s.isLauncher { flags.append("launcher") }
            if !s.hasTranscript { flags.append("no-transcript") }
            if !s.cwdExists { flags.append("cwd-missing") }
            if s.tmux == nil { flags.append("not-in-tmux") }
            if s.tmux?.current == true { flags.append("current") } else if s.tmux?.visible == true { flags.append("visible") }
            r.notes.append(String(format: "  %6d %@ %@ %@ cpu %4.1f%% %@  %@",
                                  s.key.pid, pad(String(s.title.prefix(28)), 28), pad(age, 12), pad(s.status, 5), s.cpuPercent,
                                  pad(ByteFormat.short(s.total) + (s.backgroundBytes > 0 ? " (+\(ByteFormat.short(s.backgroundBytes)) bg)" : ""), 22),
                                  whereLabel + (flags.isEmpty ? "" : "  [" + flags.joined(separator: ",") + "]")))
        }
        if !snap.leftovers.isEmpty { r.notes.append("leftovers:") }
        for l in snap.leftovers {
            r.notes.append("  \(l.id.stringValue)  \(ByteFormat.short(l.unit.footprint))  \(l.unit.members.count) procs  dead CLAUDE_PID \(l.deadClaudePid)  \(l.sessionTitle ?? "-")  \(l.unit.command.prefix(60))")
        }
        return r
    }

    static func isClaude(_ s: ProcSample, sk: LiveSysKit, env: HeadroomEnv) -> Bool {
        guard env.isClaudeBinary(path: s.path) else { return false }
        guard let a = sk.args(s.key), !a.argv0.isEmpty else { return true }
        let a0 = (a.argv0 as NSString).lastPathComponent
        return a0 == "claude" || a0 == (s.path as NSString).lastPathComponent
    }

    static func ago(_ d: Date?, _ now: Date) -> String {
        guard let d else { return "?" }
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h\(s % 3600 / 60)m" }
        return "\(s / 86_400)d"
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
}
