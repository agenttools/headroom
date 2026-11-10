// MockWorld — a deterministic, realistic WorldSnapshot (~40 rows) modelled on a typical developer's mix:
// 15 Chrome tabs in 4 windows (webmail, Maps, claude.ai, localhost, file://, a shared Linear renderer,
// an audible YouTube, a discarded tab, an incognito tab), 20 Claude sessions across the tmux sessions
// quote-composer / oakfield-ledger / hub / misc / millrace, 3 leftovers, an agent-browser automation
// Chrome owned by a session, and one unowned "Other Chrome instances" browser.
//
// ItemIDs are stable across calls (start times use a fixed epoch); only ages move with `now`.
// Used for UI development, the CLI (--mock), and tests. `HEADROOM_MOCK=1` selects it.

import Foundation

public enum MockWorld {
    /// Fixed epoch for start times so ItemIDs never change between snapshots.
    public static let epoch = 1_790_700_000
    public static let mainBrowserPid: Int32 = 812
    public static let automationBrowserPid: Int32 = 85291
    public static let otherBrowserPid: Int32 = 77120
    public static let launcherPid: Int32 = 60102

    public static func snapshot(now: Date = Date()) -> WorldSnapshot {
        var owner: [Int32: Owner] = [:]
        let chrome = makeChrome(now: now, owner: &owner)
        let claude = makeClaude(now: now, owner: &owner)
        let browsers = [
            BrowserInstance(key: ProcKey(pid: mainBrowserPid, startSec: epoch - 400_000), isMain: true,
                            userDataDir: nil, headless: false),
            BrowserInstance(key: ProcKey(pid: automationBrowserPid, startSec: epoch - 700), isMain: false,
                            userDataDir: "/Users/jappleseed/.agent-browser/profile", headless: true,
                            remoteDebugging: true),
            BrowserInstance(key: ProcKey(pid: otherBrowserPid, startSec: epoch - 90_000), isMain: false,
                            userDataDir: "/private/tmp/pw-profile-3", headless: false, remoteDebugging: true),
        ]
        let ownership = OwnershipMap(
            owner: owner, browsers: browsers, liveSessions: claude.sessions.filter { !$0.unregistered }.map(\.key),
            staleSessionFiles: claude.staleFiles)
        let system = SystemMemory(
            total: .gb(48), used: .gb(39.8), appMemory: .gb(30.5), wired: .gb(3.2), compressed: .gb(6.1),
            free: .gb(8.2), swapUsed: .gb(3.0), swapTotal: .gb(4.0), pressure: .warning)
        return WorldSnapshot(system: system, chrome: chrome, claude: claude, ownership: ownership,
                             selfBytes: .mb(31), helperBytes: .mb(24), at: now, isMock: true)
    }

    // MARK: Chrome

    private struct T {
        let win: Int, title: String, url: String, renderers: [String]
        var active = false, audible = false, pinned = false, discarded = false, incognito = false
        var minutesAgo: Double = 30
    }

    private static let renderers: [String: Double] = [ // MB
        "inbox": 412, "maps": 386, "claude": 540, "stripejs": 48, "local": 188, "file": 64, "linear": 280,
        "yt": 412, "vercel": 210, "gh": 160, "figma": 1020, "cal": 180, "notion": 240, "incog": 72,
    ]

