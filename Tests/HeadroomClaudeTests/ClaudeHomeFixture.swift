// A scratch ~/.claude (sessions JSON + transcripts) plus a matching synthetic process table, for the Claude tests.
// Everything lives under a fresh temporary directory; nothing touches the real ~/.claude, tmux or processes.

import Foundation
import HeadroomContracts
import HeadroomCore
@testable import HeadroomClaude

final class ScratchDir {
    let path: String
    init(_ tag: String = "wp2") {
        let base = FileManager.default.temporaryDirectory.path
        path = CoreSelfTest.realPath(base) + "/headroom-\(tag)-\(UUID().uuidString.prefix(8))"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    @discardableResult
    func write(_ rel: String, _ content: String) -> String {
        let p = path + "/" + rel
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try! content.write(toFile: p, atomically: false, encoding: .utf8)
        return p
    }
    func mkdir(_ rel: String) { try! FileManager.default.createDirectory(atPath: path + "/" + rel, withIntermediateDirectories: true) }
}

enum TX {
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    static func json(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!
    }
    /// Shaped like real Claude Code lines: parentUuid first, then type/role early.
    static func user(_ text: String, at: Date, sid: String) -> String {
        "{\"parentUuid\":\"\(UUID().uuidString.lowercased())\",\"isSidechain\":false,\"promptId\":\"p\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\(json(["t": text]).dropFirst(5).dropLast())},\"uuid\":\"u\",\"timestamp\":\"\(iso(at))\",\"sessionId\":\"\(sid)\"}"
    }
    static func toolResult(at: Date, sid: String) -> String {
        "{\"parentUuid\":\"x\",\"isSidechain\":false,\"promptId\":\"p\",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"tool_use_id\":\"t\",\"type\":\"tool_result\",\"content\":\"ok\"}]},\"timestamp\":\"\(iso(at))\",\"sessionId\":\"\(sid)\"}"
    }
    static func assistant(_ text: String?, at: Date, sid: String, toolUse: Bool = false) -> String {
        var blocks: [[String: Any]] = []
        if let text { blocks.append(["type": "text", "text": text]) }
        if toolUse { blocks.append(["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls"]]) }
        let content = String(json(["c": blocks]).dropFirst(5).dropLast())
        return "{\"parentUuid\":\"\(UUID().uuidString.lowercased())\",\"isSidechain\":false,\"message\":{\"model\":\"claude-opus-5-5\",\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":\(content),\"stop_reason\":\"end_turn\"},\"type\":\"assistant\",\"uuid\":\"a\",\"timestamp\":\"\(iso(at))\",\"sessionId\":\"\(sid)\"}"
    }
    static func aiTitle(_ t: String, sid: String) -> String { json(["type": "ai-title", "aiTitle": t, "sessionId": sid]) }
    static func customTitle(_ t: String, sid: String) -> String { json(["type": "custom-title", "customTitle": t, "sessionId": sid]) }
    static func lastPrompt(_ t: String, sid: String) -> String { json(["type": "last-prompt", "lastPrompt": t, "sessionId": sid]) }
    static func away(_ t: String, at: Date, sid: String) -> String {
        "{\"parentUuid\":\"x\",\"isSidechain\":false,\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\(json(["c": t]).dropFirst(5).dropLast()),\"timestamp\":\"\(iso(at))\",\"sessionId\":\"\(sid)\"}"
    }
    static func attachment(at: Date, pad: Int = 900) -> String {
        "{\"parentUuid\":\"x\",\"isSidechain\":false,\"attachment\":{\"type\":\"reminder\",\"text\":\"\(String(repeating: "z", count: pad))\"},\"type\":\"attachment\",\"timestamp\":\"\(iso(at))\"}"
    }
}

/// procStart as Claude Code writes it: UTC, en_US_POSIX "EEE MMM d HH:mm:ss yyyy".
func procStartString(_ sec: Int) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(sec)))
}

