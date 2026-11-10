// The §7.4 close sequence against real dummy processes this test spawns itself:
//   a fake claude (a copy of /bin/sleep at <scratch>/claude/versions/9.9.9) that leaves a background
//   process group (two copies of sleep named fake-dev-server), plus a leftover group, plus a fake claude that
//   ignores SIGTERM (needs Force Quit). Only these dummies are ever signalled; they are orphaned to launchd
//   with their own process groups (sh `set -m`), exactly like real leftovers.
import Darwin
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomActions

/// Minimal libproc SysKit for tests (independent of LiveSysKit).
final class TestSysKit: SysKit, @unchecked Sendable {
    func scan() -> ProcessTable {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [ProcSample] = []
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            guard let s = Self.sample(pid) else { continue }
            out.append(s)
        }
        return ProcessTable(samples: out)
    }
    static func sample(_ pid: pid_t) -> ProcSample? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { return nil }
        if info.pbi_status == 5 /* SZOMB */ { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        let path = len > 0 ? String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        return ProcSample(key: ProcKey(pid: pid, startSec: Int(info.pbi_start_tvsec)), ppid: Int32(info.pbi_ppid),
                          pgid: Int32(info.pbi_pgid), uid: info.pbi_uid, path: path, footprint: 0, rss: 0)
    }
    func args(_ k: ProcKey) -> ProcArgs? { nil }
    func cwd(_ pid: Int32) -> String? { nil }
    func systemMemory() -> SystemMemory { .zero }
    func isAlive(_ k: ProcKey) -> Bool { Self.sample(k.pid)?.key == k }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ActionEvent] = []
    func add(_ e: ActionEvent) { lock.withLock { _events.append(e) } }
    var events: [ActionEvent] { lock.withLock { _events } }
    var outcomes: [ItemID: Outcome] {
        var o: [ItemID: Outcome] = [:]
        for e in events { if case let .progress(i, out) = e { o[i] = out } }
        return o
    }
    var needsForce: [ItemID] { events.flatMap { e -> [ItemID] in if case .needsForce(let ids) = e { ids } else { [] } } }
}

/// Spawns and tracks dummies; kills whatever is left at the end (only its own pids, matched by start time).
final class Dummies: @unchecked Sendable {
    let dir: String
    let claude: String
    let dev: String
    private var spawned: [ProcKey] = []

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hr-wp4-\(UUID().uuidString.prefix(8))").path
        claude = dir + "/claude/versions/9.9.9"
        dev = dir + "/bin/fake-dev-server"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/claude/versions", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir + "/support", withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/bin/sleep", toPath: claude)
        try fm.copyItem(atPath: "/bin/sleep", toPath: dev)
        // A copied platform binary is killed on exec unless it is re-signed (ad-hoc; no keychain involved).
        for path in [claude, dev] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["--force", "--sign", "-", path]
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
    }

    /// Runs `script` under `sh -c 'set -m; …'`, reads the pid it echoes. The job is orphaned with its own pgid.
    func spawn(_ script: String) throws -> ProcKey {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "set -m; \(script) </dev/null >/dev/null 2>&1 & echo $!"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(s))
        var key: ProcKey?
        for _ in 0..<50 {
            if let smp = TestSysKit.sample(pid), smp.ppid == 1 { key = smp.key; break }
            usleep(20_000)
        }
        let k = try #require(key)
        spawned.append(k)
        return k
    }

    func groupMembers(_ pgid: Int32) -> [ProcKey] {
        let t = TestSysKit().scan()
        let m = t.byPid.values.filter { $0.pgid == pgid }.map(\.key).sorted()
        spawned.append(contentsOf: m)
        return m
    }

    func waitForMembers(_ pgid: Int32, count: Int) -> [ProcKey] {
        for _ in 0..<100 {
            let m = groupMembers(pgid)
            if m.count >= count { return m }
            usleep(20_000)
        }
        return groupMembers(pgid)
    }

    func cleanup() {
        for k in Set(spawned) where TestSysKit().isAlive(k) { kill(k.pid, SIGKILL) }
        try? FileManager.default.removeItem(atPath: dir)
    }

    func env(dryRun: Bool) -> HeadroomEnv {
        var e = HeadroomEnv(environment: ["HOME": dir, "HEADROOM_SUPPORT_DIR": dir + "/support",
                                          "HEADROOM_CLAUDE_DIR": dir + "/dot-claude",
                                          "HEADROOM_CLAUDE_VERSIONS_GLOB": dir + "/claude/versions/*"])
        e.dryRun = dryRun
        return e
    }
}