    private static let tabsSpec: [T] = [
        T(win: 1, title: "Inbox (3) – me@example.com – Mail", url: "https://mail.google.com/mail/u/0/#inbox",
          renderers: ["inbox"], pinned: true, minutesAgo: 12),
        T(win: 1, title: "Headroom design review – Claude", url: "https://claude.ai/chat/7f0c2a51-9d7e-4c52-9f1e-2b6a0c0de111",
          renderers: ["claude", "stripejs"], active: true, minutesAgo: 0),
        T(win: 1, title: "Boston to Cambridge – Google Maps", url: "https://www.google.com/maps/dir/Boston/Cambridge",
          renderers: ["maps"], minutesAgo: 190),
        T(win: 1, title: "tour landing – localhost:3217", url: "http://localhost:3217/", renderers: ["local"],
          minutesAgo: 75),
        T(win: 1, title: "mock.html", url: "file:///Users/jappleseed/Desktop/mock.html",
          renderers: ["file"], minutesAgo: 240),
        T(win: 1, title: "ENG-412 Ledger sync – Linear", url: "https://linear.app/oakfield/issue/ENG-412",
          renderers: ["linear"], minutesAgo: 50),
        T(win: 1, title: "My issues – Linear", url: "https://linear.app/oakfield/my-issues", renderers: ["linear"],
          minutesAgo: 55),
        T(win: 2, title: "Oakfield onboarding – Figma", url: "https://www.figma.com/design/abc123/Oakfield-onboarding",
          renderers: ["figma"], active: true, minutesAgo: 20),
        T(win: 2, title: "Swift concurrency deep dive – YouTube", url: "https://www.youtube.com/watch?v=swiftconc",
          renderers: ["yt"], audible: true, minutesAgo: 8),
        T(win: 2, title: "quote-composer – Deployments – Vercel", url: "https://vercel.com/acme/quote-composer/deployments",
          renderers: ["vercel"], minutesAgo: 400),
        T(win: 2, title: "Fix ledger rounding #212 – GitHub", url: "https://github.com/acme/oakfield-ledger/pull/212",
          renderers: ["gh"], minutesAgo: 95),
        T(win: 2, title: "Webhooks | Stripe Documentation", url: "https://docs.stripe.com/webhooks", renderers: [],
          discarded: true, minutesAgo: 2900),
        T(win: 3, title: "Calendar – Week of September 28", url: "https://calendar.google.com/calendar/u/0/r/week",
          renderers: ["cal"], active: true, minutesAgo: 35),
        T(win: 3, title: "Q4 plan – Notion", url: "https://www.notion.so/acme/Q4-plan-1f2e", renderers: ["notion"],
          minutesAgo: 600),
        T(win: 4, title: "Private tab", url: "https://example.com/private", renderers: ["incog"], active: true,
          incognito: true, minutesAgo: 15),
    ]

