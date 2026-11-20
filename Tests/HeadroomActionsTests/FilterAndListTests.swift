// Filter parser (§7.5) and ListModel (rows, sort, sort freeze, brackets).
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomActions

@Suite struct FilterParser {
    @Test func tokens() {
        typealias T = FilterQuery.Token
        #expect(FilterQuery(">500mb").tokens == [T.bytes(.gt, .mb(500))])
        #expect(FilterQuery("<100MB").tokens == [T.bytes(.lt, .mb(100))])
        #expect(FilterQuery(">1.5gb").tokens == [T.bytes(.gt, .gb(1.5))])
        #expect(FilterQuery("idle>2h").tokens == [T.idle(.gt, 7200)])
        #expect(FilterQuery("idle<10m").tokens == [T.idle(.lt, 600)])
        #expect(FilterQuery("idle>1d").tokens == [T.idle(.gt, 86_400)])
        #expect(FilterQuery("busy !busy").tokens == [T.busy, T.not(.busy)])
        #expect(FilterQuery("is:tab is:session is:leftover").tokens == [T.kind(.tab), T.kind(.session), T.kind(.leftover)])
        #expect(FilterQuery("site:linear.app tmux:hub").tokens == [T.site("linear.app"), T.tmux("hub")])
        #expect(FilterQuery("bg shared sleeping").tokens == [T.background, T.shared, T.sleeping])
        #expect(FilterQuery("Ledger  sync").tokens == [T.word("ledger"), T.word("sync")])
        #expect(FilterQuery("\"ledger sync\" !figma").tokens == [T.word("ledger sync"), T.not(.word("figma"))])
        // Malformed tokens fall back to words.
        #expect(FilterQuery(">lots idle>soon is:dog").tokens == [T.word(">lots"), T.word("idle>soon"), T.word("is:dog")])
        #expect(FilterQuery("   ").isEmpty)
    }

    @Test func matching() {
        let now = Date()
        let w = MockWorld.snapshot(now: now)
        func matching(_ q: String) -> Set<String> {
            let f = FilterQuery(q)
            var out: Set<String> = []
            for t in w.chrome.tabs where f.matches(FilterSubject(tab: t, now: now)) { out.insert(t.title) }
            for s in w.claude.sessions where f.matches(FilterSubject(session: s, now: now)) { out.insert(s.title) }
            for l in w.claude.leftovers where f.matches(FilterSubject(leftover: l, now: now)) { out.insert(l.unit.command) }
            return out
        }
        #expect(matching("site:linear.app") == ["ENG-412 Ledger sync – Linear", "My issues – Linear"])
        #expect(matching("shared") == matching("site:linear.app"))
        #expect(matching("sleeping") == ["Webhooks | Stripe Documentation"])
        #expect(matching("is:leftover").count == 3)
        #expect(matching("is:session busy").count == w.claude.sessions.filter(\.busy).count)
        #expect(matching("tmux:oakfield-ledger").count == 3)
        #expect(matching("bg") == ["clip generation", "weekly update skill", "oakfield onboarding flow"])
        let sweep = matching("is:session idle>2h !busy")
        #expect(sweep.contains("map directions") && !sweep.contains("managed agents") && !sweep.contains("clip generation"))
        #expect(matching(">1gb") == ["bun run dev --port 3217", "clip generation", "oakfield onboarding flow"])
        #expect(matching("ledger").isSuperset(of: ["ENG-412 Ledger sync – Linear", "oakfield ledger sync"]))
        #expect(matching("ledger is:tab") == ["ENG-412 Ledger sync – Linear", "Fix ledger rounding #212 – GitHub"])
        #expect(!matching("!site:linear.app").contains("My issues – Linear"))
        #expect(matching("!site:linear.app").contains("map directions"))
    }
}

@Suite struct ListModelTests {
    let now = Date()
    var world: WorldSnapshot { MockWorld.snapshot(now: now) }
    var prot: [ItemID: Protection] { Planner().protections(world, now: now) }