private func makeWorld(session s: ProcKey, background bg: [ProcKey], leftover lo: [ProcKey], cwd: String,
                       extraSessions: [ProcKey] = []) -> WorldSnapshot {
    func session(_ k: ProcKey, _ title: String, bg: [LinkedUnit]) -> ClaudeSession {
        ClaudeSession(key: k, sessionId: "5e55\(k.pid)-0000-4000-8000-000000000000", cwd: cwd, title: title,
                      project: "dummy", startedAt: Date(timeIntervalSince1970: TimeInterval(k.startSec)),
                      tmux: TmuxLoc(paneId: "%999", session: "headroom-test", windowName: title, windowIndex: 1, paneIndex: 0),
                      selfFootprint: .mb(10), background: bg)
    }
    let unit = LinkedUnit(root: bg[0], pgid: bg[0].pid, command: "fake-dev-server 60", argv: ["fake-dev-server", "60"],
                          cwd: cwd, members: bg, footprint: .mb(20))
    var sessions = [session(s, "dummy session", bg: [unit])]
    for (i, k) in extraSessions.enumerated() { sessions.append(session(k, "stubborn \(i)", bg: [])) }
    let leftover = LeftoverGroup(id: .leftover(pgid: lo[0].pid, leaderStartSec: lo[0].startSec),
                                 unit: LinkedUnit(root: lo[0], pgid: lo[0].pid, command: "fake-dev-server (leftover)",
                                                  argv: ["fake-dev-server", "60"], cwd: cwd, members: lo, footprint: .mb(30)),
                                 deadClaudePid: 1234, sessionTitle: "dead", cwd: cwd, startedAt: Date())
    return WorldSnapshot(system: .zero, chrome: .notRunning,
                         claude: ClaudeSnapshot(sessions: sessions, leftovers: [leftover]),
                         ownership: .empty, selfBytes: 0, at: Date())
}

@Suite(.serialized) struct CloseSequence {
    @Test func dryRunSignalsNothing() async throws {
        let d = try Dummies()
        defer { d.cleanup() }
        let s = try d.spawn("\"\(d.claude)\" 60")
        let g = try d.spawn("( \"\(d.dev)\" 60 & \"\(d.dev)\" 60 & wait )")
        let bg = d.waitForMembers(g.pid, count: 3)
        try #require(bg.count == 3)
        let l = try d.spawn("\"\(d.dev)\" 61")
        let w = makeWorld(session: s, background: bg, leftover: [l], cwd: d.dir)
        let env = d.env(dryRun: true)
        let coord = CloseCoordinator(env: env, backend: CloseBackend(sys: TestSysKit()), source: "test",
                                     timing: .fast)
        let plan = Planner().plan([.session(s), .leftover(pgid: l.pid, leaderStartSec: l.startSec)], w)
        #expect(plan.items.count == 2)
        let recs = await coord.run(plan) { _ in }
        #expect(recs.count == 2)
        let sys = TestSysKit()
        #expect(sys.isAlive(s) && sys.isAlive(l) && bg.allSatisfy(sys.isAlive))
        let entries = coord.journal.entries().filter { $0.kind == "signal" }
        #expect(entries.count == 3)          // session, its background group, the leftover
        #expect(entries.allSatisfy { $0.dryRun && $0.result == "dryRun" })
        // Dry run never writes closed.jsonl.
        #expect(!FileManager.default.fileExists(atPath: env.closedLog))
        #expect(coord.recent.list().count == 2)
    }

