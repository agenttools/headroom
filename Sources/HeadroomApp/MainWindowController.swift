// The single Headroom window (§6.1): toolbar (scope, Select ▾, token filter, Close button), strip, list,
// footer, toast, sheet, Peek, Recently Closed. Owns the refresh loop (§9) and the undo-first close flow
// (DECISIONS Q2): plan → (sheet only for §7.3 reasons) → execute → toast with Undo → NSUndoManager.
//
// All decisions come from HeadroomActions (Planner, CloseFlow, SheetModel, ToastModel, ListModel,
// SelectPreset); this file only wires them to AppKit.

import AppKit
import HeadroomActions
import HeadroomChrome
import HeadroomContracts

@MainActor final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
    NSMenuDelegate, NSMenuItemValidation, OutlineHost {
    let ctx: HeadroomContext
    let env: HeadroomEnv
    let prefs: UserDefaults
    let persistLayout: Bool

    private(set) var world = WorldSnapshot.empty
    private var protections: [ItemID: Protection] = [:]
    private var options: ListOptions
    private var expandedOverrides: [String: Bool]

    let outlineCtl: OutlineController
    private let strip = StripView()
    private let footer = FooterView()
    private let toast = ToastView()
    private let orderChip = NSButton()
    private let scope = NSSegmentedControl(labels: ["All", "Chrome", "Claude"], trackingMode: .selectOne, target: nil, action: nil)
    private let selectButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let search = NSSearchField()
    private let closeButton = NSButton()

    private var refreshing = false
    private var lastRefresh = Date.distantPast
    private var tick: Timer?
    private var pointerInside = false
    private var lastOrder: [String: [String]]?
    private var reorderWork: DispatchWorkItem?
    /// "X freed (measured)": the processes the close expected to end, each with its footprint before the
    /// close. After two refreshes, the ones that are gone are summed (other sections' changes do not count).
    private var measuring: (expected: [MeasureUnit], left: Int)?
    /// Items being closed right now: excluded from new plans, so a second ⌫ does not close them again.
    private var closingIDs: Set<ItemID> = []
    /// Closes still running (the app waits for them before it quits).
    private(set) var inFlightCloses = 0
    var onClosesFinished: (() -> Void)?
    /// A Chrome `dirty` event arrived while a refresh was not allowed yet; the next tick refreshes.
    private var pendingEventRefresh = false
    private var automationDenied = false
    private var peekPopover: NSPopover?
    private var peekCtl: PeekController?
    private var setupSheet: SetupSheet?
    private var recentSheet: RecentlyClosedSheet?
    private weak var card: SetupCardView?
    private var sawNoHelper = false
    private var announcedHelper = false

    init(ctx: HeadroomContext, env: HeadroomEnv, prefs: UserDefaults, persistLayout: Bool) {
        self.ctx = ctx; self.env = env; self.prefs = prefs; self.persistLayout = persistLayout
        options = (prefs.data(forKey: "listOptions")).flatMap { try? JSONDecoder().decode(ListOptions.self, from: $0) } ?? ListOptions()
        expandedOverrides = prefs.dictionary(forKey: "expanded") as? [String: Bool] ?? [:]
        sawNoHelper = prefs.bool(forKey: "sawNoHelper")
        announcedHelper = prefs.bool(forKey: "announcedHelper")
        outlineCtl = OutlineController(autosave: persistLayout)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Headroom"
        w.minSize = NSSize(width: 680, height: 440)
        w.isReleasedWhenClosed = false
        w.isRestorable = false          // frame autosave instead; mock runs leave no saved state
        super.init(window: w)
        w.delegate = self
        buildContent()
        buildToolbar()
        if persistLayout { w.setFrameAutosaveName("HeadroomMain") }
        if !persistLayout || !w.setFrameUsingName("HeadroomMain") { w.center() }
        outlineCtl.host = self
        outlineCtl.showSort(options.sort, ascending: options.ascending)
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFired() }
        }
        // Docker is read in the background (SPEC §5.2). It needs a cadence before the window is key, and the
        // list is drawn again when a read finds a different set of containers (the first read above all).
        applyCadence()
        (ctx.world as? LiveWorld)?.docker?.setOnChange { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let outline = outlineCtl.scroll
        for v in [strip, outline, footer, toast, orderChip] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        toast.isHidden = true
        toast.onUndo = { [weak self] in self?.window?.undoManager?.undo() }
        toast.onAction = { [weak self] a in self?.toastAction(a) }
        orderChip.title = "↕ Order out of date"
        orderChip.bezelStyle = .inline
        orderChip.controlSize = .small
        orderChip.font = Theme.small
        orderChip.target = self
        orderChip.action = #selector(reorderNow)
        orderChip.isHidden = true
        orderChip.toolTip = "Rows keep their place while the pointer is over the list or something is selected. Click (or ⌘R) to re-sort."
        let guide = content.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: guide.topAnchor),
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 80),
            outline.topAnchor.constraint(equalTo: strip.bottomAnchor),
            outline.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outline.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outline.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            toast.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
            toast.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            orderChip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            orderChip.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -8),
        ])
    }

    // MARK: Toolbar

    private enum TB {
        static let scope = NSToolbarItem.Identifier("scope")
        static let select = NSToolbarItem.Identifier("select")
        static let search = NSToolbarItem.Identifier("search")
        static let close = NSToolbarItem.Identifier("close")
    }

    private func buildToolbar() {
        let tb = NSToolbar(identifier: "HeadroomToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        window?.toolbar = tb
        window?.toolbarStyle = .unified
        scope.target = self
        scope.action = #selector(scopeChanged(_:))
        scope.selectedSegment = ListScope.allCases.firstIndex(of: options.scope) ?? 0
        scope.segmentStyle = .rounded
        selectButton.addItem(withTitle: "Select")
        selectButton.menu?.delegate = self
        selectButton.bezelStyle = .toolbar
        selectButton.controlSize = .regular
        search.placeholderString = "Filter — try idle>2h !busy"
        search.stringValue = options.filter
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(filterChanged(_:))
        closeButton.bezelStyle = .toolbar
        closeButton.target = self
        closeButton.action = #selector(closeFromButton(_:))
        closeButton.title = "Close"
        closeButton.isEnabled = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, TB.scope, TB.select, TB.search, TB.close]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case TB.scope:
            let i = NSToolbarItem(itemIdentifier: id); i.view = scope; i.label = "Scope"; return i
        case TB.select:
            let i = NSToolbarItem(itemIdentifier: id); i.view = selectButton; i.label = "Select"; return i
        case TB.search:
            let i = NSSearchToolbarItem(itemIdentifier: id)
            i.searchField = search
            i.preferredWidthForSearchField = 220
            return i
        case TB.close:
            let i = NSToolbarItem(itemIdentifier: id); i.view = closeButton; i.label = "Close"; return i
        default: return nil
        }
    }

    // MARK: Refresh (§9)

    private var refreshInterval: TimeInterval? {
        guard let w = window, w.isVisible, !w.isMiniaturized, w.occlusionState.contains(.visible) else { return nil }
        return w.isKeyWindow ? 2 : 10
    }

    private func tickFired() {
        guard let i = refreshInterval else { return }
        let since = Date().timeIntervalSince(lastRefresh)
        if since >= i || (pendingEventRefresh && since >= Self.minEventGap && window?.isKeyWindow == true) {
            refresh()
        }
    }

    /// At most one event-driven refresh per this many seconds.
    static let minEventGap: TimeInterval = 2

    func windowDidBecomeKey(_ notification: Notification) { applyCadence(); refresh() }
    func windowDidResignKey(_ notification: Notification) { applyCadence() }

    /// SPEC §9: tmux, Rex and the JXA list follow the window state (tmux and Rex 3 s / JXA 5 s while key,
    /// 10 s / 30 s while visible).
    private func applyCadence() {
        (ctx.world as? LiveWorld)?.setCadence(windowKey: window?.isKeyWindow ?? false)
    }

    /// A Chrome helper event (dirty, hello, disconnect). SPEC §9 refreshes "on dirty" only while the window is
    /// key, and coalesces: at most one refresh per `minEventGap`; otherwise the next tick picks it up.
    func refreshFromEvent() {
        guard let w = window, w.occlusionState.contains(.visible) else { return }
        guard w.isKeyWindow else { return }                      // visible, not key: the 10 s tick covers it
        if !refreshing && Date().timeIntervalSince(lastRefresh) >= Self.minEventGap {
            refresh()
        } else {
            pendingEventRefresh = true
        }
    }

    func refresh(force: Bool = false) {
        guard !refreshing else { pendingEventRefresh = true; return }
        refreshing = true
        pendingEventRefresh = false
        lastRefresh = Date()
        let provider = ctx.world
        Task.detached(priority: .userInitiated) {
            let w = await provider.snapshot()
            await MainActor.run { [weak self] in
                self?.refreshing = false
                self?.apply(world: w, forceOrder: force)
            }
        }
    }

    private func apply(world w: WorldSnapshot, forceOrder: Bool = false) {
        world = w
        protections = ctx.executor.protections(w)
        if case .helper = w.chrome.source {
            if sawNoHelper && !announcedHelper {
                announcedHelper = true; prefs.set(true, forKey: "announcedHelper")
                showToast(ToastModel(headline: "Memory per tab is on",
                                     lines: [ToastLine(text: "The helper costs \(w.helperBytes.map { ByteFormat.short($0) } ?? "a few MB") in Chrome.", action: nil)]))
            }
            setupSheet?.update(helperConnected: true)
        } else if !sawNoHelper {
            sawNoHelper = true; prefs.set(true, forKey: "sawNoHelper")
        }
        rebuild(forceOrder: forceOrder)
        if case .processesOnly = w.chrome.source, !ctx.isMock, !automationDenied,
           let chrome = (ctx.world as? LiveWorld)?.chrome {
            Task { [weak self] in
                let denied = await chrome.automationPermission() == .denied
                guard let self, denied != self.automationDenied else { return }
                self.automationDenied = denied
                self.card?.setAutomationDenied(denied)
            }
        }
        if var m = measuring {
            m.left -= 1
            if m.left <= 0 {
                measuring = nil
                let freed = MeasureUnit.freed(m.expected, now: w)
                if var t = toast.model, !toast.isHidden, t.headline.contains("freeing…") {
                    t.measured(freed)
                    toast.update(headline: t.headline)
                }
            } else { measuring = m }
        }
    }

    /// Rebuilds the rows. The order is frozen while the pointer is over the list or anything is selected.
    private func rebuild(forceOrder: Bool = false) {
        let fresh = ListModel.build(world, protections: protections, options: options)
        var rows = fresh
        var outOfDate = false
        let freshIndex = ListModel.index(fresh)
        let liveSelection = outlineCtl.selectedIDs.filter { freshIndex[$0] != nil }
        let freeze = !forceOrder && (pointerInside || !liveSelection.isEmpty)
        if freeze, let prev = lastOrder {
            (rows, outOfDate) = ListModel.freeze(fresh, previous: prev)
        }
        lastOrder = ListModel.order(of: rows)
        orderChip.isHidden = !outOfDate
        outlineCtl.apply(rows)
        card?.update(total: world.chrome.total)
        updateSelectionDependents()
        if outOfDate { scheduleReorderIfIdle() }
        strip.model.system = world.system
        strip.model.chrome = world.chrome.total
        strip.model.claude = world.claude.sessionsTotal
        strip.model.leftovers = world.claude.leftoversTotal
        strip.model.docker = world.docker.status == .running ? (world.docker.vmFootprint ?? 0) : 0
        strip.model.updated = world.at == .distantPast ? .distantPast : world.at
        strip.model.stale = world.chrome.staleSince != nil
        strip.model.mock = ctx.isMock || world.isMock
        strip.model.dryRun = env.dryRun
    }

    @objc func reorderNow() { rebuild(forceOrder: true) }

    // MARK: Selection-dependent UI

    private func currentPlan() -> ClosePlan? {
        let ids = Set(outlineCtl.selectedRows.compactMap(\.item))
        return ids.isEmpty ? nil : ctx.executor.plan(ids, world)
    }

    private func updateSelectionDependents() {
        let rows = outlineCtl.selectedRows
        let plan = currentPlan()
        if rows.isEmpty {
            footer.summary.stringValue = "Select rows to close them — ⌘A selects every visible row"
            footer.summary.textColor = .secondaryLabelColor
        } else {
            footer.summary.stringValue = SelectionSummary.text(selected: rows, plan: plan)
            footer.summary.textColor = .labelColor
        }
        var cost = "Headroom \(ByteFormat.short(world.selfBytes))"
        if let h = world.helperBytes { cost += " (+ helper \(ByteFormat.short(h)) in Chrome)" }
        if !world.claude.staleFiles.isEmpty {
            cost += " · \(Fmt.plural(world.claude.staleFiles.count, "stale session file")) hidden"
        }
        if env.dryRun { cost += " · dry run: nothing is really closed" }
        footer.cost.stringValue = cost
        if let p = plan, !p.items.isEmpty {
            closeButton.title = "Close \(p.items.count) · " + PlanMath.estimateText(p.estimate, unknown: PlanMath.unknownTabs(p.items, p.world))
            closeButton.isEnabled = true
        } else {
            closeButton.title = "Close"
            closeButton.isEnabled = false
        }
        // Strip hatch: split the estimate by section.
        var fc: Bytes = 0, fs: Bytes = 0, fl: Bytes = 0
        if let p = plan {
            var tabs: Set<TabRef> = []
            for i in p.items {
                switch i.id {
                case let .chromeTab(b, t): tabs.insert(TabRef(browserPid: b, tabId: t))
                case .session: fs += i.bytes
                case .leftover: fl += i.bytes
                default: break
                }
            }
            fc = world.chrome.freed(tabs)
        }
        strip.model.freesChrome = fc; strip.model.freesClaude = fs; strip.model.freesLeftovers = fl
    }

    // MARK: OutlineHost

    func outlineSelectionChanged() {
        updateSelectionDependents()
        if let p = peekPopover, p.isShown { peek(reuse: true) }
        scheduleReorderIfIdle()
    }

    func outlinePointerInside(_ inside: Bool) {
        pointerInside = inside
        scheduleReorderIfIdle()
    }

    private func scheduleReorderIfIdle() {
        reorderWork?.cancel()
        guard !pointerInside, outlineCtl.selectedIDs.isEmpty, !orderChip.isHidden else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.pointerInside, self.outlineCtl.selectedIDs.isEmpty else { return }
                self.rebuild(forceOrder: true)
            }
        }
        reorderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func outlineSortChanged(_ column: SortColumn, ascending: Bool) {
        options.sort = column; options.ascending = ascending
        saveOptions(); rebuild(forceOrder: true)
    }

    func outlineExpansionChanged(_ id: String, expanded: Bool) {
        expandedOverrides[id] = expanded
        if expandedOverrides.count > 400 { expandedOverrides = [:] }
        prefs.set(expandedOverrides, forKey: "expanded")
    }

    func outlineDefaultExpanded(_ row: Row) -> Bool {
        if let o = expandedOverrides[row.id] { return o }
        switch row.kind {
        case .section, .subgroup, .window: return true
        default: return false
        }
    }

    func outlineClose(skipSheet: Bool) { closeRows(outlineCtl.selectedRows, skipSheet: skipSheet) }
    func outlineSleep() { sleepTabs(outlineCtl.selectedRows) }
    func outlineJump() { jump(outlineCtl.selectedRows.first) }
    func outlinePeek() { peek(reuse: false) }
    func outlineCopy() { copyRows(outlineCtl.selectedRows) }

    func cardView() -> NSView {
        let v = SetupCardView(total: world.chrome.total, setup: #selector(setupHelper(_:)), allow: #selector(allowAutomation(_:)), target: self)
        if automationDenied { v.setAutomationDenied(true) }
        card = v
        return v
    }

    func noteView(_ row: Row) -> NSView {
        NoteView(row: row, target: self, clear: #selector(clearFilter(_:)), setup: #selector(setupHelper(_:)))
    }

    func contextMenu(_ menu: NSMenu, targets: [Row]) {
        let ids = targets.compactMap(\.item)
        let plan = ids.isEmpty ? nil : ctx.executor.plan(Set(ids), world)
        let n = plan?.items.count ?? 0
        func add(_ title: String, _ action: @escaping () -> Void, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: enabled ? #selector(ClosureItem.fire(_:)) : nil, keyEquivalent: "")
            let c = ClosureItem(action)
            i.target = c; i.representedObject = c; i.isEnabled = enabled
            menu.addItem(i)
        }
        add(n > 0 ? "Close \(n == 1 ? "" : "\(n) ")· " + PlanMath.estimateText(plan!.estimate, unknown: PlanMath.unknownTabs(plan!.items, plan!.world)) : "Close", { [weak self] in
            self?.closeRows(targets, skipSheet: false)
        }, enabled: n > 0)
        add("Close Now", { [weak self] in self?.closeRows(targets, skipSheet: true) }, enabled: n > 0)
        let tabs = targets.filter { $0.kind == .tab }
        if !tabs.isEmpty { add("Sleep Tab\(tabs.count == 1 ? "" : "s")", { [weak self] in self?.sleepTabs(targets) }) }
        menu.addItem(.separator())
        if let first = targets.first, targets.count == 1 {
            add("Jump", { [weak self] in self?.jump(first) }, enabled: first.kind == .tab || first.kind == .session || first.kind == .window)
            add("Peek", { [weak self] in
                self?.outlineCtl.select(ids: [first.id], reveal: false); self?.peek(reuse: false)
            })
        }
        add("Copy", { [weak self] in self?.copyRows(targets) })
        if targets.contains(where: { $0.kind == .session || $0.kind == .leftover }) {
            add("Reveal Folder in Finder", { [weak self] in self?.revealCwd(targets) })
        }
        if tabs.count > 0 {
            menu.addItem(.separator())
            add("Select Tabs on the Same Site", { [weak self] in self?.applyPreset(.sameSite(tabs.compactMap(\.item))) })
        }
        if targets.allSatisfy(\.isLocked) || plan?.locked.isEmpty == false {
            menu.addItem(.separator())
            let why = plan?.locked.first?.reason.text ?? targets.first?.protection.reasons.first?.text ?? "locked"
            add("🔒 \(why)", {}, enabled: false)
        }
    }

    // MARK: Close flow (§7.2–7.4, undo-first)

    @objc func closeFromButton(_ sender: Any?) {
        let option = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        closeRows(outlineCtl.selectedRows, skipSheet: option)
    }

    func closeRows(_ rows: [Row], skipSheet: Bool) {
        let ids = Set(rows.compactMap(\.item))
        guard !ids.isEmpty else { NSSound.beep(); return }
        close(ids: ids, skipSheet: skipSheet)
    }

    private func close(ids: Set<ItemID>, skipSheet: Bool) {
        var plan = ctx.executor.plan(ids, world)
        // Items another close is still working on are left out (a second ⌫ during the grace period).
        let already = plan.items.filter { closingIDs.contains($0.id) }
        if !already.isEmpty {
            let items = plan.items.filter { !closingIDs.contains($0.id) }
            if items.isEmpty {
                showToast(ToastModel(headline: "Already closing \(CloseFlow.countText(already.map(\.id)))…"))
                return
            }
            plan = ClosePlan(items: items, locked: plan.locked, estimate: PlanMath.estimate(items, plan.world),
                             world: plan.world, stopBackground: plan.stopBackground, skipBusy: plan.skipBusy)
        }
        switch CloseFlow.decide(plan, skipSheet: skipSheet) {
        case .nothing(let why):
            NSSound.beep()
            showToast(ToastModel(headline: why))
        case .execute:
            execute(plan)
        case .sheet(let note):
            guard let w = window else { return }
            let sheet = ConfirmSheet(model: SheetModel(plan: plan, mandatoryNote: note, dryRun: env.dryRun))
            sheet.begin(on: w) { [weak self] button, stop in
                withExtendedLifetime(sheet) {}
                guard let p = SheetModel.apply(button, to: plan, stopBackground: stop) else { return }
                self?.execute(p)
            }
        }
    }

    private func execute(_ plan: ClosePlan) {
        let expected = MeasureUnit.expected(plan)
        let executor = ctx.executor
        let dry = env.dryRun || ctx.isMock
        let ids = Set(PlanMath.effectiveItems(plan).map(\.id))
        closingIDs.formUnion(ids)
        inFlightCloses += 1
        showToast(ToastModel(headline: "Closing \(CloseFlow.countText(Array(ids)))…"))
        Task { [weak self] in
            var outcomes: [ItemID: Outcome] = [:]
            var force: [ItemID] = []
            var records: [ClosedRecord] = []
            for await ev in executor.execute(plan) {
                switch ev {
                case let .progress(id, o): outcomes[id] = o
                case .needsForce(let ids): force += ids
                case .finished(let r): records = r
                }
            }
            guard let self else { return }
            self.closingIDs.subtract(ids)
            self.inFlightCloses -= 1
            let t = ToastModel(records: records, outcomes: outcomes, needsForce: force, dryRun: dry, baseline: 0)
            self.showToast(t)
            if records.contains(where: \.restorable) { self.registerUndo(records) }
            self.measuring = dry ? nil : (expected, 2)
            self.refresh(force: false)
            if self.inFlightCloses == 0 { self.onClosesFinished?() }
        }
    }

    private func registerUndo(_ records: [ClosedRecord]) {
        guard let um = window?.undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.performUndo(records) }
        }
        um.setActionName("Close " + CloseFlow.countText(records.compactMap { ItemID(string: $0.itemId) }))
    }

    private func performUndo(_ records: [ClosedRecord]) {
        // Redo closes the reopened items, which have new identities on live data (a new Chrome tab id, a new
        // claude pid). The redo is registered now (it must be, while undoing) against a box that is filled
        // once the reopened items are found, and removed if they cannot be found.
        let um = window?.undoManager
        let box = RedoBox()
        um?.registerUndo(withTarget: box) { [weak self] b in
            MainActor.assumeIsolated { self?.performRedo(b.ids) }
        }
        let before = world
        let executor = ctx.executor
        let provider = ctx.world
        Task { [weak self] in
            let out = await executor.undo(records)
            guard let self else { return }
            self.showToast(self.undoToast(records, out))
            let reopened = records.filter { out[$0] == .done || out[$0] == .dryRun }
            let after = await provider.snapshot()
            let ids = RedoBox.resolve(reopened, before: before, after: after)
            if ids.isEmpty { um?.removeAllActions(withTarget: box) } else { box.ids = ids }
            self.apply(world: after, forceOrder: false)
        }
    }

    /// "↩︎ Reopened N items", failures, and "reopened without history" when Chrome had to use tabs.create.
    private func undoToast(_ records: [ClosedRecord], _ out: [ClosedRecord: Outcome]) -> ToastModel {
        let ok = out.values.filter { $0 == .done || $0 == .dryRun }.count
        let failed = out.filter { if case .failed = $0.value { true } else { false } }
        var lines: [ToastLine] = []
        if !failed.isEmpty {
            let why = failed.first.map { r -> String in if case .failed(let s) = r.value { s } else { "" } } ?? ""
            lines.append(ToastLine(text: "\(Fmt.plural(failed.count, "item")) could not be reopened — \(why)", action: nil))
        }
        let created = (ctx.world as? LiveWorld)?.chrome.lastRestoredVia.filter { $0 == "create" }.count ?? 0
        if created > 0 {
            lines.append(ToastLine(text: "\(Fmt.plural(created, "tab")) reopened without history", action: nil))
        }
        // A new Rex session Rex.app could not be asked to show. Only a session reopened by this Undo (.done) can have
        // set the notes, so a batch without one never shows an older note.
        if records.contains(where: { $0.kind == "session" && out[$0] == .done }) {
            for n in (ctx.world as? LiveWorld)?.reopenNotes ?? [] { lines.append(ToastLine(text: n, action: nil)) }
        }
        if records.contains(where: { $0.kind == "leftover" }) {
            lines.append(ToastLine(text: "Leftovers cannot be undone (⌘C in Recently Closed copies the command)", action: nil))
        }
        return ToastModel(headline: "↩︎ Reopened \(Fmt.plural(ok, "item"))", lines: lines)
    }

    private func performRedo(_ ids: [ItemID]) {
        guard !ids.isEmpty else { NSSound.beep(); return }
        close(ids: Set(ids), skipSheet: false)
    }

    private func toastAction(_ a: ToastLine.Action) {
        switch a {
        case .jump(let id): Task { await ctx.executor.jump(id) }
        case .forceQuit(let ids):
            let executor = ctx.executor
            Task { [weak self] in
                await executor.forceQuit(ids)
                self?.showToast(ToastModel(headline: "Force quit \(Fmt.plural(ids.count, "item"))"))
                self?.refresh()
            }
        }
    }

    private func showToast(_ m: ToastModel) {
        toast.show(m)
    }

    // MARK: Other actions

    func sleepTabs(_ rows: [Row]) {
        let tabIDs = rows.compactMap { r -> ItemID? in r.kind == .tab ? r.item : nil }
        guard !tabIDs.isEmpty else { NSSound.beep(); return }
        let activeSkipped = tabIDs.filter { id in
            if case let .chromeTab(b, t) = id { return world.chrome.tab(TabRef(browserPid: b, tabId: t))?.active ?? false }
            return false
        }
        let todo = tabIDs.filter { !activeSkipped.contains($0) }
        let executor = ctx.executor
        let dry = env.dryRun || ctx.isMock
        Task { [weak self] in
            let out = todo.isEmpty ? [:] : await executor.sleep(todo)
            let ok = out.values.filter { $0 == .done || $0 == .dryRun }.count
            var lines: [ToastLine] = []
            if !activeSkipped.isEmpty { lines.append(ToastLine(text: "The active tab was skipped", action: nil)) }
            let failed = out.values.filter { if case .failed = $0 { true } else { false } }.count
            if failed > 0 { lines.append(ToastLine(text: "\(failed) could not sleep (needs the helper extension)", action: nil)) }
            self?.showToast(ToastModel(headline: "\(dry ? "Dry run: would put" : "Put") \(Fmt.plural(ok, "tab")) to sleep", lines: lines))
            self?.refresh()
        }
    }

    func jump(_ row: Row?) {
        guard let row else { return }
        var target = row.item
        if case let .chromeWindow(b, wid)? = row.item {
            target = world.chrome.tabs.first { $0.browserPid == b && $0.windowId == wid && $0.active }?.itemID
        }
        guard let id = target else { NSSound.beep(); return }
        let executor = ctx.executor
        // A Rex Jump returns a note when it could only bring Rex forward (pane not found, or the app did not switch).
        Task { [weak self] in
            if let note = await executor.jumpNote(id) { self?.showToast(ToastModel(headline: note)) }
        }
        if ctx.isMock { showToast(ToastModel(headline: "Mock: would jump to \(row.title)")) }
    }

    func peek(reuse: Bool) {
        guard let row = outlineCtl.selectedRows.last, let rect = outlineCtl.rect(for: row.id) else {
            peekPopover?.close(); return
        }
        if !reuse, let p = peekPopover, p.isShown { p.close(); return }
        let ctl = peekCtl ?? PeekController()
        peekCtl = ctl
        ctl.show(row, world: world, peek: ctx.executor as? PeekProvider, env: env)
        let p = peekPopover ?? NSPopover()
        p.behavior = .semitransient
        p.animates = !reuse
        p.contentViewController = ctl
        peekPopover = p
        p.show(relativeTo: rect, of: outlineCtl.outline, preferredEdge: .maxX)
    }

    func copyRows(_ rows: [Row]) {
        var lines: [String] = []
        for r in rows {
            switch r.item {
            case let .chromeTab(b, t)?:
                if let tab = world.chrome.tab(TabRef(browserPid: b, tabId: t)) { lines.append(tab.url) }
            case let .chromeWindow(b, wid)?:
                lines += world.chrome.tabs.filter { $0.browserPid == b && $0.windowId == wid }.map(\.url)
            case .session(let k)?:
                if let s = world.claude.sessions.first(where: { $0.key == k }) { lines.append(s.resumeCommand) }
            case .leftover?:
                if let l = world.claude.leftovers.first(where: { $0.id == r.item }) {
                    let cmd = l.unit.argv.isEmpty ? l.unit.command : l.unit.argv.joined(separator: " ")
                    lines.append((l.cwd ?? l.unit.cwd).map { "cd '\($0)' && \(cmd)" } ?? cmd)
                }
            default:
                lines.append(r.tooltip ?? r.title)
            }
        }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func revealCwd(_ rows: [Row]) {
        for r in rows {
            var cwd: String?
            if case .session(let k)? = r.item { cwd = world.claude.sessions.first { $0.key == k }?.cwd }
            if case .leftover? = r.item { cwd = world.claude.leftovers.first { $0.id == r.item }.flatMap { $0.cwd ?? $0.unit.cwd } }
            if let c = cwd, FileManager.default.fileExists(atPath: c) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: c)
            }
        }
    }

    func openTranscript(_ rows: [Row]) {
        for r in rows {
            guard case .session(let k)? = r.item, let s = world.claude.sessions.first(where: { $0.key == k }) else { continue }
            let dir = s.cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
            let path = "\(env.projectsDir)/\(dir)/\(s.sessionId).jsonl"
            if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            else { NSSound.beep() }
        }
    }

    func applyPreset(_ p: SelectPreset) {
        if options.filter != "" || options.scope != .all {
            // Presets select across the whole list.
            options.filter = ""; search.stringValue = ""
            options.scope = .all; scope.selectedSegment = 0
            saveOptions(); rebuild(forceOrder: true)
        }
        let ids = p.ids(world, protections: protections).map(\.stringValue)
        outlineCtl.select(ids: ids)
        window?.makeFirstResponder(outlineCtl.outline)
    }

    // MARK: Menu actions (targets of the main menu)

    /// A plain-key menu equivalent (⌫, ↩, Space) typed into the filter field goes to the field instead.
    private func forwardedToTextField() -> Bool {
        guard let tv = window?.firstResponder as? NSTextView, let e = NSApp.currentEvent, e.type == .keyDown else { return false }
        tv.keyDown(with: e)
        return true
    }

    private var sheetOpen: Bool { window?.attachedSheet != nil }
    @objc func menuClose(_ sender: Any?) { if !sheetOpen && !forwardedToTextField() { outlineClose(skipSheet: false) } }
    @objc func menuCloseNow(_ sender: Any?) { if !sheetOpen && !forwardedToTextField() { outlineClose(skipSheet: true) } }
    @objc func menuSleep(_ sender: Any?) { if !sheetOpen && !forwardedToTextField() { outlineSleep() } }
    @objc func menuJump(_ sender: Any?) { if !sheetOpen && !forwardedToTextField() { outlineJump() } }
    @objc func menuPeek(_ sender: Any?) { if !sheetOpen && !forwardedToTextField() { outlinePeek() } }
    @objc func menuReveal(_ sender: Any?) { revealCwd(outlineCtl.selectedRows) }
    @objc func menuTranscript(_ sender: Any?) { openTranscript(outlineCtl.selectedRows) }
    @objc func menuSameSite(_ sender: Any?) {
        applyPreset(.sameSite(outlineCtl.selectedRows.filter { $0.kind == .tab }.compactMap(\.item)))
    }
    @objc func menuRefresh(_ sender: Any?) { reorderNow(); refresh(force: true) }
    @objc func menuFind(_ sender: Any?) { window?.makeFirstResponder(search) }
    @objc func menuScope(_ sender: NSMenuItem) { setScope(ListScope.allCases[sender.tag]) }
    @objc func menuChromeGrouping(_ sender: NSMenuItem) {
        options.chromeGrouping = ChromeGrouping.allCases[sender.tag]; saveOptions(); rebuild(forceOrder: true)
    }
    @objc func menuClaudeGrouping(_ sender: NSMenuItem) {
        options.claudeGrouping = ClaudeGrouping.allCases[sender.tag]; saveOptions(); rebuild(forceOrder: true)
    }
    @objc func menuRecentlyClosed(_ sender: Any?) {
        guard let w = window, w.attachedSheet == nil else { return }
        let s = recentSheet ?? RecentlyClosedSheet()
        recentSheet = s
        s.onRestore = { [weak self] recs in
            guard let self else { return }
            let executor = self.ctx.executor
            Task { [weak self] in
                let out = await executor.undo(recs)
                let list = await executor.recentlyClosed()
                guard let self else { return }
                self.recentSheet?.show(list)
                self.showToast(self.undoToast(recs, out))
                self.refresh(force: false)
            }
        }
        let executor = ctx.executor
        Task { [weak self] in
            let list = await executor.recentlyClosed()
            guard let self, let w = self.window else { return }
            s.show(list)
            w.beginSheet(s.window) { _ in }
        }
    }
    @objc func menuPreset(_ sender: NSMenuItem) {
        guard let p = (sender.representedObject as? PresetBox)?.preset else { return }
        applyPreset(p)
    }

    @objc func scopeChanged(_ sender: NSSegmentedControl) { setScope(ListScope.allCases[sender.selectedSegment]) }
    private func setScope(_ s: ListScope) {
        options.scope = s
        scope.selectedSegment = ListScope.allCases.firstIndex(of: s) ?? 0
        saveOptions(); rebuild(forceOrder: true)
    }

    @objc func filterChanged(_ sender: NSSearchField) {
        options.filter = sender.stringValue
        saveOptions(); rebuild(forceOrder: true)
    }
    func controlTextDidChange(_ obj: Notification) { filterChanged(search) }

    /// Return or ↓ in the filter moves focus to the list (and selects its first row), so the §7.5 sweep
    /// "filter, ⌘A, ⌫" acts on rows, not on the filter text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === search else { return false }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
            focusList()
            return true
        default:
            return false
        }
    }

    private func focusList() {
        let ov = outlineCtl.outline
        window?.makeFirstResponder(ov)
        if ov.selectedRowIndexes.isEmpty,
           let first = (0..<ov.numberOfRows).first(where: { outlineCtl.outline.isSelectable(row: $0) }) {
            ov.selectRowIndexes([first], byExtendingSelection: false)
            ov.scrollRowToVisible(first)
        }
    }

    @objc func clearFilter(_ sender: Any?) {
        search.stringValue = ""; options.filter = ""; saveOptions(); rebuild(forceOrder: true)
    }

    @objc func setupHelper(_ sender: Any?) {
        guard let w = window, w.attachedSheet == nil else { return }
        let s = SetupSheet(env: env)
        setupSheet = s
        if case .helper = world.chrome.source { s.update(helperConnected: true) }
        w.beginSheet(s.window) { [weak self] _ in self?.setupSheet = nil }
    }

    @objc func allowAutomation(_ sender: Any?) {
        if ctx.isMock {
            let a = NSAlert()
            a.messageText = "Mock mode"
            a.informativeText = "In the real app this asks macOS for permission to control Google Chrome (Automation). Nothing was requested."
            a.beginSheetModal(for: window!) { _ in }
            return
        }
        let chrome = (ctx.world as? LiveWorld)?.chrome
        Task.detached {
            // Through ChromeSource when live, so its cached permission state updates at once.
            let status: OSStatus
            if let chrome { status = await chrome.requestAutomationPermission() == .granted ? 0 : -1743 }
            else { status = AutomationPermission.requestChrome() }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if status != 0 {
                    self.automationDenied = true
                    self.card?.setAutomationDenied(true)
                }
                self.showToast(ToastModel(headline: status == 0 ? "Chrome control allowed" : "Chrome control not allowed (\(status))",
                                          lines: status == 0 ? [] : [ToastLine(text: "Use “Open Automation Settings…” on the card to turn it on", action: nil)]))
                self.refresh(force: false)
            }
        }
    }

    private func saveOptions() {
        if let d = try? JSONEncoder().encode(options) { prefs.set(d, forKey: "listOptions") }
    }

    // MARK: Select ▾ menu (live counts)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === selectButton.menu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: "Select", action: nil, keyEquivalent: "")
        populatePresets(menu)
    }

    func populatePresets(_ menu: NSMenu) {
        let w = world, prot = protections
        func item(_ p: SelectPreset, title: String? = nil) -> NSMenuItem {
            let (n, b) = p.summary(w, protections: prot)
            let i = NSMenuItem(title: "\(title ?? p.title)  (\(n) · \(ByteFormat.short(b)))", action: #selector(menuPreset(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = PresetBox(p)
            i.isEnabled = n > 0
            return i
        }
        for (_, t) in SelectPreset.idleIntervals { menu.addItem(item(.idleSessions(t))) }
        let tmuxNames = Array(Set(w.claude.sessions.compactMap { $0.tmux?.session })).sorted()
        let sub = NSMenu()
        for n in tmuxNames { sub.addItem(item(.tmuxSession(n))) }
        let tm = NSMenuItem(title: "Sessions in tmux session", action: nil, keyEquivalent: "")
        tm.submenu = sub
        menu.addItem(tm)
        // Rex sessions are keyed by id (labels need not be unique); shown only when some session runs in Rex.
        var rexNames: [String: String] = [:]
        for s in w.claude.sessions { if let r = s.rex, rexNames[r.sessionId] == nil { rexNames[r.sessionId] = r.sessionName } }
        if !rexNames.isEmpty {
            let pairs = rexNames.map { (id: $0.key, label: $0.value) }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
            let labelCounts = Dictionary(grouping: pairs, by: \.label).mapValues(\.count)
            let rsub = NSMenu()
            for p in pairs {
                let shared = (labelCounts[p.label] ?? 0) > 1
                rsub.addItem(item(.rexSession(id: p.id, label: p.label), title: shared ? "\(p.label) (…\(p.id.suffix(6)))" : nil))
            }
            let rx = NSMenuItem(title: "Sessions in Rex session", action: nil, keyEquivalent: "")
            rx.submenu = rsub
            menu.addItem(rx)
        }
        menu.addItem(.separator())
        menu.addItem(item(.tabsOver(.mb(500))))
        menu.addItem(item(.sessionsOver(.mb(500))))
        menu.addItem(item(.duplicateTabs))
        let same = outlineCtl.selectedRows.filter { $0.kind == .tab }.compactMap(\.item)
        let s = item(.sameSite(same))
        s.keyEquivalent = "s"; s.keyEquivalentModifierMask = [.command, .shift]
        if same.isEmpty { s.isEnabled = false }
        menu.addItem(s)
        menu.addItem(item(.backgroundWindows))
        menu.addItem(.separator())
        menu.addItem(item(.allLeftovers, title: "All leftovers (closing still asks)"))
    }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let sel = outlineCtl.selectedRows
        let listActions: [Selector] = [#selector(menuClose(_:)), #selector(menuCloseNow(_:)), #selector(menuSleep(_:)),
                                       #selector(menuJump(_:)), #selector(menuPeek(_:))]
        // Plain Return / Space / ⌫ typed in a sheet (Recently Closed, setup, confirm) must not act on the list.
        if let a = item.action, listActions.contains(a), window?.attachedSheet != nil { return false }
        switch item.action {
        case #selector(menuClose(_:)), #selector(menuCloseNow(_:)):
            return window?.firstResponder is NSTextView || sel.contains { $0.item != nil }
        case #selector(menuSleep(_:)):
            return window?.firstResponder is NSTextView || sel.contains { $0.kind == .tab }
        case #selector(menuJump(_:)), #selector(menuPeek(_:)):
            return window?.firstResponder is NSTextView || !sel.isEmpty
        case #selector(menuReveal(_:)): return sel.contains { $0.kind == .session || $0.kind == .leftover }
        case #selector(menuTranscript(_:)): return sel.contains { $0.kind == .session }
        case #selector(menuSameSite(_:)): return sel.contains { $0.kind == .tab }
        case #selector(menuScope(_:)):
            item.state = ListScope.allCases[item.tag] == options.scope ? .on : .off; return true
        case #selector(menuChromeGrouping(_:)):
            item.state = ChromeGrouping.allCases[item.tag] == options.chromeGrouping ? .on : .off; return true
        case #selector(menuClaudeGrouping(_:)):
            item.state = ClaudeGrouping.allCases[item.tag] == options.claudeGrouping ? .on : .off; return true
        default: return true
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        tick?.invalidate()
        peekPopover?.close()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window?.occlusionState.contains(.visible) == true { refresh() }
    }

    func scopeForQA(_ s: ListScope) { setScope(s) }
    func claudeGroupingForQA(_ g: ClaudeGrouping) { options.claudeGrouping = g; saveOptions(); rebuild(forceOrder: true) }

    /// QA for "no row moves while the pointer is over the list" (§7.1), with HEADROOM_MOCK_JITTER=1 so the
    /// mock footprints change on every refresh. Writes the result to `path`.
    func orderCheckForQA(path: String) {
        func order() -> [String] { (0..<outlineCtl.outline.numberOfRows).compactMap { (outlineCtl.outline.item(atRow: $0) as? Node)?.id } }
        func values() -> [String] { (0..<outlineCtl.outline.numberOfRows).compactMap { (outlineCtl.outline.item(atRow: $0) as? Node)?.row.bytes.map { "\($0)" } } }
        outlinePointerInside(true)
        let o0 = order(), v0 = values()
        var step = 0
        var log: [String] = []
        func next() {
            step += 1
            if step <= 5 {
                refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { next() } }
                return
            }
            if step == 6 {
                let o1 = order(), v1 = values()
                log.append("pointer inside, 5 refreshes: order unchanged=\(o0 == o1) values changed=\(v0 != v1) chip shown=\(!orderChip.isHidden)")
                outlinePointerInside(false)          // pointer leaves, nothing selected → reorder after 1 s
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { MainActor.assumeIsolated { next() } }
                return
            }
            let o2 = order()
            log.append("pointer left for 1.4 s: order changed=\(o2 != o0) chip shown=\(!orderChip.isHidden)")
            try? (log.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
        next()
    }
    func filterForQA(_ f: String) { search.stringValue = f; filterChanged(search) }

    /// For `--qa-select`: select rows by id and show the toast/sheet states for QA.
    func debugSelect(_ ids: [String]) { outlineCtl.select(ids: ids); updateSelectionDependents() }
    func debugClose(skipSheet: Bool) { outlineClose(skipSheet: skipSheet) }
    var debugRowCount: Int { outlineCtl.outline.numberOfRows }
    /// For `--qa-rex-check`: every string Peek shows (labels, headings, the capture box), and the toast headline.
    var debugPeekTexts: [String] {
        func walk(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(walk) }
        return peekCtl.map { walk($0.view) } ?? []
    }
    var debugToastHeadline: String? { toast.model?.headline }
}

/// Holds a closure for a context-menu item (menus keep a strong ref via representedObject).
@MainActor final class ClosureItem: NSObject {
    let action: () -> Void
    init(_ a: @escaping () -> Void) { action = a }
    @objc func fire(_ sender: Any?) { action() }
}

final class PresetBox: NSObject {
    let preset: SelectPreset
    init(_ p: SelectPreset) { preset = p }
}

enum AutomationPermission {
    /// AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true) for Google Chrome. Blocks; call off main.
    static func requestChrome() -> OSStatus {
        var addr = AEAddressDesc()
        let bundle = "com.google.Chrome"
        let err = bundle.withCString { p in
            AECreateDesc(typeApplicationBundleID, p, bundle.utf8.count, &addr)
        }
        guard err == noErr else { return OSStatus(err) }
        defer { AEDisposeDesc(&addr) }
        return AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, true)
    }
}

/// The redo target registered while undoing (see performUndo): filled with the reopened items' new ids.
@MainActor final class RedoBox: NSObject {
    var ids: [ItemID] = []

    /// New ids of reopened items: a session by its session id, a tab by URL among tabs that were not there
    /// before the undo. Items that are still under their old id (dry run, mock) keep it.
    static func resolve(_ records: [ClosedRecord], before: WorldSnapshot, after: WorldSnapshot) -> [ItemID] {
        var out: [ItemID] = []
        let afterIDs = Set(after.chrome.tabs.map(\.itemID) + after.claude.sessions.map(\.itemID))
        let oldTabs = Set(before.chrome.tabs.map(\.ref))
        var usedTabs: Set<TabRef> = []
        for r in records {
            if let id = ItemID(string: r.itemId), afterIDs.contains(id) { out.append(id); continue }
            if r.kind == "session", let sid = r.sessionId,
               let s = after.claude.sessions.first(where: { $0.sessionId == sid }) {
                out.append(s.itemID)
            } else if r.kind == "tab", let url = r.url,
                      let t = after.chrome.tabs.first(where: { $0.url == url && !oldTabs.contains($0.ref) && !usedTabs.contains($0.ref) }) {
                usedTabs.insert(t.ref); out.append(t.itemID)
            }
        }
        return out
    }
}

/// One group of processes a close expects to end, with its footprint before the close.
struct MeasureUnit: Sendable {
    /// Any of these still present = not freed.
    let keys: [ProcKey]
    let bytes: Bytes
    /// A tab renderer: only measurable while the helper reports renderers.
    var renderer = false

    static func expected(_ p: ClosePlan) -> [MeasureUnit] {
        let w = p.world
        var out: [MeasureUnit] = []
        var tabs: Set<TabRef> = []
        for i in PlanMath.effectiveItems(p) {
            switch i.id {
            case let .chromeTab(b, t): tabs.insert(TabRef(browserPid: b, tabId: t))
            case .session(let k):
                guard let s = w.claude.sessions.first(where: { $0.key == k }) else { continue }
                out.append(MeasureUnit(keys: [s.key], bytes: s.selfFootprint))
                for u in s.children { out.append(MeasureUnit(keys: [u.root], bytes: u.footprint)) }
                if p.stopBackground { for u in s.background { out.append(MeasureUnit(keys: [u.root], bytes: u.footprint)) } }
            case .leftover:
                if let l = w.claude.leftovers.first(where: { $0.id == i.id }) {
                    out.append(MeasureUnit(keys: [l.unit.root], bytes: l.unit.footprint))
                }
            default: break
            }
        }
        for (k, users) in w.chrome.procUsers where !users.isEmpty && users.isSubset(of: tabs) {
            out.append(MeasureUnit(keys: [k], bytes: w.chrome.procFootprint[k] ?? 0, renderer: true))
        }
        return out
    }

    /// Σ bytes of the expected units whose processes no longer appear in `now`.
    static func freed(_ units: [MeasureUnit], now w: WorldSnapshot) -> Bytes {
        var present: Set<ProcKey> = Set(w.chrome.procFootprint.keys)
        for s in w.claude.sessions {
            present.insert(s.key)
            for u in s.children + s.background { present.formUnion(u.members) }
        }
        for l in w.claude.leftovers { present.formUnion(l.unit.members) }
        present.formUnion(w.ownership.liveSessions)
        var perTab = false
        if case .helper = w.chrome.source { perTab = w.chrome.perTabUnavailable == nil }
        return units.filter { u in (perTab || !u.renderer) && !u.keys.contains(where: present.contains) }
            .reduce(0) { $0 + $1.bytes }
    }
}