    @Test func sectionsAndGroupRows() {
        let rows = ListModel.build(world, protections: prot, options: ListOptions(), now: now)
        #expect(rows.map(\.title) == ["CHROME", "CLAUDE CODE", "LEFTOVERS", "DOCKER"])
        #expect(rows.allSatisfy { !$0.selectable && $0.kind == .section })
        let chrome = rows[0]
        #expect(chrome.bytes == world.chrome.total)
        #expect(chrome.children.filter { $0.kind == .window }.count == 4)
        let itself = chrome.children.last!
        #expect(itself.kind == .chromeItself && itself.isLocked)
        #expect(itself.children.contains { $0.title == "Other Chrome instances" && $0.location.contains("pw-profile-3") })
        // Every tab and session appears once.
        let idx = ListModel.index(rows)
        #expect(world.chrome.tabs.allSatisfy { idx[$0.itemID.stringValue] != nil })
        #expect(world.claude.sessions.allSatisfy { idx[$0.itemID.stringValue] != nil })
        // Windows sorted by memory desc, tabs within windows too.
        let win = chrome.children.first { $0.kind == .window }!
        let bytes = win.children.map { $0.bytes ?? 0 }
        #expect(bytes == bytes.sorted(by: >))
        // The launcher session is locked and badged.
        let launcher = idx[world.claude.sessions.first(where: \.isLauncher)!.itemID.stringValue]!
        #expect(launcher.isLocked && launcher.badge == "launched Headroom")
    }

    @Test func scopeAndFilter() {
        var o = ListOptions(scope: .chrome)
        #expect(ListModel.build(world, protections: prot, options: o, now: now).map(\.title) == ["CHROME"])
        o.scope = .claude
        #expect(ListModel.build(world, protections: prot, options: o, now: now).map(\.title) == ["CLAUDE CODE", "LEFTOVERS"])
        o = ListOptions(filter: "site:linear.app")
        let rows = ListModel.build(world, protections: prot, options: o, now: now)
        let windows = rows[0].children.filter { $0.kind == .window }
        #expect(windows.count == 1 && windows[0].children.count == 2)
        #expect(rows[1].children.map(\.kind) == [.note])       // "No sessions match"
        #expect(rows[1].children[0].note == .noMatches)
    }

    @Test func kindTokenHidesOtherSections() {
        let rows = ListModel.build(world, protections: prot, options: ListOptions(filter: "idle>2h !busy is:session"), now: now)
        #expect(rows.map(\.title) == ["CLAUDE CODE"])
        #expect(rows[0].children.allSatisfy { $0.kind == .session })
        let tabsOnly = ListModel.build(world, protections: prot, options: ListOptions(filter: "is:tab >500mb"), now: now)
        #expect(tabsOnly.map(\.title) == ["CHROME"])
    }

    @Test func sharedRendererBracket() {
        let rows = ListModel.build(world, protections: prot, options: ListOptions(), now: now)
        let win = rows[0].children.first { $0.children.contains { $0.location == "linear.app" } }!
        let linear = win.children.filter { $0.location == "linear.app" }
        #expect(linear.map(\.bracket) == [.top, .bottom])
        #expect(linear.allSatisfy { $0.approx && $0.glyphs.contains(.shared(2)) })
    }

    @Test func tmuxGrouping() {
        let rows = ListModel.build(world, protections: prot, options: ListOptions(claudeGrouping: .tmux), now: now)
        let groups = rows[1].children
        #expect(groups.allSatisfy { $0.kind == .subgroup && !$0.selectable })
        #expect(groups.last?.title == "Not in tmux or Rex")
        #expect(groups.reduce(0) { $0 + $1.children.count } == world.claude.sessions.count)
    }