    @Test func closesSessionThenItsBackgroundPgidThenLeftover() async throws {
        let d = try Dummies()
        defer { d.cleanup() }
        let s = try d.spawn("\"\(d.claude)\" 60")
        let g = try d.spawn("( \"\(d.dev)\" 60 & \"\(d.dev)\" 60 & wait )")
        let bg = d.waitForMembers(g.pid, count: 3)
        try #require(bg.count == 3 && bg.allSatisfy { TestSysKit.sample($0.pid)?.pgid == g.pid })
        let lo = try d.spawn("( \"\(d.dev)\" 61 & wait )")
        let loMembers = d.waitForMembers(lo.pid, count: 2)
        try #require(loMembers.count == 2)
        let w = makeWorld(session: s, background: bg, leftover: loMembers, cwd: d.dir)
        let env = d.env(dryRun: false)
        let coord = CloseCoordinator(env: env, backend: CloseBackend(sys: TestSysKit()), source: "test", timing: .fast)
        let plan = SheetModel.apply(.close(2), to: Planner().plan([.session(s), .leftover(pgid: lo.pid, leaderStartSec: lo.startSec)], w),
                                    stopBackground: true)!
        let log_ = EventLog()
        let recs = await coord.run(plan) { log_.add($0) }
        let events = log_.events
        let sys = TestSysKit()
        #expect(!sys.isAlive(s), "session still alive")
        #expect(!bg.contains(where: sys.isAlive), "background group still alive")
        #expect(!loMembers.contains(where: sys.isAlive), "leftover still alive")
        let outcomes = events.compactMap { e -> (ItemID, Outcome)? in if case let .progress(i, o) = e { (i, o) } else { nil } }
        #expect(outcomes.contains { $0.0 == .session(s) && $0.1 == .done })
        #expect(outcomes.contains { $0.0 == .leftover(pgid: lo.pid, leaderStartSec: lo.startSec) && $0.1 == .done })
        #expect(!events.contains { if case .needsForce = $0 { true } else { false } })
        // Journal: intent, then SIGTERM to the session, then to -pgid for the background, then the leftover.
        let log = coord.journal.entries()
        #expect(log.first?.kind == "intent")
        let signals = log.filter { $0.kind == "signal" }
        #expect(signals.map(\.result) == ["sent", "sent", "sent"])
        #expect(signals[0].pid == s.pid && signals[0].signal == SIGTERM)
        #expect(signals[1].pgid == g.pid)
        #expect(signals[2].pgid == lo.pid)
        // Records: session restorable (resume), leftover not; both persisted to closed.jsonl.
        #expect(recs.count == 2)
        #expect(recs.first { $0.kind == "session" }?.restorable == true)
        #expect(recs.first { $0.kind == "leftover" }?.restorable == false)
        #expect(RecentlyClosed(env: env).list().count == 2)
    }

    @Test func uncheckedBoxLeavesBackgroundRunning() async throws {
        let d = try Dummies()
        defer { d.cleanup() }
        let s = try d.spawn("\"\(d.claude)\" 60")
        let g = try d.spawn("\"\(d.dev)\" 60")
        let l = try d.spawn("\"\(d.dev)\" 62")
        let w = makeWorld(session: s, background: [g], leftover: [l], cwd: d.dir)
        let coord = CloseCoordinator(env: d.env(dryRun: false), backend: CloseBackend(sys: TestSysKit()), source: "test",
                                     timing: .fast)
        var plan = Planner().plan([.session(s)], w)
        plan.stopBackground = false
        _ = await coord.run(plan) { _ in }
        let sys = TestSysKit()
        #expect(!sys.isAlive(s))
        #expect(sys.isAlive(g))
        #expect(sys.isAlive(l))
    }

    @Test func changedStartTimeIsSkipped() async throws {
        let d = try Dummies()
        defer { d.cleanup() }
        let s = try d.spawn("\"\(d.claude)\" 60")
        let g = try d.spawn("\"\(d.dev)\" 60")
        let l = try d.spawn("\"\(d.dev)\" 62")
        let wrong = ProcKey(pid: s.pid, startSec: s.startSec - 5)
        let w = makeWorld(session: wrong, background: [g], leftover: [ProcKey(pid: l.pid, startSec: l.startSec + 9)], cwd: d.dir)
        let coord = CloseCoordinator(env: d.env(dryRun: false), backend: CloseBackend(sys: TestSysKit()), source: "test",
                                     timing: .fast)
        let plan = Planner().plan([.session(wrong), .leftover(pgid: l.pid, leaderStartSec: l.startSec + 9)], w)
        let log_ = EventLog()
        let recs = await coord.run(plan) { log_.add($0) }
        let outs = log_.outcomes
        let sys = TestSysKit()
        #expect(sys.isAlive(s) && sys.isAlive(g) && sys.isAlive(l))
        #expect(outs[.session(wrong)] == .changedSkipped)
        #expect(outs[.leftover(pgid: l.pid, leaderStartSec: l.startSec + 9)] == .changedSkipped)
        #expect(recs.isEmpty)
    }