    private static func makeChrome(now: Date, owner: inout [Int32: Owner]) -> ChromeSnapshot {
        let b = mainBrowserPid
        owner[b] = .chrome(browserPid: b)
        var procKey: [String: ProcKey] = [:]
        var procFootprint: [ProcKey: Bytes] = [:]
        for (i, name) in renderers.keys.sorted().enumerated() {
            let k = ProcKey(pid: 9000 + Int32(i), startSec: epoch - 3_600 * (i + 1))
            procKey[name] = k
            procFootprint[k] = .mb(renderers[name]!)
            owner[k.pid] = .chrome(browserPid: b)
        }
        var procUsers: [ProcKey: Set<TabRef>] = [:]
        var tabs: [ChromeTab] = []
        var windows: [Int: ChromeWindow] = [:]
        var indexInWindow: [Int: Int] = [:]
        for (i, s) in tabsSpec.enumerated() {
            let tabId = 1_101_000 + i * 7
            let windowId = 1_100_000 + s.win
            let idx = indexInWindow[s.win, default: 0]; indexInWindow[s.win] = idx + 1
            let ref = TabRef(browserPid: b, tabId: tabId)
            let keys = s.renderers.compactMap { procKey[$0] }
            for k in keys { procUsers[k, default: []].insert(ref) }
            let frames = keys.enumerated().map { j, k in
                ChromeFrame(frameId: j == 0 ? 0 : 40 + j, parentFrameId: j == 0 ? -1 : 0, processId: Int(k.pid) - 8990,
                            lifecycle: "active")
            }
            tabs.append(ChromeTab(
                browserPid: b, id: tabId, windowId: windowId, index: idx, title: s.title, url: s.url,
                host: URL(string: s.url)?.host ?? (s.url.hasPrefix("file:") ? "file" : ""), active: s.active,
                audible: s.audible, pinned: s.pinned, discarded: s.discarded, incognito: s.incognito,
                lastAccessed: now.addingTimeInterval(-s.minutesAgo * 60), frames: frames, procs: keys))
            windows[windowId, default: ChromeWindow(browserPid: b, id: windowId, focused: s.win == 1,
                                                    incognito: s.incognito)].tabIds.append(tabId)
        }
        // Fair-share attribution (§4.4) so the mock numbers add up like the real ones.
        for i in tabs.indices {
            let t = tabs[i]
            if t.discarded { tabs[i].display = 0; continue }
            var display: Bytes = 0, exclusive: Bytes = 0
            for k in t.procs {
                let users = procUsers[k]?.count ?? 1
                display += (procFootprint[k] ?? 0) / Bytes(users)
                if users == 1 { exclusive += procFootprint[k] ?? 0 }
            }
            tabs[i].display = display; tabs[i].exclusive = exclusive
            tabs[i].sharedWith = max(0, (t.procs.first.flatMap { procUsers[$0]?.count } ?? 1) - 1)
        }
        // Chrome itself.
        let overhead: [ChromeOverheadKind: (Int, Double)] = [
            .browser: (1, 420), .gpu: (1, 610), .utility: (6, 180), .crashpad: (1, 8),
            .extensions: (7, 520), .background: (3, 210), .otherInstances: (1, 300),
        ]
        var nextPid: Int32 = 9100
        for (kind, v) in overhead where kind != .otherInstances && kind != .browser {
            for _ in 0..<v.0 { owner[nextPid] = .chrome(browserPid: b); nextPid += 1 }
        }
        owner[otherBrowserPid] = .otherChrome(browserPid: otherBrowserPid)
        let ov = Dictionary(uniqueKeysWithValues: overhead.map { ($0.key.rawValue, OverheadStat(count: $0.value.0, bytes: .mb($0.value.1))) })
        let total = procFootprint.values.reduce(0, +) + ov.values.reduce(0) { $0 + $1.bytes }
        return ChromeSnapshot(source: .helper(profiles: 1), windows: windows.values.sorted { $0.id < $1.id },
                              tabs: tabs, overhead: ov, total: total, procFootprint: procFootprint,
                              procUsers: procUsers)
    }

    // MARK: Claude

    private struct S {
        let title: String, cwd: String, tmux: (String, Int, Int)?
        let mb: Double
        var branch: String? = "main", worktree: String? = nil
        var busyMinutes: Double? = nil, idleMinutes: Double = 60
        var remote = false, visible = false, launcher = false, noTranscript = false, cwdMissing = false
        var unregistered = false
        var bg: [(String, Double, Bool)] = []       // command, MB, isAutomationBrowser
        var children: [(String, Double)] = []
        var prompt: String? = nil
    }

    private static let home = "/Users/jappleseed"

