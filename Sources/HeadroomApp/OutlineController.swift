// The main list: a native NSOutlineView with Finder-style multiple selection (§7.1), group rows, diffing by
// row id (values reload in place, structural changes fade), selection kept by id across refreshes, the
// clickedRow context menu, and the keys of §7.2 that belong to the list.

import AppKit
import HeadroomActions
import HeadroomContracts

@MainActor protocol OutlineHost: AnyObject {
    func outlineSelectionChanged()
    func outlineClose(skipSheet: Bool)
    func outlineSleep()
    func outlineJump()
    func outlinePeek()
    func outlineCopy()
    func outlinePointerInside(_ inside: Bool)
    func outlineSortChanged(_ column: SortColumn, ascending: Bool)
    func outlineExpansionChanged(_ id: String, expanded: Bool)
    func outlineDefaultExpanded(_ row: Row) -> Bool
    func contextMenu(_ menu: NSMenu, targets: [Row])
    func cardView() -> NSView
    func noteView(_ row: Row) -> NSView
}

/// NSOutlineView with the list keys. Everything else (click, ⇧-click, ⌘-click, ⌘A, ↑/↓, ⇧↑/⇧↓, →/←,
/// type-select, click on empty space) is the native behaviour.
@MainActor final class ItemOutlineView: NSOutlineView {
    weak var host: OutlineHost?
    private var tracking: NSTrackingArea?

    override func keyDown(with e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch e.keyCode {
        case 51, 117:                                   // ⌫, ⌦
            if e.isARepeat { return }                   // a held key must not close twice
            if f.contains(.control) { host?.outlineSleep() }
            else { host?.outlineClose(skipSheet: f.contains(.option)) }
        case 36, 76:                                    // ↩, enter
            host?.outlineJump()
        case 49 where f.isDisjoint(with: [.command, .control, .option]):   // space
            host?.outlinePeek()
        case 53:                                        // esc
            deselectAll(nil)
        case 126 where f.contains(.option), 125 where f.contains(.option):  // ⌥↑ / ⌥↓: first / last row
            let rows = (0..<numberOfRows).filter { isSelectable(row: $0) }
            guard let target = e.keyCode == 126 ? rows.first : rows.last else { return }
            if f.contains(.shift), let anchor = selectedRowIndexes.first {
                let range = min(anchor, target)...max(anchor, target)
                selectRowIndexes(IndexSet(range.filter { isSelectable(row: $0) }), byExtendingSelection: false)
            } else {
                selectRowIndexes([target], byExtendingSelection: false)
            }
            scrollRowToVisible(target)
        case 124 where f.contains(.option):             // ⌥→ expands recursively
            for r in selectedRowIndexes { if let it = item(atRow: r) { expandItem(it, expandChildren: true) } }
        default:
            super.keyDown(with: e)
        }
    }

    func isSelectable(row: Int) -> Bool { (item(atRow: row) as? Node)?.row.selectable ?? false }

    override func cancelOperation(_ sender: Any?) { deselectAll(sender) }

    @objc func copy(_ sender: Any?) { host?.outlineCopy() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { host?.outlinePointerInside(true) }
    override func mouseExited(with event: NSEvent) { host?.outlinePointerInside(false) }

    /// Row whose context menu is open (for the Finder rule: unselected row → acts on that row only).
    func contextTargets() -> [Node] {
        let r = clickedRow
        guard r >= 0 else { return selectedNodes() }
        if selectedRowIndexes.contains(r) { return selectedNodes() }
        return (item(atRow: r) as? Node).map { [$0] } ?? []
    }

    func selectedNodes() -> [Node] { selectedRowIndexes.compactMap { item(atRow: $0) as? Node } }
}

@MainActor final class OutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outline = ItemOutlineView()
    let scroll = NSScrollView()
    weak var host: OutlineHost? { didSet { outline.host = host } }

    private(set) var roots: [Node] = []
    private(set) var byID: [String: Node] = [:]
    /// The selection, by row id (survives refreshes).
    private(set) var selectedIDs: [String] = []
    private var suppress = false
    private var settingSort = false