    @Test func stubbornSessionNeedsForceQuit() async throws {
        let d = try Dummies()
        defer { d.cleanup() }
        let s = try d.spawn("\"\(d.claude)\" 60")
        let stubborn = try d.spawn("( trap '' TERM; exec \"\(d.claude)\" 63 )")
        let g = try d.spawn("\"\(d.dev)\" 60")
        let l = try d.spawn("\"\(d.dev)\" 62")
        let w = makeWorld(session: s, background: [g], leftover: [l], cwd: d.dir, extraSessions: [stubborn])
        var timing = CloseTiming.fast
        timing.sessionGrace = 1
        let coord = CloseCoordinator(env: d.env(dryRun: false), backend: CloseBackend(sys: TestSysKit()), source: "test",
                                     timing: timing)
        let plan = Planner().plan([.session(stubborn)], w)
        let log_ = EventLog()
        _ = await coord.run(plan) { log_.add($0) }
        let force = log_.needsForce
        #expect(force == [.session(stubborn)])
        #expect(TestSysKit().isAlive(stubborn))
        #expect(coord.pendingForce() == [.session(stubborn)])
        let r = await coord.forceQuit([.session(stubborn)])
        #expect(r[.session(stubborn)] == .sent)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!TestSysKit().isAlive(stubborn))
        #expect(TestSysKit().isAlive(s))           // untouched
        let kill9 = coord.journal.entries().filter { $0.signal == SIGKILL }
        #expect(kill9.count == 1 && kill9[0].reason == "Force Quit (user)")
    }
}

/// Review findings: the close re-checks sessions right before SIGTERM, the undo never restores a record twice,
/// and a dry-run undo still runs the session refusals.
@Suite(.serialized) struct CloseRechecks {
    @Test func sessionThatBecameBusyIsNotSignalled() async throws {
        let d = try Dummies()
        defer { d.cleanup() }
        let s = try d.spawn("\"\(d.claude)\" 60")
        let g = try d.spawn("\"\(d.dev)\" 60")
        let l = try d.spawn("\"\(d.dev)\" 62")
        let w = makeWorld(session: s, background: [g], leftover: [l], cwd: d.dir)
        let planned = try #require(w.claude.sessions.first { $0.key == s })
        // Fresh state: the same session is now busy (the user started a prompt while the sheet / prompt was open).
        let busyNow = ClaudeSession(key: s, sessionId: planned.sessionId, cwd: planned.cwd, title: planned.title,
                                    project: planned.project, busy: true, status: "busy", startedAt: planned.startedAt,
                                    tmux: planned.tmux, selfFootprint: planned.selfFootprint, background: planned.background)
        let backend = CloseBackend(sys: TestSysKit(), freshSessions: { _ in [s: busyNow] })
        let coord = CloseCoordinator(env: d.env(dryRun: false), backend: backend, source: "test", timing: .fast)
        let plan = SheetModel.apply(.close(1), to: Planner().plan([.session(s)], w), stopBackground: true)!
        #expect(plan.skipBusy)
        let log_ = EventLog()
        let recs = await coord.run(plan) { log_.add($0) }
        #expect(log_.outcomes[.session(s)] == .changedSkipped)
        #expect(TestSysKit().isAlive(s) && TestSysKit().isAlive(g))
        #expect(recs.isEmpty)
        #expect(!coord.journal.entries().contains { $0.kind == "signal" })
    }

    @Test func automationMembersAreTheRecordedBrowsersNotTheRoot() {
        let daemon = ProcKey(pid: 10, startSec: 100), chrome = ProcKey(pid: 11, startSec: 101)
        let unit = LinkedUnit(root: daemon, pgid: 10, command: "agent-browser", members: [daemon, chrome],
                              footprint: 1, isAutomationBrowser: true)
        let own = OwnershipMap(owner: [:], browsers: [BrowserInstance(key: chrome, isMain: false, userDataDir: "/tmp/x",
                                                                      headless: true, remoteDebugging: true)],
                               liveSessions: [], staleSessionFiles: [])
        let w = WorldSnapshot(system: .zero, chrome: .notRunning, claude: .empty, ownership: own, selfBytes: 0, at: Date())
        #expect(CloseCoordinator.automationMembers(unit, w) == [chrome])
        let plain = LinkedUnit(root: daemon, pgid: 10, command: "bun", members: [daemon], footprint: 1)
        #expect(CloseCoordinator.automationMembers(plain, w).isEmpty)
    }

    @Test func undoSkipsRecordsAlreadyRestoredAndDryRunKeepsSessionRefusals() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hr-undo-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let env = HeadroomEnv(environment: ["HOME": dir, "HEADROOM_SUPPORT_DIR": dir])
        let tab = ClosedRecord(batchId: "b", kind: "tab", itemId: "tab:1:1", closedAt: Date(), title: "t", bytes: 1,
                               url: "https://a.example")
        let coord = CloseCoordinator(env: env, backend: CloseBackend(sys: TestSysKit()), source: "test")
        coord.recent.add([tab])
        coord.recent.markRestored([tab.id])                     // e.g. `headroom undo --last` ran first
        let out = await coord.undo([tab])
        #expect(out[tab] == .failed("already restored"))

