// `close` and `undo` end to end on the mock context (MockExecutor never touches a process or Chrome).
import Foundation
import Testing
@testable import HeadroomCLI
import HeadroomActions
import HeadroomContracts

private let w = MockWorld.snapshot()
private func sid(_ title: String) -> String { w.claude.sessions.first { $0.title == title }!.itemID.stringValue }
private func tid(_ prefix: String) -> String { w.chrome.tabs.first { $0.title.hasPrefix(prefix) }!.itemID.stringValue }
private let leftover = w.claude.leftovers[0].id.stringValue

private func present(_ h: Harness, _ id: String) async -> Bool {
    let s = await h.ctx.world.snapshot()
    let ids = Set(s.chrome.tabs.map(\.itemID.stringValue) + s.claude.sessions.map(\.itemID.stringValue)
                  + s.claude.leftovers.map(\.id.stringValue))
    return ids.contains(id)
}

@Suite struct CloseRefusalTests {
    @Test func confirmItemsAreRefusedWithoutForceConfirm() async {
        let h = Harness()
        for id in [leftover, sid("clip generation"), sid("newsletter draft"), tid("Inbox"), tid("Swift concurrency")] {
            let (code, io) = await h.run(["close", "--yes", id])
            #expect(code == 2, "\(id)")
            #expect(io.stderr.contains("need") && io.stderr.contains("--force-confirm"))
            #expect(await present(h, id))
        }
    }

    @Test func lockedItemsAreAlwaysRefusedEvenWithForce() async {
        let h = Harness()
        let locked = [sid("ram"), "overhead:\(MockWorld.mainBrowserPid):gpu",
                      w.claude.sessions.first { $0.title == "clip generation" }!.background[0].itemID.stringValue]
        for id in locked {
            let (code, io) = await h.run(["close", "--yes", "--force-confirm", id])
            #expect(code == 2, "\(id)")
            #expect(io.stderr.contains("can't be closed"))
        }
        #expect(await present(h, sid("ram")))
    }

    @Test func oneBadIdRefusesTheWholeBatch() async {
        let h = Harness()
        let good = sid("map directions")
        let (code, io) = await h.run(["close", "--yes", good, "tab:812:4242"])
        #expect(code == 2)
        #expect(io.stderr.contains("not found"))
        #expect(await present(h, good))
    }

    @Test func nonTTYWithoutYesPrintsPlanAndExitsTwo() async {
        let h = Harness()
        let id = sid("map directions")
        let (code, io) = await h.run(["close", id])
        #expect(code == 2)
        #expect(io.stdout.contains("Close 1 item and free about"))
        #expect(io.stderr.contains("--yes"))
        #expect(await present(h, id))
    }

    @Test func ttyAnswerNoCancels() async {
        let h = Harness()
        let id = tid("Q4 plan")
        let (code, io) = await h.run(["close", id], tty: true, answers: ["n"])
        #expect(code == 2)
        #expect(io.stderr.contains("[y/N]"))
        #expect(io.stderr.contains("Cancelled"))
        #expect(await present(h, id))
    }

    @Test func explicitDryRunIsAPreviewWithoutPrompt() async {
        let (code, io) = await Harness().run(["close", "--dry-run", sid("map directions")])
        #expect(code == 0)
        #expect(!io.stderr.contains("[y/N]"))
        #expect(io.stdout.contains("Dry run"))
    }

    @Test func dryRunStillRefusesConfirmItems() async {
        #expect(await Harness().run(["close", "--dry-run", leftover]).code == 2)
    }

    @Test func jsonRefusalCarriesPlanAndReasons() async throws {
        let (code, r) = try await Harness().json(CloseResultJSON.self, ["close", "--json", "--yes", leftover])
        #expect(code == 2)
        #expect(r.status == "needsConfirmation")
        #expect(r.plan.items.first?.reasons.map(\.code) == ["leftover"])
        #expect(r.results.isEmpty)
    }
}