    private static let sessionsSpec: [S] = [
        S(title: "clip generation", cwd: home + "/learning", tmux: ("hub", 3, 1), mb: 520, branch: nil,
          busyMinutes: 11, bg: [("agent-browser (Chrome, headless)", 1280, true), ("bun run clip-worker", 38, false)],
          children: [("node playwright-mcp", 45)], prompt: "render the next 5 clips and upload them"),
        S(title: "workflow ideas for ops", cwd: home + "/work/quote-composer/.claude/worktrees/jiggly",
          tmux: ("quote-composer", 2, 0), mb: 480, branch: "jiggly", worktree: "jiggly", busyMinutes: 2),
        S(title: "map directions", cwd: home + "/work", tmux: ("hub", 5, 0), mb: 403, branch: nil, idleMinutes: 30 * 60),
        S(title: "mutable-sprouting-bird", cwd: home + "/work/hammer", tmux: ("misc", 158, 0), mb: 380,
          idleMinutes: 2 * 24 * 60, remote: true),
        S(title: "weekly update skill", cwd: home + "/learning", tmux: ("misc", 7, 0), mb: 333, branch: nil,
          idleMinutes: 3 * 24 * 60, visible: true, bg: [("bun run watch", 12, false)]),
        S(title: "ram", cwd: home, tmux: ("hub", 1, 0), mb: 356, branch: nil, busyMinutes: 1, launcher: true,
          prompt: "build headroom step 0"),
        S(title: "oakfield onboarding flow", cwd: home + "/work/oakfield-ledger", tmux: ("oakfield-ledger", 1, 0),
          mb: 610, idleMinutes: 45, bg: [("bun run dev --port 3000", 640, false)]),
        S(title: "oakfield ledger sync", cwd: home + "/work/oakfield-ledger", tmux: ("oakfield-ledger", 2, 0),
          mb: 420, branch: "eng-412-ledger", busyMinutes: 5),
        S(title: "oakfield copy review", cwd: home + "/work/oakfield-ledger", tmux: ("oakfield-ledger", 3, 0),
          mb: 290, idleMinutes: 6 * 60),
        S(title: "quote import pipeline", cwd: home + "/work/quote-composer", tmux: ("quote-composer", 1, 0),
          mb: 350, idleMinutes: 4 * 60),
        S(title: "pricing page tweaks", cwd: home + "/work/quote-composer/.claude/worktrees/bubbly",
          tmux: ("quote-composer", 3, 0), mb: 310, branch: "bubbly", worktree: "bubbly", idleMinutes: 26 * 60),
        S(title: "managed agents", cwd: home + "/kb", tmux: ("hub", 2, 0), mb: 270, branch: nil, idleMinutes: 8),
        S(title: "hammer-47", cwd: home + "/work/hammer", tmux: ("millrace", 151, 0), mb: 300, idleMinutes: 20 * 60),
        S(title: "hammer-bb", cwd: home + "/work/hammer", tmux: ("millrace", 184, 0), mb: 280, idleMinutes: 3 * 60,
          remote: true),
        S(title: "plant watch", cwd: home + "/learning/plant-watch", tmux: ("misc", 3, 0), mb: 240,
          idleMinutes: 5 * 24 * 60),
        S(title: "digest steward", cwd: home + "/learning/digest", tmux: ("misc", 4, 0), mb: 260, idleMinutes: 12 * 60),
        S(title: "newsletter draft", cwd: home + "/learning/newsletter-drafts", tmux: nil, mb: 230,
          idleMinutes: 3 * 60),
        S(title: "scratch", cwd: home + "/tmp/scratch", tmux: ("hub", 6, 0), mb: 190, branch: nil, idleMinutes: 70,
          noTranscript: true),
        S(title: "old compass worktree", cwd: home + "/work/compass/.claude/worktrees/gone", tmux: ("misc", 9, 0),
          mb: 210, branch: nil, worktree: "gone", idleMinutes: 2 * 24 * 60, cwdMissing: true),
        S(title: "claude (no session file)", cwd: home + "/learning/headroom", tmux: ("hub", 7, 0), mb: 300,
          idleMinutes: 90, unregistered: true),
    ]

