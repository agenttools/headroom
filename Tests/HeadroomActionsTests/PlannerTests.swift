// Planner (§7.3): window expansion, locked skipping, every confirm trigger, and CloseFlow (⌥ / sheetMandatory).
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomActions

private let now = Date()
private let world = MockWorld.snapshot(now: now)
private let planner = Planner()

private func session(_ title: String) -> ClaudeSession { world.claude.sessions.first { $0.title == title }! }
private func tab(_ prefix: String) -> ChromeTab { world.chrome.tabs.first { $0.title.hasPrefix(prefix) }! }
private func reasons(_ id: ItemID, in plan: ClosePlan) -> [Reason] {
    plan.items.first { $0.id == id }?.protection.reasons ?? []
}
private func codes(_ p: Protection?) -> Set<String> { Set((p?.reasons ?? []).map(\.code)) }

@Suite struct PlannerLocked {
    @Test func launcherChromeCoreAndProcessesAreLocked() {
        let launcher = world.claude.sessions.first(where: \.isLauncher)!
        let clip = session("clip generation")
        let bg = clip.background[0].itemID
        let child = clip.children[0].itemID
        let overhead = ItemID.chromeOverhead(browserPid: MockWorld.mainBrowserPid, kind: "gpu")
        let other = ItemID.chromeOverhead(browserPid: MockWorld.mainBrowserPid, kind: "otherInstances")
        let normal = tab("Boston").itemID
        let plan = planner.plan([launcher.itemID, bg, child, overhead, other, normal], world, now: now)
        #expect(plan.items.map(\.id) == [normal])
        let locked = Dictionary(uniqueKeysWithValues: plan.locked.map { ($0.id, $0.reason) })
        #expect(locked[launcher.itemID] == .launcher)
        #expect(locked[overhead] == .chromeCore)
        #expect(locked[other] == .chromeCore)
        #expect(locked[bg] != nil && locked[child] != nil)
        #expect(!plan.needsSheet)
    }

    @Test func launcherByEnvPidAndAncestors() {
        let s = session("map directions")
        let p = Planner(launcherPids: [s.key.pid]).plan([s.itemID], world, now: now)
        #expect(p.items.isEmpty)
        #expect(p.locked.first?.reason == .launcher)
    }

    @Test func revalidationFailureLocksPidMismatch() {
        let s = session("map directions")
        let l = world.claude.leftovers[0]
        let dead = Planner(isAlive: { _ in false })
        let p = dead.plan([s.itemID, l.id], world, now: now)
        #expect(p.items.isEmpty)
        #expect(p.locked.allSatisfy { $0.reason == .pidMismatch })
        #expect(p.locked.count == 2)
    }

    @Test func vanishedRowsAreLocked() {
        let gone = ItemID.chromeTab(browserPid: MockWorld.mainBrowserPid, tabId: 999)
        let goneSession = ItemID.session(ProcKey(pid: 4242, startSec: 1))
        let p = planner.plan([gone, goneSession], world, now: now)
        #expect(p.items.isEmpty)
        #expect(Set(p.locked.map(\.id)) == [gone, goneSession])
    }
}

@Suite struct PlannerConfirmTriggers {
    let prot = planner.protections(world, now: now)

    @Test func sessionTriggers() {
        #expect(codes(prot[session("clip generation").itemID]).contains("busy"))
        #expect(codes(prot[session("managed agents").itemID]) == ["recentActivity"])
        #expect(codes(prot[session("weekly update skill").itemID]).isSuperset(of: ["visiblePane", "hasBackground"]))
        #expect(codes(prot[session("newsletter draft").itemID]) == ["notInTmux"])
        #expect(codes(prot[session("oakfield onboarding flow").itemID]) == ["hasBackground"])
        #expect(codes(prot[session("scratch").itemID]) == ["noTranscript"])
        #expect(codes(prot[session("old compass worktree").itemID]) == ["cwdMissing"])
        #expect(codes(prot[session("claude (no session file)").itemID]).contains("unregistered"))
        #expect(prot[session("map directions").itemID] == Protection.none)
    }

    @Test func unknownStatusCountsAsBusy() {
        let base = session("map directions")
        let unknown = ClaudeSession(key: base.key, sessionId: base.sessionId, cwd: base.cwd, title: "x", project: "p",
                                    status: "unknown", statusSince: base.statusSince, lastActivity: base.lastActivity,
                                    startedAt: base.startedAt, tmux: base.tmux, selfFootprint: 1)
        let p = planner.sessionProtection(unknown, now: now)
        #expect(p.reasons.contains { if case .busy(let s) = $0 { s == "status unknown" } else { false } })
    }

    @Test func tabTriggers() {
        #expect(codes(prot[tab("Swift concurrency").itemID]) == ["audible"])
        #expect(codes(prot[tab("Inbox").itemID]) == ["pinned"])
        #expect(prot[tab("Boston").itemID] == Protection.none)
    }