/// The fixture world (see ClaudeFixtureTests for what each row exercises).
struct ClaudeWorld {
    static let base = 1_790_000_000
    static let now = Date(timeIntervalSince1970: TimeInterval(base + 20_000))
    static let claudePath = "/Users/fixture/.local/share/claude/versions/2.1.284"
    static let sidA = "aaaaaaaa-0000-4000-8000-00000000000a"
    static let sidB = "bbbbbbbb-0000-4000-8000-00000000000b"
    static let sidC = "cccccccc-0000-4000-8000-00000000000c"
    static let sidD = "dddddddd-0000-4000-8000-00000000000d"
    static let sidE = "eeeeeeee-0000-4000-8000-00000000000e"
    static let sidDead1 = "deadbeef-0000-4000-8000-000000000001"
    static let sidDead2 = "deadbeef-0000-4000-8000-000000000002"

    let dir = ScratchDir("claude")
    var env: HeadroomEnv
    var table: ProcessTable
    var sys: StaticSysKit
    var panes: [TmuxPane]
    var clients: [TmuxClientInfo]
    var repo: String { dir.path + "/work/repo" }
    var worktree: String { dir.path + "/work/repo/.claude/worktrees/wt1" }
    var plain: String { dir.path + "/work/plain" }
    var gone: String { dir.path + "/work/gone" }