    /// Shows the sort arrow for the list's current sort (SPEC §6.1 "Memory ▼") without reporting it back.
    func showSort(_ column: SortColumn, ascending: Bool) {
        settingSort = true
        defer { settingSort = false }
        outline.sortDescriptors = [NSSortDescriptor(key: column.rawValue, ascending: ascending)]
    }
    private var maxBytes: Bytes = 1
    private var cardViewCache: NSView?

    static let columns: [(SortColumn, String, CGFloat, Bool)] = [
        (.name, "Name", 380, true), (.location, "Where", 230, true), (.state, "State", 120, true),
        (.memory, "Memory", 150, true), (.age, "Age", 60, false), (.pid, "PID", 64, false),
        (.rss, "RSS", 76, false), (.cpu, "CPU %", 56, false), (.lastActive, "Last active", 80, false),
    ]

    init(autosave: Bool) {
        super.init()
        outline.headerView = NSTableHeaderView()
        for (key, title, width, visible) in Self.columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key.rawValue))
            c.title = title
            c.width = width
            c.minWidth = key == .name ? 180 : 44
            c.isHidden = !visible
            c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: key == .name || key == .location)
            if key == .memory || key == .rss || key == .cpu || key == .pid || key == .age {
                c.headerCell.alignment = .right
            }
            c.resizingMask = key == .name ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            outline.addTableColumn(c)
            if key == .name { outline.outlineTableColumn = c }
        }
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsTypeSelect = true
        outline.floatsGroupRows = true
        outline.style = .fullWidth
        outline.rowSizeStyle = .custom
        outline.intercellSpacing = NSSize(width: 6, height: 0)
        outline.indentationPerLevel = 14
        outline.usesAlternatingRowBackgroundColors = false
        outline.gridStyleMask = []
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        if autosave {
            outline.autosaveName = "HeadroomOutline"
            outline.autosaveTableColumns = true
        }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.headerView?.menu = headerMenu()

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: Header menu (hidden columns)

    private func headerMenu() -> NSMenu {
        let m = NSMenu()
        for (key, title, _, _) in Self.columns where key != .name {
            let i = NSMenuItem(title: title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = key.rawValue
            m.addItem(i)
        }
        m.delegate = self
        return m
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let c = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key)) else { return }
        c.isHidden.toggle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === outline.headerView?.menu {
            for i in menu.items {
                if let key = i.representedObject as? String,
                   let c = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key)) {
                    i.state = c.isHidden ? .off : .on
                }
            }
            return
        }
        menu.removeAllItems()
        let targets = outline.contextTargets().map(\.row)
        guard !targets.isEmpty else { return }
        host?.contextMenu(menu, targets: targets)
    }

    // MARK: Apply rows

    func apply(_ rows: [Row]) {
        suppress = true
        defer { suppress = false }
        if roots.isEmpty {
            roots = rows.map { make($0, parent: nil) }
            outline.reloadData()
            for n in roots { expandDefaults(n) }
        } else {
            var reload: [Node?] = []
            var toExpand: [Node] = []
            outline.beginUpdates()
            sync(parent: nil, rows: rows, reload: &reload, toExpand: &toExpand)
            outline.endUpdates()
            for n in reload { outline.reloadItem(n, reloadChildren: true) }
            for n in toExpand { expandDefaults(n) }
        }
        byID = [:]
        func index(_ n: Node) { byID[n.id] = n; n.children.forEach(index) }
        roots.forEach(index)
        recomputeMax()
        let all = IndexSet(integersIn: 0..<outline.numberOfRows)
        outline.reloadData(forRowIndexes: all, columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
        for r in all { (outline.rowView(atRow: r, makeIfNecessary: false) as? ItemRowView).map { configureRowView($0, row: r) } }
        restoreSelection()
    }

    private func make(_ r: Row, parent: Node?) -> Node {
        let n = Node(r)
        n.parent = parent
        n.children = r.children.map { make($0, parent: n) }
        return n
    }

    private func expandDefaults(_ n: Node) {
        guard !n.children.isEmpty else { return }
        if host?.outlineDefaultExpanded(n.row) ?? false {
            outline.expandItem(n)
            for c in n.children { expandDefaults(c) }
        }
    }

    private func kids(_ p: Node?) -> [Node] { p?.children ?? roots }
    private func setKids(_ p: Node?, _ k: [Node]) { if let p { p.children = k } else { roots = k } }

    /// Brings `parent`'s children in line with `rows`. The model is updated before each insert/remove call
    /// (the outline reads it back through the data source), so no inout access is held across those calls.
    private func sync(parent: Node?, rows: [Row], reload: inout [Node?], toExpand: inout [Node], silent: Bool = false) {
        let nodes = kids(parent)
        let oldIDs = nodes.map(\.id), newIDs = rows.map(\.id)
        // `silent`: an ancestor is reloaded wholesale after endUpdates, so no per-item calls below it.
        let visible = !silent && (parent == nil || outline.isItemExpanded(parent))
        var subtreeReloaded = silent
        if oldIDs != newIDs {
            let old = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let newSet = Set(newIDs), oldSet = Set(oldIDs)
            let kept = oldIDs.filter(newSet.contains)
            if visible && kept == newIDs.filter(oldSet.contains) {
                let removed = IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) })
                if !removed.isEmpty {
                    setKids(parent, nodes.filter { newSet.contains($0.id) })
                    outline.removeItems(at: removed, inParent: parent, withAnimation: .effectFade)
                }
                for (i, r) in rows.enumerated() where !oldSet.contains(r.id) {
                    let n = make(r, parent: parent)
                    var k = kids(parent)
                    k.insert(n, at: i)
                    setKids(parent, k)
                    outline.insertItems(at: IndexSet(integer: i), inParent: parent, withAnimation: .effectFade)
                    toExpand.append(n)
                }
            } else {
                setKids(parent, rows.map { r in
                    if let n = old[r.id] { return n }
                    let n = make(r, parent: parent); toExpand.append(n); return n
                })
                if !silent { reload.append(parent) }
                subtreeReloaded = true
            }
        }
        for (n, r) in zip(kids(parent), rows) {
            let hadKids = !n.children.isEmpty
            n.row = r
            sync(parent: n, rows: r.children, reload: &reload, toExpand: &toExpand, silent: subtreeReloaded)
            if !subtreeReloaded, hadKids != !n.children.isEmpty, !reload.contains(where: { $0 === n }) { reload.append(n) }
        }
    }

    private func recomputeMax() {
        var m: Bytes = 0
        for r in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: r) as? Node else { continue }
            switch n.row.kind {
            case .tab, .session, .leftover, .process, .overhead: m = max(m, n.row.bytes ?? 0)
            default: break
            }
        }
        maxBytes = max(m, 1)
    }

    // MARK: Selection

    func restoreSelection() {
        var idx = IndexSet()
        var keep: [String] = []
        for id in selectedIDs {
            guard let n = byID[id], n.row.selectable else { continue }
            let r = outline.row(forItem: n)
            if r >= 0 { idx.insert(r); keep.append(id) }
        }
        selectedIDs = keep
        suppress = true
        if idx != outline.selectedRowIndexes { outline.selectRowIndexes(idx, byExtendingSelection: false) }
        suppress = false
    }

    func select(ids: [String], reveal: Bool = true) {
        for id in ids {
            var p = byID[id]?.parent
            var chain: [Node] = []
            while let n = p { chain.insert(n, at: 0); p = n.parent }
            for n in chain where !outline.isItemExpanded(n) { outline.expandItem(n) }
        }
        let idx = IndexSet(ids.compactMap { byID[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(idx, byExtendingSelection: false)
        if reveal, let first = idx.first { outline.scrollRowToVisible(first) }
    }

    var selectedRows: [Row] { selectedIDs.compactMap { byID[$0]?.row } }

    /// Every selectable, visible row (⌘A respects the filter, the scope and collapsed groups).
    func visibleSelectableIDs() -> [String] {
        (0..<outline.numberOfRows).compactMap { r -> String? in
            guard let n = outline.item(atRow: r) as? Node, n.row.selectable else { return nil }
            return n.id
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppress else { return }
        selectedIDs = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.id }
        host?.outlineSelectionChanged()
    }

    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        IndexSet(proposed.filter { outline.isSelectable(row: $0) })
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Node)?.row.selectable ?? false
    }

    @objc private func doubleClicked() {
        guard outline.clickedRow >= 0, outline.isSelectable(row: outline.clickedRow) else { return }
        host?.outlineJump()
    }

    func rect(for id: String) -> NSRect? {
        guard let n = byID[id] else { return nil }
        let r = outline.row(forItem: n)
        return r >= 0 ? outline.rect(ofRow: r) : nil
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.row.kind == .section
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let n = item as? Node else { return 24 }
        switch n.row.kind {
        case .section: return 28
        case .card: return 116
        case .note: return 30
        case .window, .subgroup, .chromeItself: return 25
        default: return 24
        }
    }
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !settingSort, let d = outlineView.sortDescriptors.first, let key = d.key,
              let col = SortColumn(rawValue: key) else { return }
        host?.outlineSortChanged(col, ascending: d.ascending)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !suppress, let n = notification.userInfo?["NSObject"] as? Node else { return }
        host?.outlineExpansionChanged(n.id, expanded: true)
        recomputeMax(); refreshVisibleCells()
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !suppress, let n = notification.userInfo?["NSObject"] as? Node else { return }
        host?.outlineExpansionChanged(n.id, expanded: false)
        recomputeMax(); refreshVisibleCells()
    }

    func refreshVisibleCells() {
        let vis = outline.rows(in: outline.visibleRect)
        guard vis.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: vis.location..<(vis.location + vis.length)),
                           columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
    }

    // MARK: Views

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let r = n.row
        if r.kind == .card || r.kind == .note { return nil }
        guard let col = tableColumn else {
            let c = outlineView.makeView(withIdentifier: SectionCell.id, owner: nil) as? SectionCell ?? SectionCell()
            c.configure(r)
            return c
        }
        let key = SortColumn(rawValue: col.identifier.rawValue) ?? .name
        switch key {
        case .name:
            let c = outlineView.makeView(withIdentifier: NameCell.id, owner: nil) as? NameCell ?? NameCell()
            c.configure(r)
            return c
        case .memory:
            let c = outlineView.makeView(withIdentifier: MemoryCell.id, owner: nil) as? MemoryCell ?? MemoryCell()
            c.configure(r, max: maxBytes, showBar: r.kind != .window && r.kind != .subgroup && r.kind != .chromeItself)
            return c
        default:
            let c = outlineView.makeView(withIdentifier: TextCell.id, owner: nil) as? TextCell ?? TextCell()
            let now = Date()
            switch key {
            case .location: c.configure(r.location, truncateMiddle: true)
            case .state:
                let busy = r.tone == .busy
                c.configure((busy ? "● " : "") + r.state, color: Theme.tone(r.tone), font: busy ? Theme.smallBold : Theme.small)
            case .age: c.configure(r.started.map { Fmt.age(now.timeIntervalSince($0)) } ?? "", font: Theme.monoSmall, align: .right)
            case .pid: c.configure(r.pid.map(String.init) ?? "", font: Theme.monoSmall, align: .right)
            case .rss: c.configure(r.rss.map { ByteFormat.short($0) } ?? "", font: Theme.monoSmall, align: .right)
            case .cpu: c.configure(r.cpu.map { String(format: "%.1f", $0) } ?? "", font: Theme.monoSmall, align: .right)
            case .lastActive: c.configure(r.lastActive.map { Fmt.age(now.timeIntervalSince($0)) } ?? "", font: Theme.monoSmall, align: .right)
            default: c.configure("")
            }
            return c
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let n = item as? Node else { return nil }
        let level = CGFloat(outline.level(forItem: n))
        switch n.row.kind {
        case .card:
            if cardViewCache == nil { cardViewCache = host?.cardView() }
            return ContentRowView(content: cardViewCache ?? NSView(), inset: 18 + level * outline.indentationPerLevel)
        case .note:
            return ContentRowView(content: host?.noteView(n.row) ?? NSView(), inset: 22 + level * outline.indentationPerLevel)
        default:
            let v = ItemRowView()
            v.bracket = n.row.bracket
            v.bracketX = 14 + level * outline.indentationPerLevel
            return v
        }
    }

    private func configureRowView(_ v: ItemRowView, row: Int) {
        guard let n = outline.item(atRow: row) as? Node else { return }
        v.bracket = n.row.bracket
        v.bracketX = 14 + CGFloat(outline.level(forItem: n)) * outline.indentationPerLevel
    }

    func invalidateCard() { cardViewCache = nil }
}