        var dry = env; dry.dryRun = true
        let session = ClosedRecord(batchId: "b2", kind: "session", itemId: "session:5:5", closedAt: Date(), title: "s",
                                   bytes: 1, sessionId: "abc", cwd: "/nonexistent")
        let backend = CloseBackend(sys: TestSysKit(), reopenSessions: { recs in
            Dictionary(uniqueKeysWithValues: recs.map { ($0, Outcome.failed("working directory /nonexistent no longer exists")) })
        })
        let dryCoord = CloseCoordinator(env: dry, backend: backend, source: "test")
        let out2 = await dryCoord.undo([session])
        #expect(out2[session] == .failed("working directory /nonexistent no longer exists"))
    }
}

@Suite struct JournalAndRecentlyClosed {
    @Test func incognitoURLsNeverWrittenAndPrune() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hr-rc-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let env = HeadroomEnv(environment: ["HOME": dir, "HEADROOM_SUPPORT_DIR": dir])
        let rc = RecentlyClosed(env: env)
        #expect(rc.persist)
        let now = Date()
        rc.add([
            ClosedRecord(batchId: "b1", kind: "tab", itemId: "tab:1:1", closedAt: now, title: "secret", bytes: 1,
                         url: "https://secret.example", incognito: true),
            ClosedRecord(batchId: "b1", kind: "tab", itemId: "tab:1:2", closedAt: now, title: "ok", bytes: 1,
                         url: "https://ok.example"),
            ClosedRecord(batchId: "b0", kind: "session", itemId: "session:1:1", closedAt: now.addingTimeInterval(-8 * 86_400),
                         title: "old", bytes: 1, sessionId: "s"),
        ])
        let raw = try String(contentsOfFile: env.closedLog, encoding: .utf8)
        #expect(!raw.contains("secret.example"))
        #expect(raw.contains("ok.example"))
        #expect(Set(rc.list(now: now).map(\.title)) == ["ok", "secret"])
        #expect(rc.lastBatch(now: now).count == 2)
        rc.markRestored([rc.list(now: now).first { $0.title == "ok" }!.id])
        #expect(rc.list(now: now).map(\.title) == ["secret"])
        rc.prune(now: now)
        let after = try String(contentsOfFile: env.closedLog, encoding: .utf8)
        #expect(!after.contains("\"old\""))
        // A second store (the CLI) sees the same records.
        #expect(RecentlyClosed(env: env).list(now: now).count == 1)
    }

    /// In dry run the store reads closed.jsonl (read-only) and merges its own
    /// in-memory records; nothing is written. Mock never reads the disk.
    @Test func dryRunReadsDiskButNeverWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hr-rc-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let live = HeadroomEnv(environment: ["HOME": dir, "HEADROOM_SUPPORT_DIR": dir])
        let now = Date()
        RecentlyClosed(env: live).add([ClosedRecord(batchId: "real", kind: "tab", itemId: "tab:1:1", closedAt: now,
                                                     title: "real", bytes: 1, url: "https://a.example")])
        let before = try String(contentsOfFile: live.closedLog, encoding: .utf8)
        let dry = HeadroomEnv(environment: ["HOME": dir, "HEADROOM_SUPPORT_DIR": dir, "HEADROOM_DRY_RUN": "1"])
        let rc = RecentlyClosed(env: dry)
        #expect(!rc.persist && rc.readsDisk)
        rc.add([ClosedRecord(batchId: "dry", kind: "tab", itemId: "tab:1:2", closedAt: now.addingTimeInterval(1),
                             title: "dry", bytes: 1, url: "https://b.example")])
        #expect(rc.list(now: now.addingTimeInterval(2)).map(\.title) == ["dry", "real"])
        rc.markRestored([rc.list(now: now.addingTimeInterval(2)).last!.id])
        #expect(rc.list(now: now.addingTimeInterval(2)).map(\.title) == ["dry"])
        #expect(try String(contentsOfFile: live.closedLog, encoding: .utf8) == before)
        #expect(!FileManager.default.fileExists(atPath: dir + "/restored.jsonl"))
        let mock = HeadroomEnv(environment: ["HOME": dir, "HEADROOM_SUPPORT_DIR": dir, "HEADROOM_DRY_RUN": "1", "HEADROOM_MOCK": "1"])
        #expect(RecentlyClosed(env: mock).list(now: now).isEmpty)
    }
}