    @Test func sortFreezeKeepsOrderWhileNumbersChange() {
        let o = ListOptions()
        let before = ListModel.build(world, protections: prot, options: o, now: now)
        let order = ListModel.order(of: before)
        // Make the smallest session the biggest: a fresh sort would move it to the top.
        let smallest = world.claude.sessions.min { $0.total < $1.total }!
        var claude = world.claude
        let i = claude.sessions.firstIndex { $0.key == smallest.key }!
        let s = claude.sessions[i]
        claude.sessions[i] = ClaudeSession(key: s.key, sessionId: s.sessionId, cwd: s.cwd, title: s.title, project: s.project,
                                           startedAt: s.startedAt, tmux: s.tmux, selfFootprint: .gb(9))
        let w2 = WorldSnapshot(system: world.system, chrome: world.chrome, claude: claude, ownership: world.ownership,
                               selfBytes: 0, at: now, docker: world.docker)
        let fresh = ListModel.build(w2, protections: prot, options: o, now: now)
        #expect(fresh[1].children.first?.id == s.itemID.stringValue)
        let (frozen, outOfDate) = ListModel.freeze(fresh, previous: order)
        #expect(outOfDate)
        #expect(ListModel.order(of: frozen) == order)                 // no row moved
        #expect(ListModel.index(frozen)[s.itemID.stringValue]?.bytes == .gb(9))   // but the number changed
        // Same data, nothing changed → not out of date.
        #expect(ListModel.freeze(before, previous: order).outOfDate == false)
    }

    @Test func freezeAppendsNewRowsAndDropsVanished() {
        let o = ListOptions()
        let full = ListModel.build(world, protections: prot, options: o, now: now)
        var claude = world.claude
        let removed = claude.sessions.removeFirst()
        let w2 = WorldSnapshot(system: world.system, chrome: world.chrome, claude: claude, ownership: world.ownership,
                               selfBytes: 0, at: now)
        let smaller = ListModel.build(w2, protections: prot, options: o, now: now)
        let (frozen, _) = ListModel.freeze(full, previous: ListModel.order(of: smaller))
        let ids = frozen[1].children.map(\.id)
        #expect(ids.last == removed.itemID.stringValue)          // re-appearing row goes to the end
        let (f2, _) = ListModel.freeze(smaller, previous: ListModel.order(of: full))
        #expect(!f2[1].children.contains { $0.id == removed.itemID.stringValue })
    }

    @Test func chromeStates() {
        func rows(_ mode: String) -> Row {
            let w = MockWorldProvider.applyChromeMode(world, mode)
            return ListModel.build(w, protections: Planner().protections(w, now: now), options: ListOptions(), now: now)[0]
        }
        #expect(rows("processesOnly").children.first?.kind == .card)
        #expect(rows("processesOnly").children.last?.kind == .chromeItself)
        #expect(rows("notRunning").children.first?.note == .chromeNotRunning)
        #expect(rows("waiting").children.first?.note == .waitingForHelper)
        let apple = rows("appleScript")
        if case .perTabUnavailable = apple.children.first?.note {} else { Issue.record("no per-tab note") }
        let tabRow = ListModel.index([apple]).values.first { $0.kind == .tab }!
        #expect(tabRow.bytes == nil && Fmt.bytes(tabRow.bytes) == "—")
        if case .helperStale = rows("stale").children.first?.note {} else { Issue.record("no stale note") }
    }

    @Test func footerSummary() {
        let w = world
        let rows = ListModel.build(w, protections: prot, options: ListOptions(), now: now)
        let idx = ListModel.index(rows)
        let yt = w.chrome.tabs.first { $0.audible }!
        let map = w.chrome.tabs.first { $0.title.hasPrefix("Boston") }!
        let launcher = w.claude.sessions.first(where: \.isLauncher)!
        let sel = [yt.itemID, map.itemID, launcher.itemID].map { idx[$0.stringValue]! }
        let plan = Planner().plan(Set(sel.compactMap(\.item)), w, now: now)
        let text = SelectionSummary.text(selected: sel, plan: plan)
        #expect(text.hasPrefix("3 selected — 2 tabs, 1 session"))
        #expect(text.contains("1 needs a look (audible)"))
        #expect(text.contains("1 row can't be closed"))
        #expect(text.contains("frees ≈"))
    }
}

/// DOCKER is read-only: nothing in it can be selected, and it never changes what the other sections show.
@Suite struct DockerListTests {
    let now = Date()
    var world: WorldSnapshot { MockWorld.snapshot(now: now) }
    func rows(_ o: ListOptions = ListOptions(), _ w: WorldSnapshot? = nil) -> [Row] {
        ListModel.build(w ?? world, protections: [:], options: o, now: now)
    }
    func with(_ d: DockerSnapshot) -> WorldSnapshot {
        let w = world
        return WorldSnapshot(system: w.system, chrome: w.chrome, claude: w.claude, ownership: w.ownership,
                             selfBytes: w.selfBytes, at: w.at, isMock: true, docker: d)
    }

