// HeadroomClaude tests. Nothing here touches the real ~/.claude, the user's tmux server, or any process we did not start.
import Foundation
import Testing
import HeadroomContracts
import HeadroomCore
@testable import HeadroomClaude

// MARK: - SessionStore

@Suite struct SessionStoreTests {
    @Test func lenientDecoding() throws {
        let d = ScratchDir("store")
        d.write("s/100.json", #"{"pid":"100","sessionId":"x","startedAt":"1790000000000","status":"idle","unknownKey":[1,2],"bridgeSessionId":null}"#)
        d.write("s/200.json", #"{"sessionId":"y","cwd":"/tmp","name":"","statusUpdatedAt":1790000000123}"#)   // pid from file name
        d.write("s/300.json", #"[1,2,3]"#)                    // not an object: skipped
        d.write("s/400.json", #"{"pid":400,"sessionId":"#)    // half-written: skipped
        d.write("s/500.json", #"{"pid":true,"sessionId":"z"}"#)   // a Bool is not a pid → falls back to the file name
        d.write("s/600.abc.key", "x")                        // not .json
        let recs = SessionStore(dir: d.path + "/s", watch: false).records()
        #expect(recs.map(\.pid) == [100, 200, 500])
        let r1 = try #require(recs.first)
        #expect(r1.sessionId == "x" && r1.startedAt == 1_790_000_000_000 && r1.status == "idle" && r1.bridgeSessionId == nil)
        #expect(r1.filePath == d.path + "/s/100.json")
        #expect(recs[1].name == nil && recs[1].cwd == "/tmp" && recs[1].statusUpdatedAt == 1_790_000_000_123)
    }

    @Test func reparsesChangedFilesAndSeesNewOnes() throws {
        let d = ScratchDir("store2")
        d.write("s/1.json", #"{"pid":1,"sessionId":"a","status":"idle"}"#)
        let store = SessionStore(dir: d.path + "/s", watch: true)
        #expect(store.records().map(\.status) == ["idle"])
        d.write("s/1.json", #"{"pid":1,"sessionId":"a","status":"busy","x":"longer so the size changes"}"#)
        #expect(store.records().map(\.status) == ["busy"])
        d.write("s/2.json", #"{"pid":2,"sessionId":"b"}"#)
        // The directory watcher marks the listing dirty; the 10 s rescan is the safety net.
        var seen = store.records().count
        for _ in 0..<40 where seen < 2 { usleep(25_000); seen = store.records().count }
        #expect(seen == 2)
        try FileManager.default.removeItem(atPath: d.path + "/s/1.json")
        var left = store.records().count
        for _ in 0..<40 where left > 1 { usleep(25_000); left = store.records().count }
        #expect(store.records().map(\.pid) == [2])
    }

    @Test func missingDirectoryIsEmpty() {
        #expect(SessionStore(dir: "/nonexistent/headroom/sessions").records().isEmpty)
    }
}

// MARK: - TranscriptTail

@Suite struct TranscriptTailTests {
    let sid = "11111111-2222-4333-8444-555555555555"
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func projectDirName() {
        #expect(TranscriptTail.projectDirName(cwd: "/Users/jappleseed/kb") == "-Users-jappleseed-kb")
        #expect(TranscriptTail.projectDirName(cwd: "/Users/j/work/repo/.claude/worktrees/wt_1")
                == "-Users-j-work-repo--claude-worktrees-wt-1")
        #expect(TranscriptTail.projectDirName(cwd: "/a b/é") == "-a-b--")
    }

    @Test func locateDirectThenGlobThenMissing() {
        let d = ScratchDir("tail-locate")
        let tail = TranscriptTail(projectsDir: d.path + "/projects")
        let direct = d.write("projects/-work-a/\(sid).jsonl", "\n")
        #expect(tail.locate(sessionId: sid, cwd: "/work/a") == direct)
        #expect(tail.locate(sessionId: sid, cwd: "/work/elsewhere") == direct)       // glob
        #expect(tail.locate(sessionId: "99999999-0000-4000-8000-000000000000", cwd: "/work/a") == nil)
        #expect(tail.locate(sessionId: "../../etc/passwd", cwd: nil) == nil)          // never a path
        #expect(tail.info(sessionId: "99999999-0000-4000-8000-000000000000", cwd: nil).exists == false)
    }

    @Test func takesTheLastEntriesByTheirOwnTimestamps() throws {
        let d = ScratchDir("tail")
        let lines = [
            TX.user("first prompt", at: t0, sid: sid),
            TX.aiTitle("Old title", sid: sid),
            TX.assistant("old answer", at: t0 + 10, sid: sid),
            TX.away("You were fixing X; next run the tests.", at: t0 + 20, sid: sid),
            TX.user("second prompt", at: t0 + 100, sid: sid),
            TX.aiTitle("New title", sid: sid),
            TX.assistant(String(repeating: "é", count: 400), at: t0 + 110, sid: sid),
            TX.assistant(nil, at: t0 + 120, sid: sid, toolUse: true),
            TX.toolResult(at: t0 + 121, sid: sid),
            TX.lastPrompt("second prompt", sid: sid),
            TX.attachment(at: t0 + 5000),       // not user/assistant: never activity
        ]
        let p = d.write("t.jsonl", lines.joined(separator: "\n") + "\n")
        // An mtime far in the future must not matter.
        var tv = [timeval(tv_sec: 2_000_000_000, tv_usec: 0), timeval(tv_sec: 2_000_000_000, tv_usec: 0)]
        utimes(p, &tv)
        let i = TranscriptTail.read(path: p)
        #expect(i.lastActivity == t0 + 121)
        #expect(i.aiTitle == "New title")
        #expect(i.lastPrompt == "second prompt")
        let a = try #require(i.lastAssistant)
        #expect(a.count == 300 && a.hasSuffix("…"))
        #expect(i.awaySummary == nil)       // older than the latest activity: the user came back
    }

    @Test func freshAwaySummaryIsKept() {
        let d = ScratchDir("tail-away")
        let p = d.write("t.jsonl", [
            TX.user("do it", at: t0, sid: sid), TX.assistant("done", at: t0 + 5, sid: sid),
            TX.away("You asked for X; it is done.", at: t0 + 600, sid: sid),
        ].joined(separator: "\n") + "\n")
        let i = TranscriptTail.read(path: p)
        #expect(i.awaySummary == "You asked for X; it is done.")
        #expect(i.lastPrompt == "do it")          // no last-prompt entry: the typed user text
    }

    @Test func growsTheWindowPastBulkyNonActivityLines() {
        let d = ScratchDir("tail-grow")
        var lines = [TX.aiTitle("T", sid: sid), TX.user("go", at: t0, sid: sid), TX.assistant("ok", at: t0 + 1, sid: sid)]
        for k in 0..<300 { lines.append(TX.attachment(at: t0 + Double(k), pad: 1000)) }   // ~300 KB of attachments
        let p = d.write("t.jsonl", lines.joined(separator: "\n") + "\n")
        let i = TranscriptTail.read(path: p)
        #expect(i.lastActivity == t0 + 1 && i.aiTitle == "T")
        #expect(i.bytesRead > TranscriptTail.initialWindow)
    }

    @Test func partialFirstLineIsDropped() {
        let d = ScratchDir("tail-partial")
        let big = TX.assistant(String(repeating: "x", count: 70_000), at: t0, sid: sid)   // straddles the 64 KB cut
        let p = d.write("t.jsonl", [big, TX.user("tail prompt", at: t0 + 3, sid: sid)].joined(separator: "\n") + "\n")
        let i = TranscriptTail.read(path: p)
        #expect(i.lastActivity == t0 + 3 && i.lastPrompt == "tail prompt")
    }

    @Test func rereadsOnlyWhenTheSizeChangesAndKeepsOlderValues() {
        let d = ScratchDir("tail-cache")
        let tail = TranscriptTail(projectsDir: d.path)
        let p = d.write("t.jsonl", [TX.aiTitle("Kept title", sid: sid), TX.user("a", at: t0, sid: sid)].joined(separator: "\n") + "\n")
        #expect(tail.info(path: p).aiTitle == "Kept title")
        // Same size, different content: served from the cache (no re-read).
        let same = [TX.aiTitle("Diff title", sid: sid), TX.user("a", at: t0, sid: sid)].joined(separator: "\n") + "\n"
        let fh = FileHandle(forWritingAtPath: p)!; fh.write(same.data(using: .utf8)!); try? fh.close()
        #expect(tail.info(path: p).aiTitle == "Kept title")
        // Appending 100 KB of new activity pushes the ai-title out of the 64 KB window; it is kept from before.
        var more = ""
        for k in 0..<100 { more += TX.attachment(at: t0 + Double(k)) + "\n" }
        more += TX.assistant("new", at: t0 + 500, sid: sid) + "\n"
        let fa = FileHandle(forWritingAtPath: p)!; fa.seekToEndOfFile(); fa.write(more.data(using: .utf8)!); try? fa.close()
        let i = tail.info(path: p)
        #expect(i.lastActivity == t0 + 500 && i.lastAssistant == "new")
        #expect(i.aiTitle == "Diff title" || i.aiTitle == "Kept title")
    }

    @Test func isoTimestamps() {
        #expect(ISOTimestamp.parse("2026-09-30T17:36:39.480Z")?.timeIntervalSince1970 == 1_790_789_799.48)
        #expect(ISOTimestamp.parse("2026-09-30T17:36:39Z")?.timeIntervalSince1970 == 1_790_789_799)
        #expect(ISOTimestamp.parse("2026-09-30T18:36:39+01:00")?.timeIntervalSince1970 == 1_790_789_799)
        #expect(ISOTimestamp.parse("garbage") == nil)
    }

    /// 22 tails of 3 MB transcripts, cold. The live budget (§11) is 20 ms; debug builds get 3× slack here.
    @Test func tailBudget() {
        let d = ScratchDir("tail-budget")
        var chunk = ""
        for k in 0..<400 {
            chunk += TX.assistant(String(repeating: "w", count: 3000), at: t0 + Double(k), sid: sid, toolUse: true) + "\n"
            chunk += TX.toolResult(at: t0 + Double(k), sid: sid) + "\n"
            if k % 50 == 0 { chunk += TX.aiTitle("Title \(k)", sid: sid) + "\n" + TX.lastPrompt("p\(k)", sid: sid) + "\n" }
        }
        var paths: [String] = []
        for n in 0..<22 { paths.append(d.write("p/\(n).jsonl", chunk)) }
        let tail = TranscriptTail(projectsDir: d.path)
        let s = DispatchTime.now().uptimeNanoseconds
        let infos = paths.map { tail.info(path: $0) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6
        #expect(infos.allSatisfy { $0.lastActivity != nil && $0.aiTitle != nil })
        #if DEBUG
        let budget = 60.0
        #else
        let budget = 20.0
        #endif
        print("tailBudget: 22 × \(chunk.utf8.count / 1024) KB transcripts in \(String(format: "%.2f", ms)) ms")
        #expect(ms < budget)
    }
}

// MARK: - Title and where

@Suite struct TitleTests {
    @Test func rules() {
        // 1. name when the user set it
        #expect(SessionTitle.choose(name: "ram", nameSource: "user", aiTitle: "AI", paneTitle: "✳ Pane", project: "p") == "ram")
        // 2. ai-title beats a derived name and the pane
        #expect(SessionTitle.choose(name: "hammer-47", nameSource: "derived", aiTitle: "Fix bug", paneTitle: "✳ Pane", project: "p") == "Fix bug")
        // 3. pane title without the status glyph
        #expect(SessionTitle.choose(name: "hammer-47", nameSource: "derived", aiTitle: nil, paneTitle: "✳ Pane Title", project: "p") == "Pane Title")
        #expect(SessionTitle.choose(name: nil, nameSource: nil, aiTitle: nil, paneTitle: "⠂ Spinning", project: "p") == "Spinning")
        // 4. derived name
        #expect(SessionTitle.choose(name: "hammer-47", nameSource: "derived", aiTitle: nil, paneTitle: "✳ ", project: "p") == "hammer-47")
        // 5. custom-title, then project
        #expect(SessionTitle.choose(name: nil, nameSource: nil, customTitle: "renamed", aiTitle: nil, paneTitle: nil, project: "p") == "renamed")
        #expect(SessionTitle.choose(name: nil, nameSource: nil, aiTitle: " ", paneTitle: nil, project: "proj") == "proj")
        // tmux's default pane title (the host name) is not a title
        #expect(SessionTitle.cleanPaneTitle("Johns-MBP.local", hostName: "Johns-MBP.local") == nil)
        #expect(SessionTitle.cleanPaneTitle("Johns-MBP", hostName: "Johns-MBP.local") == nil)
    }

    @Test func whereLabel() {
        let loc = TmuxLoc(paneId: "%1", session: "hub", windowName: "w", windowIndex: 3, paneIndex: 1)
        #expect(WhereLabel.make(tmux: loc, project: "compass", branch: "main", worktree: nil) == "hub:3.1 › compass ⎇ main")
        #expect(WhereLabel.make(tmux: nil, project: "compass", branch: "b", worktree: "bubbly") == "compass ⎇ bubbly")
        #expect(WhereCache.project(cwd: "/x/compass/.claude/worktrees/bubbly", head: nil) == "compass")
        // Rex: "rex <session>:<tab>.<pane>"; "?" when the block's place is unknown.
        let r = RexLoc(blockId: "block:x", sessionId: "session:0190-abcdef", sessionLabel: "foundry", windowId: "window:w",
                       windowLabel: "api reference", windowIndex: 2, paneIndex: 1, visible: true)
        #expect(WhereLabel.make(tmux: nil, rex: r, project: "compass", branch: "main", worktree: nil)
                == "rex foundry:2.1 › compass ⎇ main")
        let unplaced = RexLoc(blockId: "block:x", sessionId: "session:0190-abcdef", sessionLabel: "", visible: true)
        #expect(WhereLabel.make(tmux: nil, rex: unplaced, project: "compass", branch: nil, worktree: nil)
                == "rex …abcdef:? › compass")
    }
}

// MARK: - Busy

@Suite struct BusyTests {
    let k = ProcKey(pid: 10, startSec: 1000)
    let now = Date(timeIntervalSince1970: 2000)

    func table(_ cpuNs: UInt64, childCpu: UInt64? = nil, at: Date) -> ProcessTable {
        var s = [ProcSample(key: k, ppid: 1, pgid: 10, path: "/c/claude/versions/1", footprint: 1, rss: 1, cpuNs: cpuNs)]
        if let c = childCpu { s.append(ProcSample(key: ProcKey(pid: 11, startSec: 1500), ppid: 10, pgid: 10, path: "/bin/zsh", footprint: 1, rss: 1, cpuNs: c)) }
        return ProcessTable(samples: s, takenAt: at)
    }

    @Test func statusEvidence() {
        let b = BusyTracker()
        func ev(_ s: String?, registered: Bool = true) -> BusyEvidence {
            b.evaluate(key: k, status: s, registered: registered, statusUpdatedAt: now - 60, lastActivity: nil,
                       cpuPercent: nil, childPaths: [], childStarts: [], now: now).evidence
        }
        #expect(!ev("idle").busy)
        #expect(ev("busy").status && ev("waiting").status && ev(nil).status)      // unknown counts as busy
        #expect(!ev(nil, registered: false).busy)       // unregistered: other evidence only
    }

    @Test func otherEvidence() {
        let b = BusyTracker()
        let su = now - 600
        func ev(la: Date? = nil, cpu: Double? = nil, paths: [String] = [], starts: [Int] = []) -> BusyEvidence {
            b.evaluate(key: k, status: "idle", registered: true, statusUpdatedAt: su, lastActivity: la,
                       cpuPercent: cpu, childPaths: paths, childStarts: starts, now: now).evidence
        }
        #expect(ev(paths: ["/usr/bin/caffeinate"]).caffeinate)
        #expect(ev(cpu: 5.1).cpu && !ev(cpu: 4.9).busy)
        #expect(ev(la: now - 10).transcript)                 // entry written after the status went idle, recently
        #expect(!ev(la: su + 1).busy)                        // the turn's last entry itself
        #expect(!ev(la: now - 40).busy)                      // too old
        #expect(ev(starts: [Int(now.timeIntervalSince1970) - 5]).child)
        #expect(!ev(starts: [Int(now.timeIntervalSince1970) - 60]).busy)
    }

    @Test func busySince() {
        let b = BusyTracker()
        let r1 = b.evaluate(key: k, status: "busy", registered: true, statusUpdatedAt: now - 300, lastActivity: nil,
                            cpuPercent: nil, childPaths: [], childStarts: [], now: now)
        #expect(r1.since == now - 300)
        // JSON says idle but CPU says busy: age from the first busy observation.
        let r2 = b.evaluate(key: k, status: "idle", registered: true, statusUpdatedAt: now - 300, lastActivity: nil,
                            cpuPercent: 50, childPaths: [], childStarts: [], now: now)
        let r3 = b.evaluate(key: k, status: "idle", registered: true, statusUpdatedAt: now - 300, lastActivity: nil,
                            cpuPercent: 50, childPaths: [], childStarts: [], now: now + 30)
        #expect(r2.since == now && r3.since == now)
        let r4 = b.evaluate(key: k, status: "idle", registered: true, statusUpdatedAt: now - 300, lastActivity: nil,
                            cpuPercent: 0, childPaths: [], childStarts: [], now: now + 60)
        #expect(!r4.evidence.busy && r4.since == now - 300)
    }

    @Test func cpuAveragesOverTheLastThreeSamples() throws {
        let b = BusyTracker()
        let members = [k, ProcKey(pid: 11, startSec: 1500)]
        #expect(b.cpuPercent(members: members, in: table(0, at: now)) == nil)
        b.record(table(0, childCpu: 0, at: now), keys: members)
        b.record(table(1_000_000_000, childCpu: 0, at: now + 2), keys: members)
        // 3rd sample: claude used 1 s + child 1 s over 4 s since the oldest kept sample → 50%.
        let pct = try #require(b.cpuPercent(members: members, in: table(1_000_000_000, childCpu: 1_000_000_000, at: now + 4)))
        #expect(abs(pct - 50) < 0.01)
        b.record(table(1_000_000_000, childCpu: 1_000_000_000, at: now + 4), keys: members)
        // Next window (now+2 → now+6): only the child's second → 25%.
        let p2 = try #require(b.cpuPercent(members: members, in: table(1_000_000_000, childCpu: 1_000_000_000, at: now + 6)))
        #expect(abs(p2 - 25) < 0.01)
    }
}

// MARK: - ClaudeSource over a scratch ~/.claude (the §11 fixture)

@Suite struct ClaudeFixtureTests {
    @Test func snapshotCoversTitleRulesTranscriptsCwdAndTmux() async throws {
        let w = ClaudeWorld()
        let map = w.assign()
        #expect(map.liveSessions.map(\.pid) == [301, 302, 303, 304])
        #expect(map.staleSessionFiles.map { ($0 as NSString).lastPathComponent } == ["998.json"])
        let snap = await w.source().snapshot(w.table, map, w.sys)
        func s(_ pid: Int32) throws -> ClaudeSession { try #require(snap.sessions.first { $0.key.pid == pid }) }

        // A: user name; transcript; repo branch; remote control; background bun dev; visible + current.
        let a = try s(301)
        #expect(a.title == "handoff design" && a.sessionId == ClaudeWorld.sidA && a.project == "repo")
        #expect(a.branch == "feature-x" && a.worktree == nil && a.cwdExists && a.hasTranscript)
        #expect(a.remoteControl && !a.busy && a.status == "idle")
        #expect(a.lastActivity == ClaudeWorld.now - 8000 && a.lastPrompt == "start the handoff doc")
        #expect(a.lastAssistant == "Drafted the handoff doc.")
        #expect(a.idleSince == ClaudeWorld.now - 7200)
        #expect(a.tmux?.label == "hub:1.0" && a.tmux?.visible == true && a.tmux?.current == true)
        #expect(a.children.map(\.command) == ["node mcp-server.js"])
        #expect(a.background.count == 1 && a.background[0].members.map(\.pid) == [501, 502])
        #expect(a.background[0].command == "bun run dev --port 3217" && a.backgroundBytes == 800 << 20)
        #expect(a.total == (300 + 40 + 800) << 20)

        // B: derived name → ai-title; worktree + branch; busy (status + caffeinate); launcher; not visible.
        let b = try s(302)
        #expect(b.title == "Fix login bug" && b.project == "repo" && b.worktree == "wt1" && b.branch == "wt1-branch")
        #expect(b.busy && b.statusSince == ClaudeWorld.now - 90 && b.isLauncher)
        #expect(b.lastActivity == ClaudeWorld.now - 95 && b.lastAssistant == nil && b.lastPrompt == "fix the login bug")
        #expect(b.tmux?.visible == false && b.tmux?.current == false)

        // C: no transcript → pane title without ✳.
        let c = try s(303)
        #expect(c.title == "Pane Title Here" && !c.hasTranscript && c.lastActivity == nil && c.tmux?.session == "misc")

        // D: missing cwd, not in tmux, no name, no transcript → project name.
        let d = try s(304)
        #expect(!d.cwdExists && d.tmux == nil && !d.hasTranscript && d.title == "gone" && d.branch == nil)

        // E: unregistered claude, session id from `--resume`, transcript found by glob.
        let e = try s(305)
        #expect(e.unregistered && e.sessionId == ClaudeWorld.sidE && e.hasTranscript && e.title == "Resumed investigation")
        #expect(e.cwd == w.plain && e.status == "unknown" && !e.busy && e.version == "2.1.284")

        // Stale file and leftovers.
        #expect(snap.staleFiles.count == 1)
        #expect(snap.leftovers.map(\.unit.pgid) == [610, 620])
        let l1 = snap.leftovers[0]
        #expect(l1.id == .leftover(pgid: 610, leaderStartSec: ClaudeWorld.base - 40_000))
        #expect(l1.deadClaudePid == 999 && l1.sessionId == ClaudeWorld.sidDead1 && l1.sessionTitle == "tour landing")
        #expect(l1.unit.members.map(\.pid) == [610, 611] && l1.unit.footprint == 1000 << 20 && l1.cwd == w.dir.path + "/work/harbour-tours")
        let l2 = snap.leftovers[1]
        #expect(l2.sessionTitle == "Old dashboard work" && l2.cwd == w.plain)   // cwd from the dead session's JSON

        // No double counting: the section equals the Claude-owned pids.
        let owned = map.owner.reduce(Bytes(0)) { acc, e in
            switch e.value {
            case .session, .claudeChild, .claudeBackground, .unregisteredClaude, .leftover: acc + w.table.byPid[e.key]!.footprint
            default: acc
            }
        }
        #expect(snap.sessionsTotal + snap.leftoversTotal == owned)
        // Sorted by total, largest first.
        #expect(snap.sessions.map(\.total) == snap.sessions.map(\.total).sorted(by: >))
    }

    @Test func cpuSecondSampleMakesAnIdleJSONSessionBusy() async throws {
        let w = ClaudeWorld()
        let map = w.assign()
        let src = w.source()
        _ = await src.snapshot(w.table, map, w.sys)
        // Next tick: claude 303 burned 1.5 s of CPU in 2 s → busy although its JSON says idle.
        let later = ProcessTable(samples: w.table.byPid.values.map { s in
            s.pid == 303 ? ProcSample(key: s.key, ppid: s.ppid, pgid: s.pgid, path: s.path, footprint: s.footprint,
                                      rss: s.rss, cpuNs: s.cpuNs + 1_500_000_000) : s
        }, takenAt: w.table.takenAt + 2)
        let snap = await src.snapshot(later, map, w.sys)
        let c = try #require(snap.sessions.first { $0.key.pid == 303 })
        #expect(c.busy && c.cpuPercent > 70 && c.status == "idle")
    }

    @Test func ps_fixture_replay() async throws {
        // Replays the captured ps/psargs + overlay: 20 live sessions, the two §3 leftovers, agent-browser as
        // 80876's background.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let f = try OwnershipFixture.load(ps: dir.appendingPathComponent("ps.txt"),
                                          psargs: dir.appendingPathComponent("psargs.txt"),
                                          overlay: dir.appendingPathComponent("ownership-overlay.json"))
        let map = f.assign()
        let scratch = ScratchDir("psfix")
        var env = f.env
        env.claudeDir = scratch.path + "/.claude"
        env.supportDir = scratch.path + "/support"
        env.tmuxPath = "/nonexistent/tmux"
        env.rexPath = "/nonexistent/rex"
        let src = ClaudeSource(env: env, desktop: RecordingDesktop(), watch: false)
        src.cpuSettle = 0
        let panes = f.tmuxPanes
        src.tmuxData = { (panes, []) }
        let snap = await src.snapshot(f.table, map, f.sys)
        #expect(snap.sessions.filter { !$0.unregistered }.count == 20)
        let lefts = Dictionary(uniqueKeysWithValues: snap.leftovers.map { ($0.unit.pgid, $0) })
        #expect(Set(lefts.keys) == [7164, 40363])
        #expect(lefts[7164]?.unit.members.count == 8 && lefts[40363]?.unit.members.count == 3)
        #expect(lefts[7164]?.unit.command.contains("bun") == true)
        let s80876 = try #require(snap.sessions.first { $0.key.pid == 80876 })
        #expect(s80876.background.contains { $0.isAutomationBrowser })
        #expect(!snap.sessions.contains { s in s.children.contains { $0.isAutomationBrowser } })
        // Every session placed in tmux sits under its pane's shell.
        for s in snap.sessions { if let t = s.tmux { #expect(f.table.ancestors(of: s.key.pid).contains(t.panePid)) } }
        #expect(snap.staleFiles.count == 2)
    }
}

// MARK: - Jump and reopen against a private tmux server (never the user's)

@Suite(.serialized) struct ClaudeTmuxTests {
    static let socket = "headroom-test-wp2"
    static let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Runs tmux on the private socket only, with no config file (so the user's ~/.tmux.conf is never loaded).
    @discardableResult
    static func tmux(_ args: [String]) async -> Shell.Result {
        precondition(!socket.isEmpty)
        var e = ProcessInfo.processInfo.environment; e["TMUX"] = nil; e["TMUX_PANE"] = nil
        return await Shell.run(tmuxPath!, ["-L", socket, "-f", "/dev/null"] + args, timeout: 5, environment: e)
    }

    /// Synchronous kill-server on the private socket (a Task in `defer` would not finish before exit).
    static func killPrivateServer() {
        precondition(socket == "headroom-test-wp2")
        var e = ProcessInfo.processInfo.environment; e["TMUX"] = nil; e["TMUX_PANE"] = nil
        _ = Shell.runSync(tmuxPath!, ["-L", socket, "-f", "/dev/null", "kill-server"], timeout: 5, environment: e)
    }

    func env(_ d: ScratchDir, dryRun: Bool) -> HeadroomEnv {
        var e: [String: String] = ["HOME": d.path, "HEADROOM_CLAUDE_DIR": d.path + "/.claude", "HEADROOM_TMUX": Self.tmuxPath!,
                                   "HEADROOM_TMUX_SOCKET": Self.socket, "HEADROOM_SUPPORT_DIR": d.path + "/support",
                                   "HEADROOM_REX": "/nonexistent/rex"]
        if dryRun { e["HEADROOM_DRY_RUN"] = "1" }
        return HeadroomEnv(environment: e)
    }

    func record(_ cwd: String, session: String?) -> ClosedRecord {
        ClosedRecord(batchId: "b", kind: "session", itemId: "session:1:1", closedAt: Date(), title: "my \"quoted\" title",
                     bytes: 1, sessionId: "abcdef01-0000-4000-8000-000000000001", cwd: cwd, tmuxSession: session)
    }

    @Test(.enabled(if: tmuxPath != nil)) func reopenAndJump() async throws {
        let d = ScratchDir("tmux")
        d.mkdir("proj")
        Self.killPrivateServer()       // leftovers from an aborted run, private socket only
        // `cat` as the default command: the typed `claude --resume …` is echoed, never executed.
        #expect(await Self.tmux(["new-session", "-d", "-s", "base", "-c", d.path, "cat"]).ok)
        #expect(await Self.tmux(["set-option", "-g", "default-command", "cat"]).ok)
        defer { Self.killPrivateServer() }

        let desk = RecordingDesktop()
        // Dry run: nothing happens.
        let dry = ClaudeSource(env: env(d, dryRun: true), desktop: desk, watch: false)
        let r0 = record(d.path + "/proj", session: "work")
        #expect(await dry.reopen([r0])[r0] == .dryRun)
        #expect(await Self.tmux(["has-session", "-t", "=work"]).ok == false)

        let src = ClaudeSource(env: env(d, dryRun: false), desktop: desk, watch: false)
        // Session "base" exists: a new window there, the resume command typed into it.
        let r1 = record(d.path + "/proj", session: "base")
        #expect(await src.reopen([r1])[r1] == .done)
        let panes = TmuxClient.parsePanes(await Self.tmux(["list-panes", "-a", "-F", TmuxClient.paneFormat]).stdout)
        let newPane = try #require(panes.first { $0.session == "base" && $0.windowIndex != 0 })
        try await Task.sleep(nanoseconds: 300_000_000)
        let screen = await Self.tmux(["capture-pane", "-p", "-t", newPane.paneId]).stdout
        #expect(screen.contains("claude --resume abcdef01-0000-4000-8000-000000000001"))
        #expect(newPane.windowName == "my \"quoted\" title")
        #expect(desk.calls.isEmpty)       // the session existed: no jump

        // Session gone: created, then (no client attached) the attach command goes to the clipboard stand-in.
        let r2 = record(d.path + "/proj", session: "gone sess")
        #expect(await src.reopen([r2])[r2] == .done)
        #expect(await Self.tmux(["has-session", "-t", "=gone sess"]).ok)
        #expect(desk.calls.last == "noClient:tmux attach -t 'gone sess'")

        // Refusals.
        let bad = record(d.path + "/missing", session: "base")
        if case .failed = await src.reopen([bad])[bad] {} else { Issue.record("missing cwd must fail") }
        let tab = ClosedRecord(batchId: "b", kind: "tab", itemId: "tab:1:1", closedAt: Date(), title: "t", bytes: 0)
        if case .failed = await src.reopen([tab])[tab] {} else { Issue.record("a tab record is not a session") }
        var evil = record(d.path + "/proj", session: "base"); evil.sessionId = "x; rm -rf ~"
        if case .failed = await src.reopen([evil])[evil] {} else { Issue.record("unsafe session id must be refused") }

        // Jump to a session whose claude is not in tmux (ProcKey not alive) → only focuses the terminal app.
        await src.jump(ProcKey(pid: 999_999, startSec: 1))
        #expect(desk.calls.last == "focus:")
    }

    struct ClientDidNotAttach: Error { let session: String }

    static func listClients() async -> [TmuxClientInfo] {
        TmuxClient.parseClients(await tmux(["list-clients", "-F", TmuxClient.clientFormat]).stdout)
    }

    /// Attaches a real tmux client to `session` on the private server through a pty (`script`) and waits for it.
    /// Returns the process (terminate it when done) and the client's tty.
    static func attachClient(to session: String) async throws -> (Process, String) {
        let before = Set(await listClients().map(\.tty))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", tmuxPath!, "-L", socket, "-f", "/dev/null", "attach", "-t", session]
        var e = ProcessInfo.processInfo.environment; e["TMUX"] = nil; e["TMUX_PANE"] = nil; e["TERM"] = "xterm-256color"
        p.environment = e
        p.standardInput = Pipe(); p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let c = await listClients().first(where: { !before.contains($0.tty) && $0.session == session }) {
                return (p, c.tty)
            }
        }
        p.terminate()
        throw ClientDidNotAttach(session: session)
    }

    /// tty → session of every attached client.
    static func clientSessions() async -> [String: String] {
        Dictionary(await listClients().map { ($0.tty, $0.session) }, uniquingKeysWith: { a, _ in a })
    }

    /// Jump resolves the pane live from the ppid chain (no prior snapshot). Then: with no client, the attach command
    /// and a note; with one client elsewhere, that client is switched and the terminal on ITS tty is focused; with a
    /// client already on the session, that one is used and the others stay where they are; and when the terminal
    /// could not be focused exactly, a note says why. The clients are pty clients started by `script`.
    @Test(.enabled(if: tmuxPath != nil)) func jumpSwitchesAClientAndFocusesItsTty() async throws {
        let d = ScratchDir("tmux-jump")
        Self.killPrivateServer()
        #expect(await Self.tmux(["new-session", "-d", "-s", "base", "-c", d.path, "cat"]).ok)
        #expect(await Self.tmux(["new-session", "-d", "-s", "target", "-n", "tw", "-c", d.path, "sleep 60"]).ok)
        #expect(await Self.tmux(["new-window", "-d", "-t", "=target:", "-n", "tw2", "-c", d.path, "sleep 61"]).ok)
        var started: [Process] = []
        defer {
            for c in started where c.isRunning { c.terminate() }   // our own `script` children only
            Self.killPrivateServer()
        }
        let panes = TmuxClient.parsePanes(await Self.tmux(["list-panes", "-a", "-F", TmuxClient.paneFormat]).stdout)
        let first = try #require(panes.first { $0.session == "target" && $0.windowName == "tw" })
        let second = try #require(panes.first { $0.session == "target" && $0.windowName == "tw2" })
        // Each "claude" is a pane's own process (sleep, started by our private server).
        func key(_ p: TmuxPane) throws -> ProcKey {
            ProcKey(pid: p.panePid, startSec: Int(try #require(LiveSysKit.bsdInfo(p.panePid)).pbi_start_tvsec))
        }
        let k1 = try key(first), k2 = try key(second)

        let desk = RecordingDesktop()
        let src = ClaudeSource(env: env(d, dryRun: true), desktop: desk, watch: false)

        // 1. Nothing is attached: the attach command is copied, and the note says so.
        let none = await src.jumpNote(k1)
        #expect(desk.calls == ["noClient:tmux attach -t target"])
        #expect(none == "No terminal is attached to tmux. Copied “tmux attach -t target”: paste it in Ghostty.")

        // 2. One client, on "base": it is switched to "target", and the terminal on ITS tty is focused. No note.
        let (c1, tty1) = try await Self.attachClient(to: "base"); started.append(c1)
        #expect(await src.jumpNote(k1) == nil)
        #expect(await Self.clientSessions() == [tty1: "target"])
        #expect(desk.calls.last == "focus:\(tty1)")

        // 3. A second client, on "base". Jumping to the other window of "target" uses the client that already shows
        //    "target" (the one on "base" stays there), selects that window, and focuses that client's tty.
        let (c2, tty2) = try await Self.attachClient(to: "base"); started.append(c2)
        #expect(tty2 != tty1)
        #expect(await src.jumpNote(k2) == nil)
        #expect(await Self.clientSessions() == [tty1: "target", tty2: "base"])
        #expect(desk.calls.last == "focus:\(tty1)")
        let active = await Self.tmux(["display-message", "-p", "-t", "=target:", "#{window_name} #{pane_id}"]).stdout
        #expect(active.trimmingCharacters(in: .whitespacesAndNewlines) == "tw2 \(second.paneId)")

        // 4. tmux switched, but the terminal could not be focused exactly: the note says what happened.
        desk.focusResult = .notAllowed
        let denied = try #require(await src.jumpNote(k1))
        #expect(denied.hasPrefix("tmux switched to “target”, but Ghostty may show another window."))
        #expect(denied.contains("System Settings ▸ Privacy & Security ▸ Automation"))
        desk.focusResult = .notFound
        let elsewhere = try #require(await src.jumpNote(k2))
        #expect(elsewhere.contains("its terminal (\(tty1)) is not a Ghostty window"))
        desk.focusResult = .failed("Ghostty did not answer")
        #expect(await src.jumpNote(k1)?.hasSuffix("(Ghostty did not answer).") == true)
        #expect(desk.calls.suffix(3) == ["focus:\(tty1)", "focus:\(tty1)", "focus:\(tty1)"])
    }

    @Test func focusNotes() {
        #expect(ClaudeSource.tmuxFocusNote(.exact, session: "s", tty: "/dev/ttys001") == nil)
        #expect(ClaudeSource.tmuxFocusNote(.appOnly, session: "s", tty: "/dev/ttys001") == nil)
        for f in [TerminalFocus.notAllowed, .notFound, .failed("x")] {
            #expect(ClaudeSource.tmuxFocusNote(f, session: "my sess", tty: "/dev/ttys001")?
                .hasPrefix("tmux switched to “my sess”, but ") == true)
        }
    }

    @Test func ghosttyFocusScriptAndOutcome() {
        #expect(GhosttyDesktop.focusScript(tty: "/dev/ttys028")
            == #"tell application id "com.mitchellh.ghostty" to focus (first terminal whose tty is "/dev/ttys028")"#)
        // A tty is never trusted as script text.
        #expect(GhosttyDesktop.focusScript(tty: #"x" & (do shell script "id") & "\"#).hasSuffix(
            #"whose tty is "x\" & (do shell script \"id\") & \"\\")"#))

        #expect(GhosttyDesktop.focusOutcome(ok: true, stderr: "", timedOut: false) == .exact)
        // What Ghostty 1.4.0 answers when no terminal has that tty (captured).
        let missing = "51:53: execution error: Ghostty got an error: Can’t get terminal 1 whose tty = \"/dev/ttys999\". "
            + "Invalid index. (-1719)\n"
        #expect(GhosttyDesktop.focusOutcome(ok: false, stderr: missing, timedOut: false) == .notFound)
        let refused = "40:45: execution error: Not authorized to send Apple events to Ghostty. (-1743)\n"
        #expect(GhosttyDesktop.focusOutcome(ok: false, stderr: refused, timedOut: false) == .notAllowed)
        #expect(GhosttyDesktop.focusOutcome(ok: false, stderr: "", timedOut: true) == .failed("Ghostty did not answer"))
        let other = "0:5: execution error: Ghostty got an error: AppleScript is disabled. (-10000)\n"
        #expect(GhosttyDesktop.focusOutcome(ok: false, stderr: other, timedOut: false)
            == .failed("Ghostty got an error: AppleScript is disabled. (-10000)"))
        #expect(GhosttyDesktop.focusOutcome(ok: false, stderr: "", timedOut: false) == .failed("osascript failed"))

        #expect(GhosttyDesktop.Automation(status: 0) == .granted)
        #expect(GhosttyDesktop.Automation(status: -1743) == .denied)
        #expect(GhosttyDesktop.Automation(status: -1744) == .notDetermined)
        #expect(GhosttyDesktop.Automation(status: -600) == .notRunning)
        #expect(GhosttyDesktop.Automation(status: -50) == .other(-50))
    }
}

// MARK: - Live, and it changes what is on screen (opt-in, by hand):
//   HEADROOM_LIVE_FOCUS_TTY=/dev/ttysNNN swift test --filter HeadroomClaudeTests.LiveGhosttyFocus
// Runs the real GhosttyDesktop against the running Ghostty: focuses the terminal on that tty, checks that its window is
// now Ghostty's front window, then focuses the window that was in front before. It never asks for Automation
// (mayAsk is false): without the permission the test fails with `.notAllowed`.

@Suite struct LiveGhosttyFocus {
    static let tty = ProcessInfo.processInfo.environment["HEADROOM_LIVE_FOCUS_TTY"]

    static func frontTtys() async -> [String] {
        let script = "tell application id \"\(GhosttyDesktop.bundleId)\" to get tty of terminals of front window"
        let r = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 5)
        return r.stdout.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The frontmost app, as LaunchServices names it.
    static func frontApp() async -> String {
        let r = await Shell.run("/bin/sh", ["-c", "lsappinfo info -only name \"$(lsappinfo front)\""], timeout: 5)
        return r.stdout.split(separator: "\"").first.map(String.init) ?? "?"      // "Ghostty" ASN:… → Ghostty
    }

    @Test(.enabled(if: tty != nil)) func focusesTheTerminalOnATty() async throws {
        let tty = try #require(Self.tty)
        let before = await Self.frontTtys(), appBefore = await Self.frontApp()
        let desk = GhosttyDesktop()
        let outcome = await desk.focusTerminal(tty: tty)
        let during = await Self.frontTtys(), appDuring = await Self.frontApp()
        if let back = before.first, !before.contains(tty) { _ = await desk.focusTerminal(tty: back) }   // put it back
        let after = await Self.frontTtys()
        print("LiveGhosttyFocus: permission \(await GhosttyDesktop.automation(ask: false)), outcome \(outcome), "
            + "front window before \(before), during \(during), after \(after); "
            + "front app before \(appBefore), during \(appDuring)")
        #expect(outcome == .exact)
        #expect(during.contains(tty))
        #expect(appDuring == "Ghostty")          // also when another app was in front before
        #expect(after == before)
        #expect(await desk.focusTerminal(tty: "/dev/ttys999-headroom-none") == .notFound)
    }
}

// MARK: - Live, read-only (opt-in): HEADROOM_LIVE_SELFTEST=1 swift test --filter HeadroomClaudeTests.LiveSelfTest

@Suite struct LiveSelfTest {
    static let enabled = ProcessInfo.processInfo.environment["HEADROOM_LIVE_SELFTEST"] == "1"

    @Test(.enabled(if: enabled)) func selftestClaude() async {
        var e = ProcessInfo.processInfo.environment
        e["HEADROOM_DRY_RUN"] = "1"
        let r = await ClaudeSelfTest.run(env: HeadroomEnv(environment: e))
        print(r.render())
        #expect(r.passed)
    }
}