    @Test func leftoversAlwaysConfirm() {
        for l in world.claude.leftovers { #expect(codes(prot[l.id]) == ["leftover"]) }
    }

    @Test func emptiesWindowOverFiveTabs() {
        let win = world.chrome.windows.first { $0.tabIds.count > 5 }!
        let p = planner.plan([win.itemID], world, now: now)
        let n = win.tabIds.count
        for i in p.items { #expect(i.protection.reasons.contains(.emptiesWindow(n))) }
        #expect(p.needsSheet)
        // A window of ≤ 5 tabs empties without asking (unless something else applies).
        let small = world.chrome.windows.first { $0.tabIds.count <= 5 && !$0.incognito }!
        let q = planner.plan([small.itemID], world, now: now)
        #expect(!q.items.contains { $0.protection.reasons.contains { $0.code == "emptiesWindow" } })
    }

    @Test func closesAllNormalWindows() {
        let normal = world.chrome.windows.filter { !$0.incognito }
        let p = planner.plan(Set(normal.map(\.itemID)), world, now: now)
        #expect(p.items.allSatisfy { $0.protection.reasons.contains(.closesAllWindows) })
        // Leaving one tab open in one window removes the trigger.
        let keep = ItemID.chromeTab(browserPid: normal[0].browserPid, tabId: normal[0].tabIds[0])
        let sel = Set(normal.flatMap { w in w.tabIds.map { ItemID.chromeTab(browserPid: w.browserPid, tabId: $0) } })
            .subtracting([keep])
        let q = planner.plan(sel, world, now: now)
        #expect(!q.items.contains { $0.protection.reasons.contains(.closesAllWindows) })
    }

    @Test func manyItemsOverFifteen() {
        let ids = world.chrome.tabs.prefix(8).map(\.itemID) + world.claude.sessions.filter { !$0.isLauncher }.prefix(8).map(\.itemID)
        let p = planner.plan(Set(ids), world, now: now)
        #expect(p.items.count == 16)
        #expect(p.items.allSatisfy { $0.protection.reasons.contains(.manyItems) })
        let q = planner.plan(Set(ids.prefix(15)), world, now: now)
        #expect(!q.items.contains { $0.protection.reasons.contains(.manyItems) })
    }

    @Test func estimateUsesFreedForSharedRenderer() {
        let linear = world.chrome.tabs.filter { $0.host == "linear.app" }
        #expect(linear.count == 2)
        let one = planner.plan([linear[0].itemID], world, now: now)
        #expect(one.estimate == 0)                    // the other Linear tab keeps the renderer alive
        let both = planner.plan(Set(linear.map(\.itemID)), world, now: now)
        #expect(both.estimate == .mb(280))
    }

    @Test func skipBusyAndStopBackgroundChangeEstimate() {
        let busy = session("clip generation"), bg = session("oakfield onboarding flow")
        var p = planner.plan([busy.itemID, bg.itemID], world, now: now)
        #expect(PlanMath.busyCount(p) == 1)
        #expect(PlanMath.effectiveItems(p).map(\.id) == [bg.itemID])
        #expect(PlanMath.effectiveEstimate(p) == bg.total)
        p.stopBackground = false
        #expect(PlanMath.effectiveEstimate(p) == bg.total - bg.backgroundBytes)
        p.skipBusy = false
        #expect(PlanMath.effectiveItems(p).count == 2)
    }
}

@Suite struct CloseFlowDecisions {
    @Test func plainItemsExecuteAtOnce() {
        let p = planner.plan([tab("Boston").itemID], world, now: now)
        #expect(CloseFlow.decide(p, skipSheet: false) == .execute)
        #expect(CloseFlow.decide(p, skipSheet: true) == .execute)
    }

    @Test func confirmReasonShowsSheetButOptionSkipsIt() {
        let p = planner.plan([tab("Swift concurrency").itemID], world, now: now)
        #expect(p.needsSheet && !p.sheetMandatory)
        #expect(CloseFlow.decide(p, skipSheet: false) == .sheet(mandatoryNote: nil))
        #expect(CloseFlow.decide(p, skipSheet: true) == .execute)
    }

    @Test func sheetMandatoryHoldsUnderOption() {
        for id in [session("clip generation").itemID, world.claude.leftovers[0].id,
                   session("claude (no session file)").itemID] {
            let p = planner.plan([id, tab("Boston").itemID], world, now: now)
            #expect(p.sheetMandatory, "\(id)")
            guard case .sheet(let note) = CloseFlow.decide(p, skipSheet: true) else {
                Issue.record("⌥ skipped a mandatory sheet for \(id)"); continue
            }
            #expect(note != nil)
        }
    }

    @Test func lockedOnlySelectionDoesNothing() {
        let p = planner.plan([world.claude.sessions.first(where: \.isLauncher)!.itemID], world, now: now)
        #expect(CloseFlow.decide(p, skipSheet: false) == .nothing("1 selected row can't be closed"))
    }

    @Test func sheetButtonsWithBusy() {
        let p = planner.plan([session("clip generation").itemID, session("oakfield onboarding flow").itemID,
                              tab("Boston").itemID], world, now: now)
        let m = SheetModel(plan: p)
        #expect(m.title.hasPrefix("Close 3 items and free about"))
        #expect(m.buttons == [.cancel, .closeAll(3), .skipBusy(2)])
        #expect(m.defaultButton == .skipBusy(2))
        #expect(m.checkboxText?.contains("background") == true)
        #expect(m.backgroundUnits.count == 3)       // clip: 2 units, oakfield: 1
        let applied = SheetModel.apply(.closeAll(3), to: p, stopBackground: false)!
        #expect(!applied.skipBusy && !applied.stopBackground)
        #expect(SheetModel.apply(.cancel, to: p, stopBackground: true) == nil)
    }

    @Test func sheetButtonsWithoutBusy() {
        let p = planner.plan([tab("Swift concurrency").itemID, world.claude.leftovers[0].id], world, now: now)
        let m = SheetModel(plan: p, dryRun: true)
        #expect(m.buttons == [.cancel, .close(2)])
        #expect(m.defaultButton == .close(2))
        #expect(m.groups.map(\.heading) == ["Chrome tabs", "Leftovers"])
        #expect(m.footnote?.contains("cannot be undone") == true)
    }

    @Test func toastLines() {
        let t1 = ItemID.chromeTab(browserPid: 1, tabId: 1), t2 = ItemID.chromeTab(browserPid: 1, tabId: 2)
        let s = ItemID.session(ProcKey(pid: 5, startSec: 5)), l = ItemID.leftover(pgid: 9, leaderStartSec: 9)
        let recs = [ClosedRecord(batchId: "b", kind: "tab", itemId: t1.stringValue, closedAt: now, title: "a", bytes: 1, url: "https://a"),
                    ClosedRecord(batchId: "b", kind: "session", itemId: s.stringValue, closedAt: now, title: "s", bytes: 1, sessionId: "x"),
                    ClosedRecord(batchId: "b", kind: "leftover", itemId: l.stringValue, closedAt: now, title: "l", bytes: 1)]
        let m = ToastModel(records: recs, outcomes: [t1: .done, t2: .changedSkipped, s: .stillAlive, l: .done],
                           needsForce: [s], dryRun: false, baseline: 0)
        #expect(m.headline == "✓ Closed 1 tab, 1 session, 1 leftover · freeing…")
        #expect(m.lines.map(\.text) == ["1 tab changed since you selected it — skipped", "1 session didn't quit",
                                        "Leftovers stopped (not undoable)"])
        #expect(m.lines[1].action == .forceQuit([s]))
        #expect(m.undoable)
        var m2 = m; m2.measured(.gb(3.1))
        #expect(m2.headline.hasSuffix("3.10 GB freed (measured)"))
    }
}

