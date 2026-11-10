// Close and undo on the mock context, and window-row expansion.
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomActions

@Suite struct MockFlow {
    @Test func closeThenUndoInMock() async {
        let ctx = Headroom.mock(env: HeadroomEnv(environment: ["HOME": "/nonexistent", "HEADROOM_DRY_RUN": "1"]))
        let w = await ctx.world.snapshot()
        let prot = ctx.executor.protections(w)
        let tab = w.chrome.tabs.first { !$0.pinned && !$0.audible && !$0.active }!
        let launcher = w.claude.sessions.first(where: \.isLauncher)!
        #expect(prot[launcher.itemID]?.isLocked == true)
        let plan = ctx.executor.plan([tab.itemID, launcher.itemID], w)
        #expect(plan.items.map(\.id) == [tab.itemID])
        #expect(plan.locked.map(\.id) == [launcher.itemID])
        var records: [ClosedRecord] = []
        for await ev in ctx.executor.execute(plan) { if case .finished(let r) = ev { records = r } }
        #expect(records.count == 1)
        #expect(await ctx.world.snapshot().chrome.tabs.contains { $0.itemID == tab.itemID } == false)
        _ = await ctx.executor.undo(records)
        #expect(await ctx.world.snapshot().chrome.tabs.contains { $0.itemID == tab.itemID })
    }

    @Test func windowRowsExpand() async {
        let ctx = Headroom.mock()
        let w = await ctx.world.snapshot()
        let win = w.chrome.windows.first { $0.tabIds.count > 3 }!
        let plan = ctx.executor.plan([win.itemID], w)
        #expect(plan.items.count == win.tabIds.count)
        #expect(Set(plan.items.map(\.id)) == Set(win.tabIds.map { ItemID.chromeTab(browserPid: win.browserPid, tabId: $0) }))
        // Selecting the window and one of its tabs does not double count.
        let both = ctx.executor.plan([win.itemID, .chromeTab(browserPid: win.browserPid, tabId: win.tabIds[0])], w)
        #expect(both.items.count == win.tabIds.count)
    }
}