    private static func makeClaude(now: Date, owner: inout [Int32: Owner]) -> ClaudeSnapshot {
        var sessions: [ClaudeSession] = []
        var nextPid: Int32 = 61000
        for (i, s) in sessionsSpec.enumerated() {
            let pid: Int32 = s.launcher ? launcherPid : 41000 + Int32(i) * 97
            let startedAgo = max(s.idleMinutes, s.busyMinutes ?? 0) * 60 + 1800 + Double(i) * 60
            let key = ProcKey(pid: pid, startSec: epoch - Int(startedAgo))
            owner[pid] = s.unregistered ? .unregisteredClaude(key) : .session(key)
            func unit(_ cmd: String, _ mb: Double, auto: Bool, bg: Bool) -> LinkedUnit {
                let rootPid = auto ? automationBrowserPid : nextPid
                nextPid += 3
                let root = ProcKey(pid: rootPid, startSec: key.startSec + 120)
                let members = auto ? [root] + (1...4).map { ProcKey(pid: rootPid + Int32($0), startSec: root.startSec) } : [root]
                for m in members { owner[m.pid] = bg ? .claudeBackground(key) : .claudeChild(key) }
                return LinkedUnit(root: root, pgid: rootPid, command: cmd, argv: cmd.split(separator: " ").map(String.init),
                                  cwd: s.cwd, members: members, footprint: .mb(mb), isAutomationBrowser: auto)
            }
            let busy = s.busyMinutes != nil
            let last = now.addingTimeInterval(-(s.busyMinutes ?? s.idleMinutes) * 60)
            let tmux = s.tmux.map { t in
                TmuxLoc(paneId: "%\(200 + i)", session: t.0, windowName: s.title, windowIndex: t.1, paneIndex: t.2,
                        panePid: pid - 1, visible: s.visible, current: s.visible)
            }
            let project = URL(fileURLWithPath: s.cwd.components(separatedBy: "/.claude/worktrees/")[0]).lastPathComponent
            sessions.append(ClaudeSession(
                key: key, sessionId: String(format: "%08x-0000-4000-8000-%012x", 0xc5d5_0000 + i, 0x1000 + i),
                cwd: s.cwd, title: s.title, project: project, worktree: s.worktree, branch: s.branch,
                cwdExists: !s.cwdMissing, hasTranscript: !s.noTranscript && !s.unregistered, busy: busy,
                remoteControl: s.remote, isLauncher: s.launcher, unregistered: s.unregistered,
                status: s.unregistered ? "unknown" : busy ? "busy" : "idle", statusSince: last,
                lastActivity: last, startedAt: Date(timeIntervalSince1970: TimeInterval(key.startSec)),
                cpuPercent: busy ? 14.5 : 0.1, lastPrompt: s.prompt ?? "continue with \(s.title)",
                lastAssistant: busy ? "Working on it…" : "Done. Anything else?", awaySummary: nil, tmux: tmux,
                version: "2.1.285", selfFootprint: .mb(s.mb), selfRSS: .mb(s.mb * 0.8),
                children: s.children.map { unit($0.0, $0.1, auto: false, bg: false) },
                background: s.bg.map { unit($0.0, $0.1, auto: $0.2, bg: true) }))
        }
        let leftoversSpec: [(Int32, Int32, String, Double, String, String)] = [
            (7164, 21630, "bun run dev --port 3217", 1200, home + "/work/harbour-tours", "tour landing"),
            (40363, 38011, "doppler run -- next dev", 885,
             home + "/work/compass/.claude/worktrees/bubbly-discovering-clock", "compass onboarding"),
            (51220, 50001, "next-server (v15.5) + bun start", 156, home + "/work/monthly-budget-tool-wt", "budget wt"),
        ]
        var leftovers: [LeftoverGroup] = []
        for (i, l) in leftoversSpec.enumerated() {
            let start = epoch - 86_400 * (i + 1)
            let root = ProcKey(pid: l.0, startSec: start)
            let members = [root, ProcKey(pid: l.0 + 1, startSec: start), ProcKey(pid: l.0 + 2, startSec: start + 1)]
            for m in members { owner[m.pid] = .leftover(pgid: l.0, deadClaudePid: l.1) }
            let unit = LinkedUnit(root: root, pgid: l.0, command: l.2, argv: l.2.split(separator: " ").map(String.init),
                                  cwd: l.4, members: members, footprint: .mb(l.3))
            leftovers.append(LeftoverGroup(
                id: .leftover(pgid: l.0, leaderStartSec: start), unit: unit, deadClaudePid: l.1,
                sessionId: String(format: "dead%04x-0000-4000-8000-000000000000", i), sessionTitle: l.5, cwd: l.4,
                startedAt: Date(timeIntervalSince1970: TimeInterval(start))))
        }
        return ClaudeSnapshot(sessions: sessions, leftovers: leftovers,
                              staleFiles: [home + "/.claude/sessions/21630.json"])
    }
}