@Suite struct Presets {
    let prot = planner.protections(world, now: now)

    @Test func idleSessionsExcludeProtected() {
        let ids = Set(SelectPreset.idleSessions(2 * 3600).ids(world, protections: prot, now: now))
        let titles = Set(world.claude.sessions.filter { ids.contains($0.itemID) }.map(\.title))
        #expect(titles.contains("map directions"))
        #expect(titles.contains("mutable-sprouting-bird"))
        for excluded in ["weekly update skill", "newsletter draft", "old compass worktree", "claude (no session file)",
                         "clip generation", "ram", "oakfield onboarding flow", "managed agents"] {
            #expect(!titles.contains(excluded), "\(excluded)")
        }
        // Everything returned closes without a sheet unless >15.
        #expect(!planner.plan(ids, world, now: now).needsSheet)
    }

    @Test func otherPresets() {
        #expect(SelectPreset.allLeftovers.ids(world, protections: prot, now: now).count == 3)
        let big = Set(SelectPreset.tabsOver(.mb(500)).ids(world, protections: prot, now: now))
        #expect(Set(world.chrome.tabs.filter { big.contains($0.itemID) }.map(\.host)) == ["www.figma.com", "claude.ai"])
        let dup = SelectPreset.duplicateTabs.ids(world, protections: prot, now: now)
        #expect(dup.isEmpty)
        let same = SelectPreset.sameSite([tab("ENG-412").itemID]).ids(world, protections: prot, now: now)
        #expect(same.count == 2)
        let bgw = SelectPreset.backgroundWindows.ids(world, protections: prot, now: now)
        let focused = world.chrome.windows.first(where: \.focused)!
        #expect(!bgw.isEmpty && !bgw.contains { if case let .chromeTab(_, t) = $0 { focused.tabIds.contains(t) } else { false } })
        #expect(SelectPreset.tmuxSession("oakfield-ledger").ids(world, protections: prot, now: now).count == 3)
    }
}
