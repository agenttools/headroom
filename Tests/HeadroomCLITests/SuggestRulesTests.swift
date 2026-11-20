// The `suggest` rules engine.
import Foundation
import Testing
@testable import HeadroomCLI
import HeadroomActions
import HeadroomContracts

private let now = Date()

private func run(_ w: WorldSnapshot, minBytes: Bytes = 0, planner: Planner = Planner()) -> [Suggestion] {
    SuggestRules().suggest(w, protections: planner.protections(w, now: now),
                           plan: { planner.plan($0, $1, now: now) }, minBytes: minBytes, now: now)
}

private func titles(_ s: [Suggestion], _ v: Verdict) -> Set<String> { Set(s.filter { $0.verdict == v }.compactMap(\.title)) }

// MARK: synthetic worlds

/// A Rex location in session "foundry" (tab 2, pane 1); `placed: false` is what discovery failure gives (visible).
private func rexLoc(_ pid: Int32, visible: Bool, placed: Bool = true) -> RexLoc {
    RexLoc(blockId: "block:0190bbbb-0000-7000-8000-\(String(format: "%012x", Int(pid)))",
           sessionId: "session:0190bbbb-0000-7000-8000-000000000001", sessionLabel: "foundry",
           windowId: placed ? "window:0190bbbb-0000-7000-8000-000000000002" : nil, windowLabel: placed ? "api" : nil,
           windowIndex: placed ? 2 : nil, paneIndex: placed ? 1 : nil, visible: visible)
}

private func session(_ pid: Int32, idleHours: Double, mb: Double = 300, tmux: Bool = true, busy: Bool = false,
                      visible: Bool = false, bg: Bool = false, status: String? = nil, transcript: Bool = true,
                      rex: RexLoc? = nil) -> ClaudeSession {
    let key = ProcKey(pid: pid, startSec: 1_700_000_000 + Int(pid))
    let last = now.addingTimeInterval(-idleHours * 3600)
    let unit = LinkedUnit(root: ProcKey(pid: pid + 1, startSec: key.startSec), pgid: pid + 1, command: "bun run dev",
                          members: [ProcKey(pid: pid + 1, startSec: key.startSec)], footprint: .mb(100))
    return ClaudeSession(
        key: key, sessionId: "s\(pid)", cwd: "/tmp/p\(pid)", title: "s\(pid)", project: "p", hasTranscript: transcript,
        busy: busy, status: status ?? (busy ? "busy" : "idle"), statusSince: last, lastActivity: last,
        startedAt: last.addingTimeInterval(-600),
        tmux: tmux ? TmuxLoc(paneId: "%\(pid)", session: "t", windowName: "w", windowIndex: Int(pid % 100), paneIndex: 0,
                             visible: visible, current: visible) : nil,
        rex: rex, selfFootprint: .mb(mb), background: bg ? [unit] : [])
}

private func tab(_ id: Int, win: Int, idx: Int, minutesAgo: Double, mb: Double?, active: Bool = false,
                 audible: Bool = false, pinned: Bool = false, incognito: Bool = false, discarded: Bool = false) -> ChromeTab {
    ChromeTab(browserPid: 1, id: id, windowId: win, index: idx, title: "t\(id)", url: "https://e.com/\(id)", host: "e.com",
              active: active, audible: audible, pinned: pinned, discarded: discarded, incognito: incognito,
              lastAccessed: now.addingTimeInterval(-minutesAgo * 60), display: mb.map { .mb($0) }, exclusive: mb.map { .mb($0) } ?? 0)
}

private func world(sessions: [ClaudeSession] = [], tabs: [ChromeTab] = [], leftovers: [LeftoverGroup] = []) -> WorldSnapshot {
    var wins: [Int: ChromeWindow] = [:]
    for t in tabs.sorted(by: { $0.index < $1.index }) {
        wins[t.windowId, default: ChromeWindow(browserPid: 1, id: t.windowId, incognito: t.incognito)].tabIds.append(t.id)
    }
    let chrome = ChromeSnapshot(source: .helper(profiles: 1), windows: wins.values.sorted { $0.id < $1.id }, tabs: tabs)
    return WorldSnapshot(system: .zero, chrome: chrome, claude: ClaudeSnapshot(sessions: sessions, leftovers: leftovers),
                         ownership: .empty, selfBytes: 0, at: now)
}