@Suite struct CloseAndUndoFlowTests {
    @Test func ttyYesClosesThenUndoRestores() async {
        let h = Harness()
        let a = sid("map directions"), b = tid("Q4 plan")
        let (code, io) = await h.run(["close", a, b], tty: true, answers: ["y"])
        #expect(code == 0)
        #expect(io.stdout.contains("Dry run: would close 1 tab, 1 session") || io.stdout.contains("would close"))
        #expect(await !present(h, a))
        #expect(await !present(h, b))

        let (ucode, uio) = await h.run(["undo", "--last"])
        #expect(ucode == 0)
        #expect(uio.stdout.contains("2 of 2 items"))
        #expect(await present(h, a))
        #expect(await present(h, b))
    }

    @Test func suggestedSafeCommandRunsWithoutForce() async throws {
        let h = Harness()
        let (_, report) = try await h.json(SuggestReport.self, ["suggest", "--json"])
        let ids = report.suggestions.filter { $0.verdict == .safe }.map(\.id.stringValue)
        #expect(ids.count == 15)
        let (code, r) = try await h.json(CloseResultJSON.self, ["close", "--json", "--yes"] + ids)
        #expect(code == 0)
        #expect(r.status == "closed")
        #expect(r.results.count == 15)
        #expect(r.results.allSatisfy { $0.outcome == "dryRun" })
        #expect(r.dryRun)
        for id in ids { #expect(await !present(h, id)) }
    }

    @Test func forceConfirmClosesLeftoverAndItCannotBeUndone() async {
        let h = Harness()
        let (code, io) = await h.run(["close", "--yes", "--force-confirm", leftover])
        #expect(code == 0, "\(io.stderr)")
        #expect(io.stdout.contains("Leftovers cannot be undone"))
        #expect(await !present(h, leftover))
        let (ucode, uio) = await h.run(["undo", leftover])
        #expect(ucode == 1)
        #expect(uio.stderr.contains("cannot be undone"))
        let (lcode, lio) = await h.run(["undo"])             // --last skips the unrestorable batch
        #expect(lcode == 1 && lio.stderr.contains("Nothing to undo"))
    }

    /// Review finding: --force-confirm (and suggest's confirmCommand) must not close a busy session mid-turn.
    @Test func forceConfirmRefusesBusyWithoutIncludeBusy() async {
        let h = Harness()
        let busy = sid("oakfield ledger sync")
        let (code, io) = await h.run(["close", "--yes", "--force-confirm", busy])
        #expect(code == 2)
        #expect(io.stderr.contains("busy"))
        #expect(await present(h, busy))
        let (code2, _) = await h.run(["close", "--yes", "--force-confirm", "--include-busy", busy])
        #expect(code2 == 0)
        #expect(await !present(h, busy))
    }

    @Test func listAndSuggestRejectStrayArguments() async {
        let h = Harness()
        let (c1, io1) = await h.run(["list", "--json", "sessions"])
        #expect(c1 == 1 && io1.stderr.contains("unexpected argument sessions"))
        let (c2, io2) = await h.run(["suggest", "500"])
        #expect(c2 == 1 && io2.stderr.contains("unexpected argument 500"))
    }

    @Test func windowIdExpandsToItsTabs() async throws {
        let h = Harness()
        let win = w.chrome.windows.first { $0.tabIds.count == 2 }!      // Calendar (active) + Notion
        let (code, r) = try await h.json(CloseResultJSON.self, ["close", "--json", "--yes", win.itemID.stringValue])
        #expect(code == 0)
        #expect(r.plan.items.count == 2)
        #expect(Set(r.plan.items.map(\.kind)) == ["tab"])
    }

    @Test func undoByItemIdAndPrefixAndList() async throws {
        let h = Harness()
        let a = sid("plant watch"), b = sid("digest steward")
        _ = await h.run(["close", "--yes", a])
        _ = await h.run(["close", "--yes", b])
        let (_, list) = try await h.json(RecentJSON.self, ["undo", "--list", "--json"])
        #expect(list.records.map(\.itemId) == [b, a])
        #expect(list.records[0].kind == "session" && list.records[0].sessionId != nil)
        // By item id.
        let (c1, _) = await h.run(["undo", a])
        #expect(c1 == 0)
        #expect(await present(h, a))
        // By unique record-id prefix.
        let rec = list.records.first { $0.itemId == b }!
        let (c2, _) = await h.run(["undo", String(rec.id.prefix(8))])
        #expect(c2 == 0)
        #expect(await present(h, b))
        // Unknown.
        let (c3, io3) = await h.run(["undo", "zzzzzzzz"])
        #expect(c3 == 1 && io3.stderr.contains("No Recently Closed record"))
        #expect(await h.run(["undo", "--last", a]).code == 1)
    }

    /// A visible Rex pane asks first, exactly like a visible tmux pane.
    @Test func visibleRexSessionIsRefusedWithoutForceConfirm() async throws {
        let h = Harness()
        let docs = "session:43037:1790691540"                       // rex docs pass (visible)
        #expect(sid("rex docs pass") == docs)
        let (code, io) = await h.run(["close", "--yes", docs])
        #expect(code == 2)
        #expect(io.stderr.contains("visible or current tmux pane, or visible Rex pane"))
        #expect(io.stderr.contains("--force-confirm"))
        #expect(await present(h, docs))
        let (jcode, r) = try await h.json(CloseResultJSON.self, ["close", "--json", "--yes", docs])
        #expect(jcode == 2 && r.status == "needsConfirmation")
        #expect(r.plan.items.first?.reasons.map(\.code) == ["visiblePane"])
    }

    /// The Rex session id and label go into Recently Closed, so Undo reopens it in that Rex session.
    @Test func closedRexSessionRecordsItsRexSession() async throws {
        let h = Harness()
        let spike = "session:43134:1790694480"                      // rex billing spike (hidden tab, no protection)
        #expect(sid("rex billing spike") == spike)
        let (code, r) = try await h.json(CloseResultJSON.self, ["close", "--json", "--yes", spike])
        #expect(code == 0 && r.status == "closed")
        #expect(r.records.isEmpty)                                  // dry run: records are not written
        let (_, list) = try await h.json(RecentJSON.self, ["undo", "--list", "--json"])
        let rec = try #require(list.records.first { $0.itemId == spike })
        #expect(rec.kind == "session")
        #expect(rec.rexSessionId == "session:0190aaaa-0000-7000-8000-000000000002")
        #expect(rec.rexSessionLabel == "studio")
        #expect(rec.tmuxSession == nil)
        // The raw JSON carries the new keys; a tmux record keeps tmuxSession and has no rex keys.
        _ = await h.run(["close", "--yes", sid("plant watch")])
        let (_, io) = await h.run(["undo", "--list", "--json"])
        let root = try #require(try JSONSerialization.jsonObject(with: Data(io.stdout.utf8)) as? [String: Any])
        let raw = try #require(root["records"] as? [[String: Any]])
        let rawSpike = try #require(raw.first { $0["itemId"] as? String == spike })
        #expect(rawSpike["rexSessionId"] as? String == "session:0190aaaa-0000-7000-8000-000000000002")
        #expect(rawSpike["rexSessionLabel"] as? String == "studio")
        let rawPlant = try #require(raw.first { $0["itemId"] as? String == sid("plant watch") })
        #expect(rawPlant["tmuxSession"] as? String == "misc")
        #expect(rawPlant["rexSessionId"] == nil && rawPlant["rexSessionLabel"] == nil)
        // Undo (dry run) restores it.
        let (ucode, uio) = await h.run(["undo", spike])
        #expect(ucode == 0)
        #expect(uio.stdout.contains("1 of 1 item"))
        #expect(await present(h, spike))
    }

    @Test func emptyRecentlyClosed() async {
        let (code, io) = await Harness().run(["undo"])
        #expect(code == 1)
        #expect(io.stderr.contains("Recently Closed is empty"))
        let (lc, lio) = await Harness().run(["undo", "--list"])
        #expect(lc == 0 && lio.stdout.contains("empty"))
    }
}