    @Test func sectionShowsTheVMProjectsContainersAndDisk() throws {
        let docker = try #require(rows().first { $0.section == .docker })
        let d = world.docker
        // The section's number is the VM on this Mac, not the containers' sum.
        #expect(docker.bytes == d.vmFootprint && docker.bytes != d.containersMemory)
        #expect(docker.badge?.hasPrefix("colima · 7 containers running · 3 stopped · containers use ") == true)
        let groups = docker.children.filter { $0.kind == .subgroup }
        #expect(groups.map(\.title) == ["quote-composer", "oakfield-ledger"])          // by memory, descending
        #expect(groups[1].children.map(\.title) == ["backend", "worker", "db", "redis"])
        #expect(groups[1].bytes == d.projects.first { $0.name == "oakfield-ledger" }?.memory)
        // A container started without compose sits beside the projects under its own name.
        let loose = try #require(docker.children.first { $0.kind == .container })
        #expect(loose.title == "scratch-pg" && loose.location == "postgres:17" && loose.state == "Up 5 days")
        // The disk note is last, in decimal units, with its age.
        let disk = try #require(docker.children.last)
        #expect(disk.note == .dockerDisk)
        #expect(disk.title.hasPrefix("Disk 67.1 GB, 29.1 GB reclaimable · images 41.2 GB · build cache 15.2 GB"))
        #expect(disk.title.hasSuffix("read 7m ago"))
        // Nothing in DOCKER can be selected or closed.
        var all: [Row] = []
        docker.walk { all.append($0) }
        #expect(all.allSatisfy { !$0.selectable && $0.item == nil })
        #expect(!ListModel.selectableIDs(rows()).contains { $0.hasPrefix("container:") || $0.hasPrefix("docker:") })
    }

    @Test func filterScopeAndKindToken() throws {
        // Free text matches name, image and project; empty projects and the disk note go away.
        let pg = try #require(rows(ListOptions(filter: "postgres")).first { $0.section == .docker })
        var titles: [String] = []
        pg.walk { if $0.kind == .container { titles.append($0.title) } }
        #expect(Set(titles) == ["db", "scratch-pg"])
        #expect(!pg.children.contains { $0.kind == .note })
        // is:container shows only DOCKER; a tab-only token hides it; so do the Chrome and Claude scopes.
        let only = rows(ListOptions(filter: "is:container"))
        #expect(only.map(\.title) == ["DOCKER"] && only[0].children.last?.note == .dockerDisk)
        #expect(rows(ListOptions(filter: "is:container >1gb")).first?.children.first?.children.map(\.title) == ["search"])
        #expect(!rows(ListOptions(filter: "site:linear.app")).contains { $0.section == .docker })
        #expect(!rows(ListOptions(scope: .chrome)).contains { $0.section == .docker })
        #expect(!rows(ListOptions(scope: .claude)).contains { $0.section == .docker })
    }

    @Test func hiddenUnlessTheEngineAnswersAndHonestWithoutAVM() throws {
        #expect(!rows(ListOptions(), with(.empty)).contains { $0.section == .docker })
        #expect(!rows(ListOptions(), with(DockerSnapshot(status: .notRunning, runtime: "colima"))).contains { $0.section == .docker })
        // VM up, nothing running: the VM still costs memory, so the section stays and says so.
        let idle = DockerSnapshot(status: .running, runtime: "colima", vmPids: [1], vmFootprint: .gb(3))
        let r = try #require(rows(ListOptions(), with(idle)).first { $0.section == .docker })
        #expect(r.bytes == .gb(3) && r.children.map(\.note) == [.dockerIdle])
        // VM not identified: the number falls back to the containers' sum and the tooltip says why.
        var noVM = world.docker
        noVM.vmPids = []; noVM.vmFootprint = nil
        let n = try #require(rows(ListOptions(), with(noVM)).first { $0.section == .docker })
        #expect(n.bytes == noVM.containersMemory && n.tooltip?.contains("could not tell") == true)
    }
}