@Suite struct SuggestRulesMockTests {
    let s = run(MockWorld.snapshot(now: now))

    @Test func safeSessionsAreIdleQuietAndInTmux() {
        #expect(titles(s, .safe).isSuperset(of: [
            "map directions", "mutable-sprouting-bird", "oakfield copy review", "quote import pipeline",
            "pricing page tweaks", "hammer-47", "hammer-bb", "plant watch", "digest steward",
        ]))
    }

    @Test func safeTabsAreUnusedOrHeavyAndPlain() {
        let safeTabs = Set(s.filter { $0.verdict == .safe && $0.id.kind == .tab }.compactMap(\.title))
        #expect(safeTabs == [
            "Boston to Cambridge – Google Maps", "tour landing – localhost:3217", "mock.html",
            "quote-composer – Deployments – Vercel", "Fix ledger rounding #212 – GitHub", "Q4 plan – Notion",
        ])
    }

    @Test func confirmHoldsLeftoversAndSessionsTheAppWouldAskAbout() {
        #expect(titles(s, .confirm) == ["newsletter draft", "old compass worktree", "tour landing", "compass onboarding", "budget wt"])
        for l in s where l.id.kind == .leftover { #expect(l.verdict == .confirm && l.reason.contains("cannot be undone")) }
        let draft = s.first { $0.title == "newsletter draft" }!
        #expect(draft.reason.contains("not in tmux"))
    }

    @Test func neverSuggestsBusyVisibleBackgroundLauncherLockedActiveAudiblePinnedIncognitoOrAsleep() {
        let never: Set<String> = [
            "clip generation", "workflow ideas for ops", "ram", "oakfield ledger sync",   // busy / launcher
            "weekly update skill", "oakfield onboarding flow",                            // visible pane / background
            "managed agents", "scratch", "claude (no session file)",                        // idle < 2 h
            "Headroom design review – Claude", "Swift concurrency deep dive – YouTube",    // active / audible
            "Inbox (3) – me@example.com – Mail", "Private tab", "Webhooks | Stripe Documentation", // pinned / incognito / asleep
            "ENG-412 Ledger sync – Linear", "My issues – Linear",                           // < 1 h and light
        ]
        #expect(Set(s.compactMap(\.title)).isDisjoint(with: never))
        let prot = Planner().protections(MockWorld.snapshot(now: now), now: now)
        for x in s { #expect(prot[x.id]?.isLocked != true) }
        #expect(!s.contains { $0.verdict == .keep })
    }

    /// The mock Rex rows are busy, visible or idle under 2 h, so suggest output is the same as without them.
    @Test func mockRexSessionsAreNotCandidates() {
        #expect(Set(s.compactMap(\.title)).isDisjoint(with: ["rex release notes", "rex docs pass", "rex billing spike"]))
        #expect(!s.contains { $0.reason.contains("Undo resumes it in Rex") })
        let draft = s.first { $0.title == "newsletter draft" }!
        #expect(draft.reason.contains("not in tmux or Rex"))
    }

    @Test func safeItemsAreExactlyWhatCloseAcceptsWithoutForce() {
        let safe = Set(s.filter { $0.verdict == .safe }.map(\.id))
        #expect(safe.count == 15)
        let plan = Planner().plan(safe, MockWorld.snapshot(now: now), now: now)
        #expect(plan.locked.isEmpty)
        #expect(!plan.needsSheet)
    }

    @Test func rankedSafeThenConfirmBySize() {
        let verdicts = s.map(\.verdict)
        #expect(verdicts == verdicts.sorted { ($0 == .safe ? 0 : 1) < ($1 == .safe ? 0 : 1) })
        let safe = s.filter { $0.verdict == .safe }.map(\.bytes)
        #expect(safe == safe.sorted(by: >))
        #expect(s.first { $0.verdict == .confirm }?.title == "tour landing")   // 1.2 GB leftover leads confirm
    }

    @Test func reportHasCloseCommandForSafeOnly() {
        let r = SuggestReport(generatedAt: now, suggestions: s)
        let cmd = try! #require(r.closeCommand)
        #expect(cmd.hasPrefix("headroom close "))
        #expect(!cmd.contains("leftover:"))
        #expect(r.safeBytes == s.filter { $0.verdict == .safe }.reduce(0) { $0 + $1.bytes })
    }

    @Test func minMBDropsSmallCandidates() {
        let big = run(MockWorld.snapshot(now: now), minBytes: .mb(350))
        #expect(!big.isEmpty)
        #expect(big.allSatisfy { $0.bytes >= .mb(350) })
        #expect(titles(big, .safe).contains("map directions"))
        #expect(!titles(big, .safe).contains("plant watch"))
    }
}

@Suite struct SuggestRulesSyntheticTests {
    @Test func sessionThresholdIsTwoHours() {
        let s = run(world(sessions: [session(100, idleHours: 1.9), session(200, idleHours: 2.1)]))
        #expect(s.map(\.title) == ["s200"])
        #expect(s[0].verdict == .safe)
    }

    @Test func busyUnknownVisibleAndBackgroundSessionsAreSkipped() {
        let s = run(world(sessions: [
            session(100, idleHours: 5, busy: true), session(200, idleHours: 5, status: "unknown"),
            session(300, idleHours: 5, visible: true), session(400, idleHours: 5, bg: true),
            session(500, idleHours: 5),
        ]))
        #expect(s.map(\.title) == ["s500"])
    }

    @Test func notInTmuxOrNoTranscriptBecomesConfirm() {
        let s = run(world(sessions: [session(100, idleHours: 5, tmux: false), session(200, idleHours: 5, transcript: false)]))
        #expect(s.allSatisfy { $0.verdict == .confirm })
        #expect(s.count == 2)
    }

    @Test func hiddenRexSessionIsSafeAndUndoResumesItInRex() {
        let s = run(world(sessions: [session(100, idleHours: 5, tmux: false, rex: rexLoc(100, visible: false)),
                                     session(200, idleHours: 5)]))
        #expect(s.count == 2)
        #expect(s.allSatisfy { $0.verdict == .safe })
        let rex = s.first { $0.title == "s100" }!
        #expect(rex.reason.contains("not on screen"))
        #expect(!rex.reason.contains("not in tmux"))
        #expect(rex.reason.hasSuffix("; Undo resumes it in Rex"))
        #expect(s.first { $0.title == "s200" }!.reason.hasSuffix("; Undo resumes it in tmux"))
    }

    /// Visible Rex panes, and Rex panes Headroom could not place (fail-closed: visible), are never suggested.
    @Test func visibleOrUnplacedRexSessionsAreSkipped() {
        let s = run(world(sessions: [
            session(100, idleHours: 5, tmux: false, rex: rexLoc(100, visible: true)),
            session(200, idleHours: 5, tmux: false, rex: rexLoc(200, visible: true, placed: false)),
            session(300, idleHours: 5, tmux: false, rex: rexLoc(300, visible: false)),
        ]))
        #expect(s.map(\.title) == ["s300"])
    }

    @Test func sessionInNeitherMultiplexerSaysSo() {
        let s = run(world(sessions: [session(100, idleHours: 5, tmux: false)]))
        #expect(s.count == 1 && s[0].verdict == .confirm)
        #expect(s[0].reason.hasPrefix("idle 5h, not busy, not in tmux or Rex, no background processes; asks first: "))
        #expect(s[0].reason.contains("not in tmux or Rex (Undo cannot put it back where it ran)"))
    }

    @Test func launcherIsNeverSuggested() {
        let p = Planner(launcherPids: [100])
        #expect(run(world(sessions: [session(100, idleHours: 9)]), planner: p).isEmpty)
    }

    @Test func tabRules() {
        let s = run(world(tabs: [
            tab(1, win: 1, idx: 0, minutesAgo: 0, mb: 50, active: true),
            tab(2, win: 1, idx: 1, minutesAgo: 30, mb: 299),        // light and recent → no
            tab(3, win: 1, idx: 2, minutesAgo: 30, mb: 300),        // heavy → safe
            tab(4, win: 1, idx: 3, minutesAgo: 61, mb: 10),         // unused → safe
            tab(5, win: 1, idx: 4, minutesAgo: 600, mb: 500, audible: true),
            tab(6, win: 1, idx: 5, minutesAgo: 600, mb: 500, pinned: true),
            tab(7, win: 1, idx: 6, minutesAgo: 600, mb: 0, discarded: true),
            tab(8, win: 2, idx: 0, minutesAgo: 600, mb: 500, incognito: true),
            tab(9, win: 1, idx: 7, minutesAgo: 90, mb: nil),        // unknown memory, unused → safe
        ]))
        #expect(Set(s.map(\.title)) == ["t3", "t4", "t9"])
        #expect(s.allSatisfy { $0.verdict == .safe })
        #expect(s.first { $0.title == "t9" }!.reason.contains("memory unknown"))
        // --min-mb drops unknown-size tabs.
        let big = SuggestRules().suggest(world(tabs: [tab(9, win: 1, idx: 0, minutesAgo: 90, mb: nil),
                                                      tab(1, win: 1, idx: 1, minutesAgo: 0, mb: 5, active: true)]),
                                         protections: [:], plan: { Planner().plan($0, $1, now: now) },
                                         minBytes: .mb(1), now: now)
        #expect(big.isEmpty)
    }

    @Test func emptyingABigWindowOrEveryWindowDowngradesToConfirm() {
        // Window 1: 6 unused tabs (would be emptied); window 2: an active tab, so not every window closes.
        var tabs = (0..<6).map { tab(10 + $0, win: 1, idx: $0, minutesAgo: 120, mb: 100) }
        tabs.append(tab(99, win: 2, idx: 0, minutesAgo: 0, mb: 100, active: true))
        let s = run(world(tabs: tabs))
        #expect(s.count == 6)
        #expect(s.allSatisfy { $0.verdict == .confirm && $0.reason.contains("closes a whole window of 6 tabs") })

        // A single normal window whose only candidates would all close → closesAllWindows.
        let only = run(world(tabs: [tab(1, win: 1, idx: 0, minutesAgo: 120, mb: 100)]))
        #expect(only.first?.verdict == .confirm)
        #expect(only.first?.reason.contains("every normal Chrome window") == true)
    }

    @Test func safeBatchIsCappedAtFifteen() {
        let sessions = (0..<20).map { session(Int32(1000 + $0 * 10), idleHours: 3, mb: Double(200 + $0)) }
        let s = run(world(sessions: sessions))
        #expect(s.filter { $0.verdict == .safe }.count == 15)
        let over = s.filter { $0.verdict == .confirm }
        #expect(over.count == 5)
        #expect(over.allSatisfy { $0.reason.contains("15-item batch") })
        // The 15 largest stay safe.
        let safeMin = s.filter { $0.verdict == .safe }.map(\.bytes).min()!
        #expect(over.allSatisfy { $0.bytes < safeMin })
        let plan = Planner().plan(Set(s.filter { $0.verdict == .safe }.map(\.id)), world(sessions: sessions), now: now)
        #expect(!plan.needsSheet)
    }

    @Test func emptyWorldSuggestsNothing() {
        #expect(run(world()).isEmpty)
        #expect(SuggestReport(generatedAt: now, suggestions: []).closeCommand == nil)
    }
}
