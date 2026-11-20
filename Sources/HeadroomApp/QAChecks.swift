// In-app QA checks, run only with --mock (see main.swift). They drive the real window with synthesized
// mouse and key events (sent through NSApp/NSWindow exactly like hardware events) and write what happened
// to a file, so selection, undo and sort-freeze behaviour can be checked without a person at the keyboard.

import AppKit
import HeadroomActions
import HeadroomContracts

@MainActor enum QADebug { static var log: [String] = [] }

@MainActor final class QARunner {
    private var steps: [() -> Void] = []
    private(set) var log: [String] = []
    let delay: TimeInterval
    init(delay: TimeInterval = 0.3) { self.delay = delay }
    func step(_ s: @escaping () -> Void) { steps.append(s) }
    var flushPath: String?
    func note(_ s: String) {
        log.append(s)
        if let p = flushPath { try? (log.joined(separator: "\n") + "\n").write(toFile: p, atomically: true, encoding: .utf8) }
    }
    func run(then done: @escaping ([String]) -> Void) {
        guard !steps.isEmpty else { done(log); return }
        let s = steps.removeFirst()
        s()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self.run(then: done) } }
    }
}

@MainActor extension MainWindowController {
    private var ov: ItemOutlineView { outlineCtl.outline }

    private func selectableRows() -> [Int] { (0..<ov.numberOfRows).filter { ov.isSelectable(row: $0) } }
    private func selectedRows() -> [Int] { Array(ov.selectedRowIndexes) }
    private func firstSession() -> Int {
        (0..<ov.numberOfRows).first { (ov.item(atRow: $0) as? Node)?.row.kind == .session } ?? 0
    }
    private func idAt(_ r: Int) -> String { (ov.item(atRow: r) as? Node)?.id ?? "?" }