    init() {
        env = HeadroomEnv(environment: [
            "HOME": dir.path, "HEADROOM_CLAUDE_DIR": dir.path + "/.claude",
            "HEADROOM_SUPPORT_DIR": dir.path + "/support", "HEADROOM_DRY_RUN": "1",
            "HEADROOM_TMUX": "/nonexistent/tmux", "CLAUDE_PID": "302"])
        let b = Self.base
        let now = Self.now
        let dir = self.dir
        let repo = dir.path + "/work/repo", worktree = dir.path + "/work/repo/.claude/worktrees/wt1"
        let plain = dir.path + "/work/plain", gone = dir.path + "/work/gone"

        // Git: repo on branch feature-x, and a linked worktree .claude/worktrees/wt1 on wt1-branch.
        dir.write("work/repo/.git/HEAD", "ref: refs/heads/feature-x\n")
        dir.write("work/repo/.git/worktrees/wt1/HEAD", "ref: refs/heads/wt1-branch\n")
        dir.write("work/repo/.git/worktrees/wt1/commondir", "../..\n")
        dir.write("work/repo/.claude/worktrees/wt1/.git", "gitdir: \(dir.path)/work/repo/.git/worktrees/wt1\n")
        dir.mkdir("work/plain")

        // Sessions JSON.
        func session(_ pid: Int32, _ sid: String, cwd: String, start: Int, name: String?, nameSource: String?,
                     status: String?, statusAgo: TimeInterval, bridge: String? = nil, extra: [String: Any] = [:]) {
            var j: [String: Any] = ["pid": pid, "sessionId": sid, "cwd": cwd, "startedAt": Double(start) * 1000 + 400,
                                    "procStart": procStartString(start), "version": "2.1.284", "kind": "interactive",
                                    "entrypoint": "cli", "tmux": "stale:@1.%999",
                                    "statusUpdatedAt": (now.timeIntervalSince1970 - statusAgo) * 1000,
                                    "updatedAt": (now.timeIntervalSince1970 - statusAgo) * 1000]
            if let name { j["name"] = name }
            if let nameSource { j["nameSource"] = nameSource }
            if let status { j["status"] = status }
            j["bridgeSessionId"] = bridge ?? NSNull()
            for (k, v) in extra { j[k] = v }
            dir.write(".claude/sessions/\(pid).json", TX.json(j))
            dir.write(".claude/sessions/\(pid).abc123.key", "not json")
        }
        session(301, Self.sidA, cwd: repo, start: b + 100, name: "handoff design", nameSource: "user",
                status: "idle", statusAgo: 7200, bridge: "cse_01")
        session(302, Self.sidB, cwd: worktree, start: b + 200, name: "hammer-47", nameSource: "derived",
                status: "busy", statusAgo: 90)
        session(303, Self.sidC, cwd: plain, start: b + 300, name: "quiet-fox-12", nameSource: "derived",
                status: "idle", statusAgo: 600)
        session(304, Self.sidD, cwd: gone, start: b + 400, name: nil, nameSource: nil, status: "idle", statusAgo: 50_000)
        // Stale: pid 998 is gone. Its transcript names the dead session of leftover 620.
        session(998, Self.sidDead2, cwd: plain, start: b - 50_000, name: "old-name", nameSource: "derived",
                status: "idle", statusAgo: 90_000)
        dir.write(".claude/sessions/997.json", "{\"pid\": 997, \"sessionId\": ")   // half-written: skipped

        // Transcripts.
        let projA = ".claude/projects/" + TranscriptTail.projectDirName(cwd: repo)
        dir.write("\(projA)/\(Self.sidA).jsonl", [
            TX.user("start the handoff doc", at: now - 9000, sid: Self.sidA),
            TX.aiTitle("Handoff design doc", sid: Self.sidA),
            TX.assistant("Drafted the handoff doc.", at: now - 8000, sid: Self.sidA),
            TX.lastPrompt("start the handoff doc", sid: Self.sidA),
        ].joined(separator: "\n") + "\n")
        let projB = ".claude/projects/" + TranscriptTail.projectDirName(cwd: worktree)
        dir.write("\(projB)/\(Self.sidB).jsonl", [
            TX.user("fix the login bug", at: now - 200, sid: Self.sidB),
            TX.aiTitle("Fix login bug", sid: Self.sidB),
            TX.assistant(nil, at: now - 100, sid: Self.sidB, toolUse: true),
            TX.toolResult(at: now - 95, sid: Self.sidB),
        ].joined(separator: "\n") + "\n")
        // C and D: no transcript. E (unregistered, argv --resume sidE): transcript in an unrelated project dir (glob).
        dir.write(".claude/projects/-somewhere-else/\(Self.sidE).jsonl", [
            TX.aiTitle("Resumed investigation", sid: Self.sidE),
            TX.assistant("Looking into it.", at: now - 4000, sid: Self.sidE),
        ].joined(separator: "\n") + "\n")
        // Dead session of leftover 620 (found by glob via CLAUDE_CODE_SESSION_ID).
        dir.write(".claude/projects/-old/\(Self.sidDead2).jsonl", TX.aiTitle("Old dashboard work", sid: Self.sidDead2) + "\n")
        // closed.jsonl names the dead session of leftover 610.
        dir.write("support/closed.jsonl", TX.json(["id": "r1", "batchId": "b1", "kind": "session", "itemId": "session:999:1",
                                                    "closedAt": "2026-09-29T10:00:00Z", "title": "tour landing",
                                                    "bytes": 1, "source": "app", "sessionId": Self.sidDead1]) + "\n")

        // Processes.
        let MB: Bytes = 1 << 20
        var s: [ProcSample] = []
        var args: [Int32: ProcArgs] = [:]
        var cwds: [Int32: String] = [:]
        func p(_ pid: Int32, _ ppid: Int32, _ path: String, _ argv: [String], mb: Bytes, start: Int, pgid: Int32? = nil,
               env: [String: String] = [:], cwd: String? = nil) {
            s.append(ProcSample(key: ProcKey(pid: pid, startSec: start), ppid: ppid, pgid: pgid ?? pid, path: path,
                                footprint: mb * MB, rss: mb * MB / 2))
            args[pid] = ProcArgs(argv: argv, env: env)
            if let cwd { cwds[pid] = cwd }
        }
        p(1, 0, "/sbin/launchd", ["/sbin/launchd"], mb: 10, start: b - 99_999)
        p(100, 1, "/opt/homebrew/bin/tmux", ["tmux"], mb: 5, start: b - 1000)
        for (i, pane) in [201, 202, 203, 204].enumerated() {
            p(Int32(pane), 100, "/bin/zsh", ["-zsh"], mb: 2, start: b + 50 + i)
        }
        p(301, 201, Self.claudePath, ["claude"], mb: 300, start: b + 100)
        p(401, 301, "/opt/homebrew/bin/node", ["node", "mcp-server.js"], mb: 40, start: b + 101, pgid: 301)
        p(302, 202, Self.claudePath, ["claude"], mb: 250, start: b + 200)
        p(402, 302, "/usr/bin/caffeinate", ["caffeinate", "-i", "-t", "300"], mb: 1, start: b + 19_000, pgid: 302)
        p(303, 203, Self.claudePath, ["claude"], mb: 200, start: b + 300)
        p(304, 1, Self.claudePath, ["claude"], mb: 150, start: b + 400)
        p(305, 204, Self.claudePath, ["claude", "--resume", Self.sidE], mb: 120, start: b + 500, cwd: plain)
        // Background of A: bun dev (env-linked to live 301).
        p(501, 1, "/opt/homebrew/bin/bun", ["bun", "run", "dev", "--port", "3217"], mb: 500, start: b + 1000,
          env: ["CLAUDE_PID": "301", "CLAUDE_CODE_SESSION_ID": Self.sidA], cwd: repo)
        p(502, 501, "/opt/homebrew/bin/node", ["node", "next", "dev"], mb: 300, start: b + 1001, pgid: 501,
          env: ["CLAUDE_PID": "301"])
        // Leftover 610: dead CLAUDE_PID 999, titled from closed.jsonl.
        p(610, 1, "/opt/homebrew/bin/bun", ["bun", "run", "dev", "--port", "3000"], mb: 700, start: b - 40_000,
          env: ["CLAUDE_PID": "999", "CLAUDE_CODE_SESSION_ID": Self.sidDead1], cwd: dir.path + "/work/harbour-tours")
        p(611, 610, "/opt/homebrew/bin/node", ["node", "server"], mb: 300, start: b - 39_999, pgid: 610,
          env: ["CLAUDE_PID": "999"])
        // Leftover 620: dead CLAUDE_PID 998 (whose session file is stale), titled from the dead transcript.
        p(620, 1, "/opt/homebrew/bin/python3", ["python3", "-m", "http.server"], mb: 30, start: b - 49_000,
          env: ["CLAUDE_PID": "998", "CLAUDE_CODE_SESSION_ID": Self.sidDead2])
        table = ProcessTable(samples: s, takenAt: now)
        sys = StaticSysKit(table: table, args: args, cwds: cwds)

        func pane(_ id: String, _ pid: Int32, active: Bool, winActive: Bool, attached: Int, session: String,
                  win: Int, title: String) -> TmuxPane {
            TmuxPane(paneId: id, panePid: pid, paneActive: active, windowActive: winActive, sessionAttached: attached,
                     session: session, windowIndex: win, paneIndex: 0, windowName: "w\(win)", paneTitle: title,
                     currentCommand: "claude")
        }
        panes = [
            pane("%1", 201, active: true, winActive: true, attached: 1, session: "hub", win: 1, title: "✳ Handoff design doc"),
            pane("%2", 202, active: true, winActive: false, attached: 1, session: "hub", win: 2, title: "⠐ Fix login bug"),
            pane("%3", 203, active: true, winActive: true, attached: 0, session: "misc", win: 1, title: "✳ Pane Title Here"),
            pane("%4", 204, active: true, winActive: true, attached: 0, session: "misc", win: 2, title: "fixture-host"),
        ]
        clients = [TmuxClientInfo(activity: 1_790_019_000, tty: "/dev/ttys001", session: "hub")]
    }

    func assign() -> OwnershipMap {
        let recs = SessionStore(dir: env.sessionsDir, watch: false).records()
        return Ownership.assign(table, sessions: recs, hosts: [], tmuxPanes: panes, sys: sys, env: env,
                                excluding: [], uid: nil)
    }

    func source(desktop: RecordingDesktop = RecordingDesktop()) -> ClaudeSource {
        let src = ClaudeSource(env: env, desktop: desktop, watch: false)
        src.cpuSettle = 0
        let p = panes, c = clients
        src.tmuxData = { (p, c) }
        src.clock = { ClaudeWorld.now }
        return src
    }
}