    private func click(_ row: Int, _ mods: NSEvent.ModifierFlags = []) {
        guard let w = window else { return }
        // Centre the row without animation (clear of the floating section header).
        if let sv = ov.enclosingScrollView {
            let clip = sv.contentView
            let top = sv.contentInsets.top                   // the table header floats in the inset
            let r = ov.rect(ofRow: row)
            let visible = clip.bounds.height - top
            let wantY = r.midY - top - visible / 2
            let minY = -top, maxY = max(minY, ov.bounds.height - clip.bounds.height)
            if r.minY < clip.bounds.minY + top + 30 || r.maxY > clip.bounds.maxY - 4 {
                clip.setBoundsOrigin(NSPoint(x: 0, y: min(maxY, max(minY, wantY))))
                sv.reflectScrolledClipView(clip)
            }
        }
        ov.layoutSubtreeIfNeeded()
        let col = ov.column(withIdentifier: NSUserInterfaceItemIdentifier("state"))
        let cell = ov.frameOfCell(atColumn: max(col, 0), row: row)
        let p = ov.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: mods, timestamp: t,
                                            windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: mods, timestamp: t + 0.05,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        else { return }
        // Post the mouse-up from a timer that also runs in event-tracking mode, so it arrives while the
        // table is tracking the press (posting it first can be reordered by the gesture system).
        nonisolated(unsafe) let upEvent = up
        let t2 = Timer(timeInterval: 0.03, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.postEvent(upEvent, atStart: false) }
        }
        RunLoop.main.add(t2, forMode: .common)
        let hit = w.contentView?.superview?.hitTest(w.contentView!.superview!.convert(p, from: nil))
        if hit !== ov && hit?.isDescendant(of: ov) != true {
            QADebug.log.append("click row \(row): hit \(hit.map { String(describing: type(of: $0)) } ?? "nil") instead of the outline")
        } else if ov.row(at: ov.convert(p, from: nil)) != row {
            QADebug.log.append("click row \(row): landed on row \(ov.row(at: ov.convert(p, from: nil)))")
        }
        w.sendEvent(down)
    }

    private func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) {
        guard let w = window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: w.windowNumber, context: nil, characters: chars,
                                                       charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        else { return }
        // What NSApplication does for an active app: the key window, then the main menu, then keyDown.
        // (A QA run launched from a shell may not be the active app, so the menu step is done explicitly.)
        if mods.contains(.command), w.performKeyEquivalent(with: e) || NSApp.mainMenu?.performKeyEquivalent(with: e) == true {
            return
        }
        NSApp.sendEvent(e)
    }

    private func finish(_ path: String, _ log: [String]) {
        let log = log + QADebug.log.map { "debug: " + $0 }
        try? (log.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Finder-style selection (§7.1) against the live NSOutlineView.
    func selectionCheckForQA(path: String) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(ov)
        let q = QARunner()
        q.flushPath = path
        q.note("window is key: \(window?.isKeyWindow ?? false) (menu key equivalents need a key window)")
        var s: [Int] = []
        func expect(_ name: String, _ want: [Int]) {
            let got = selectedRows()
            q.note("\(got == want ? "PASS" : "FAIL") \(name): selected \(got.map(idAt)) \(got == want ? "" : "expected \(want.map(idAt))")")
        }
        q.step { s = self.selectableRows(); self.click(s[1]) }
        q.step { expect("click selects one row", [s[1]]) ; self.click(s[4], .shift) }
        q.step { expect("⇧-click selects the range from the anchor", Array(s[1...4])); self.click(s[6], .command) }
        q.step { expect("⌘-click adds a row", Array(s[1...4]) + [s[6]]); self.click(s[2], .command) }
        q.step { expect("⌘-click toggles a row off", [s[1], s[3], s[4], s[6]]); self.click(s[8], .command) }
        q.step { self.click(s[10], .shift) }
        q.step {
            // Finder keeps the earlier ⌘-picks and adds the range from the anchor (s[8]).
            expect("⇧-click after ⌘-click keeps earlier ⌘-picks", [s[1], s[3], s[4], s[6]] + Array(s[8...10]))
            self.click(self.firstSession() - 1)                    // the CLAUDE CODE group row
        }
        q.step {
            let got = self.selectedRows()
            let section = self.firstSession() - 1
            q.note("\(got.contains(section) ? "FAIL" : "PASS") section rows are never selected (click on \(self.idAt(section)) → \(got.map(self.idAt)))")
            self.key(53, "\u{1b}")
        }
        q.step { expect("Esc deselects", []); self.key(0, "a", .command) }
        q.step {
            let got = self.selectedRows()
            let want = self.selectableRows()
            let noGroups = !got.contains { (self.ov.item(atRow: $0) as? Node)?.row.kind == .section }
            q.note("\((got == want && noGroups) ? "PASS" : "FAIL") ⌘A selects every visible selectable row (\(got.count) of \(want.count), no section rows: \(noGroups))")
            self.key(53, "\u{1b}")
        }
        q.step { self.click(s[1]) }
        q.step { self.key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.numericPad, .function]) }
        q.step { self.key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.numericPad, .function]) }
        q.step { expect("↓↓ moves the selection", [s[3]]); self.key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.shift, .numericPad, .function]) }
        q.step { expect("⇧↓ extends from the anchor", [s[3], s[4]]); self.key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.shift, .numericPad, .function]) }
        q.step { expect("⇧↑ shrinks back", [s[3]]); self.key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.shift, .numericPad, .function]) }
        q.step { expect("⇧↑ again extends upwards", [s[2], s[3]]); self.key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.option, .numericPad, .function]) }
        q.step { expect("⌥↓ jumps to the last row", [self.selectableRows().last!]); self.key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.option, .numericPad, .function]) }
        q.step {
            expect("⌥↑ jumps to the first row", [self.selectableRows().first!])
            // Range across a section boundary: last row of CHROME to the first session.
            self.click(self.firstSession() - 2)
        }
        q.step { self.click(self.firstSession(), .shift) }
        q.step {
            let fs = self.firstSession()
            expect("⇧-range across a section skips the section row", [fs - 2, fs])
            self.click(s[1])
        }
        q.step { self.click(s[3], .command) }
        q.step { self.refresh(force: true) }
        q.step { self.refresh(force: true) }
        q.step {
            let ids = self.outlineCtl.selectedIDs
            q.note("\(ids == [self.idAt(s[1]), self.idAt(s[3])] ? "PASS" : "FAIL") selection is kept by id across refreshes (\(ids))")
        }
        q.run { self.finish(path, $0) }
    }

    /// Rex in the window, against MockWorld's Rex rows (Rex session "foundry": 2 sessions, one visible at foundry:2.1
    /// in tab "api reference"; "studio": 1). Calls the same entry points as the menus and the filter field
    /// (no synthesized events): Select ▾ submenu, Group Claude By, the eye glyph and Where text, `rex:` filter,
    /// Peek's Rex pane (MockExecutor's canned capture) and Jump (the mock toast; jumpNote is nil in mock).
    func rexCheckForQA(path: String) {
        let q = QARunner(delay: 0.6)
        q.flushPath = path
        func check(_ ok: Bool, _ name: String, _ detail: String) { q.note("\(ok ? "PASS" : "FAIL") \(name) (\(detail))") }
        func sessionRows() -> Set<String> { Set(outlineCtl.byID.values.filter { $0.row.kind == .session }.map(\.id)) }
        var rex: [ClaudeSession] = []
        var visible: ClaudeSession?
        func ids(_ label: String) -> Set<String> { Set(rex.filter { $0.rex?.sessionLabel == label }.map(\.itemID.stringValue)) }
        func sessionId(_ label: String) -> String { rex.first { $0.rex?.sessionLabel == label }?.rex?.sessionId ?? "?" }
        q.step {
            rex = self.world.claude.sessions.filter { $0.rex != nil }
            visible = rex.first { $0.rex?.visible == true }
            check(rex.count == 3 && ids("foundry").count == 2 && ids("studio").count == 1 && rex.allSatisfy { $0.tmux == nil },
                  "mock world has 3 Rex sessions, none also in tmux", "foundry \(ids("foundry").count), studio \(ids("studio").count)")
            let menu = NSMenu()
            self.populatePresets(menu)
            let titles = menu.items.first { $0.title == "Sessions in Rex session" }?.submenu?.items.map(\.title) ?? []
            check(titles.count == 2 && titles[0].hasPrefix("foundry  (2 ·") && titles[1].hasPrefix("studio  (1 ·"),
                  "Select ▾ has Sessions in Rex session", titles.joined(separator: " | "))
            let row = visible.flatMap { self.outlineCtl.byID[$0.itemID.stringValue]?.row }
            check(row?.location.hasPrefix("rex foundry:2.1 › ") == true && row?.glyphs.contains(.visible) == true
                  && row?.protection.reasons == [.visiblePane],
                  "visible Rex row: Where, eye glyph, asks first for visiblePane only",
                  "\(row?.location ?? "no row"); \(row?.protection.reasons.map(\.code) ?? [])")
            self.claudeGroupingForQA(.tmux)
            let f = self.outlineCtl.byID["rex:" + sessionId("foundry")]?.row
            let s = self.outlineCtl.byID["rex:" + sessionId("studio")]?.row
            let none = self.outlineCtl.byID["tmux:"]?.row
            check(f?.title == "Rex: foundry" && f?.children.count == 2 && s?.title == "Rex: studio" && s?.children.count == 1
                  && none?.title == "Not in tmux or Rex",
                  "Group Claude By tmux or Rex Session", "\(f?.title ?? "-"), \(s?.title ?? "-"), \(none?.title ?? "-")")
            self.claudeGroupingForQA(.none)
            self.filterForQA("rex:found")
            let found = sessionRows()
            self.filterForQA("rex:studio")
            let studio = sessionRows()
            self.filterForQA("")
            check(found == ids("foundry") && studio == ids("studio"), "rex: filter", "rex:found \(found.count), rex:studio \(studio.count)")
            if let v = visible { self.debugSelect([v.itemID.stringValue]); self.outlinePeek() }
        }
        q.step {
            let texts = self.debugPeekTexts
            let r = visible?.rex
            let heading = "Rex pane \(r?.shortBlockId ?? "?") (read-only)".uppercased()
            let ok = r != nil && texts.contains(heading)
                && texts.contains { $0.contains("Rex foundry:2.1 · api reference (visible)") }
                && texts.contains { $0.contains("(mock Rex pane \(r?.blockId.suffix(6) ?? "?"))") }
            check(ok, "Peek shows the Rex place and the pane capture", ok ? heading : texts.joined(separator: " ¦ "))
            self.jump(self.outlineCtl.selectedRows.first)
        }
        q.step {
            let want = "Mock: would jump to \(visible?.title ?? "?")"
            check(self.debugToastHeadline == want, "Jump on a Rex session", self.debugToastHeadline ?? "no toast")
        }
        q.run { self.finish(path, $0) }
    }

    /// Undo-first close (DECISIONS Q2) and NSUndoManager: close → Undo → Redo, through the window's undo manager.
    func undoCheckForQA(path: String, ids: [String]) {
        window?.makeFirstResponder(ov)
        let q = QARunner(delay: 0.6)
        func present() -> [Bool] { ids.map { id in self.outlineCtl.byID[id] != nil } }
        q.step { self.outlineCtl.select(ids: ids); q.note("before: present \(present())"); self.key(51, "\u{7f}") }
        q.step {
            let p = present()
            q.note("\(p.allSatisfy { !$0 } ? "PASS" : "FAIL") ⌫ closes at once with no sheet (sheet shown: \(self.window?.attachedSheet != nil)); present \(p)")
            q.note("undo menu title: \(self.window?.undoManager?.undoMenuItemTitle ?? "nil")")
            self.key(6, "z", .command)                             // ⌘Z through the Edit menu
        }
        q.step {}
        q.step {
            let p = present()
            q.note("\(p.allSatisfy { $0 } ? "PASS" : "FAIL") ⌘Z reopens them; present \(p)")
            q.note("redo menu title: \(self.window?.undoManager?.redoMenuItemTitle ?? "nil")")
            self.key(6, "Z", [.command, .shift])
        }
        q.step {}
        q.step {
            let p = present()
            q.note("\(p.allSatisfy { !$0 } ? "PASS" : "FAIL") ⇧⌘Z closes them again; present \(p)")
        }
        q.run { self.finish(path, $0) }
    }
}
