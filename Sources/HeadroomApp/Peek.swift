// Peek (§6.2, Space; follows ↑/↓) and Recently Closed (§7.7, ⌘Y).

import AppKit
import HeadroomActions
import HeadroomContracts

@MainActor final class PeekController: NSViewController {
    private let stack = NSStackView.v([], spacing: 5)
    private let width: CGFloat = 440
    private var captureBox: NSTextField?
    private var portsBox: NSTextField?

    override func loadView() {
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        view = stack
    }

    func show(_ row: Row, world w: WorldSnapshot, peek: PeekProvider?, env: HeadroomEnv) {
        _ = view
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        captureBox = nil; portsBox = nil
        title(row.title)
        let now = Date()
        switch row.item {
        case let .chromeTab(b, t)?:
            guard let tab = w.chrome.tab(TabRef(browserPid: b, tabId: t)) else { break }
            text(tab.incognito ? "Incognito tab (URL not shown)" : tab.url, font: Theme.code, selectable: true)
            let win = w.chrome.windows.firstIndex { $0.browserPid == b && $0.id == tab.windowId }.map { $0 + 1 } ?? 0
            var meta = "Window \(win) · tab \(tab.index + 1)"
            if let la = tab.lastAccessed { meta += " · last active \(tab.active ? "now" : Fmt.age(now.timeIntervalSince(la)) + " ago")" }
            if tab.discarded { meta += " · sleeping" }
            text(meta)
            text("Memory \(Fmt.bytes(tab.display, approx: tab.sharedWith > 0)) · closing it alone frees \(ByteFormat.short(w.chrome.freed([tab.ref])))")
            heading("Processes")
            if tab.procs.isEmpty { text("No renderer (sleeping or not yet attributed)") }
            for (i, k) in tab.procs.enumerated() {
                let users = w.chrome.procUsers[k] ?? []
                let frame = i < tab.frames.count ? tab.frames[i] : nil
                let role = i == 0 ? (users.count > 1 ? "main (shared)" : "main") : "iframe"
                let others = users.subtracting([tab.ref]).compactMap { w.chrome.tab($0)?.title }
                var line = "pid \(k.pid) · \(role) · \(frame?.lifecycle ?? "active") · \(ByteFormat.short(w.chrome.procFootprint[k] ?? 0))"
                if !others.isEmpty { line += " · also: " + others.joined(separator: ", ") }
                text(line, font: Theme.code)
            }
        case .session(let k)?:
            guard let s = w.claude.sessions.first(where: { $0.key == k }) else { break }
            text("\(Fmt.tilde(s.cwd, home: env.home))\(s.cwdExists ? "" : "  (missing on disk)")", font: Theme.code,
                 color: s.cwdExists ? .labelColor : .systemOrange, selectable: true)
            var meta = ["session \(s.sessionId)"]
            if let b = s.branch { meta.append("⎇ \(b)") }
            if let wt = s.worktree { meta.append("worktree \(wt)") }
            text(meta.joined(separator: " · "), font: Theme.small)
            var st = ["started \(Fmt.age(now.timeIntervalSince(s.startedAt))) ago"]
            if s.busy { st.append("busy since \(Fmt.age(now.timeIntervalSince(s.statusSince ?? now))) ago") }
            else if let i = s.idleSince { st.append("idle \(Fmt.age(now.timeIntervalSince(i)))") }
            if !s.version.isEmpty { st.append("v\(s.version)") }
            if s.remoteControl { st.append("Remote Control on") }
            if let t = s.tmux {
                st.append("tmux \(t.label)\(t.visible ? " (visible)" : "")")
            } else if let r = s.rex {
                // An unplaced Rex pane ("foundry:?") is visible by rule: unknown counts as on screen (SPEC §5).
                st.append("Rex \(r.label)\(r.windowLabel.map { " · " + $0 } ?? "")\(r.visible ? " (visible)" : "")")
            } else {
                st.append(ClaudeSession.notPlacedLabel)
            }
            text(st.joined(separator: " · "), font: Theme.small)
            if let p = s.lastPrompt { labeled("Last prompt", p) }
            if let a = s.lastAssistant { labeled("Last reply", a) }
            if let a = s.awaySummary { labeled("While you were away", a) }
            heading("Memory")
            text("claude \(ByteFormat.short(s.selfFootprint)) · total \(ByteFormat.short(s.total))", font: Theme.code)
            for u in s.children { text("  child  \(u.command) · pid \(u.root.pid) · \(ByteFormat.short(u.footprint))", font: Theme.code) }
            for u in s.background {
                text("  bg     \(u.isAutomationBrowser ? "⌬ " : "")\(u.command) · pgid \(u.pgid) · \(ByteFormat.short(u.footprint))", font: Theme.code)
            }
            if let t = s.tmux {
                heading("Pane \(t.paneId) (read-only)")
                let box = codeBox("…")
                captureBox = box
                Task { [weak self] in
                    let out = await peek?.capturePane(t.paneId)
                    self?.captureBox?.stringValue = out ?? "(pane not available)"
                }
            } else if let r = s.rex {
                // Read-only `rex capture … --trim`, last 60 lines (the CLI has no line count).
                heading("Rex pane \(r.shortBlockId) (read-only)")
                let box = codeBox("…")
                captureBox = box
                Task { [weak self] in
                    let out = await peek?.captureRexBlock(sessionId: r.sessionId, blockId: r.blockId)
                    self?.captureBox?.stringValue = out ?? "(pane not available)"
                }
            }
            heading("Resume")
            text(s.resumeCommand, font: Theme.code, selectable: true)
        case .leftover?:
            guard let l = w.claude.leftovers.first(where: { $0.id == row.item }) else { break }
            text(l.unit.argv.isEmpty ? l.unit.command : l.unit.argv.joined(separator: " "), font: Theme.code, selectable: true)
            if let c = l.cwd ?? l.unit.cwd { text(Fmt.tilde(c, home: env.home), font: Theme.code, selectable: true) }
            text("pgid \(l.unit.pgid) · \(l.unit.members.count) process\(l.unit.members.count == 1 ? "" : "es") · session pid \(l.deadClaudePid) has ended",
                 font: Theme.small)
            heading("Processes")
            for m in l.unit.members { text("pid \(m.pid)\(m == l.unit.root ? " (root)" : "")", font: Theme.code) }
            heading("Listening ports")
            portsBox = codeBox("…")
            Task { [weak self] in
                let lines = await peek?.listeningPorts(l.unit.members.map(\.pid)) ?? []
                self?.portsBox?.stringValue = lines.isEmpty ? "none" : lines.joined(separator: "\n")
            }
            if let t = l.sessionTitle { labeled("Ended session", t) }
            if let sid = l.sessionId, let c = l.cwd {
                text("cd '\(c)' && claude --resume \(sid)", font: Theme.code, selectable: true)
            }
            text("Leftovers cannot be undone. ⌘C copies the command and folder so you can restart it by hand.",
                 font: Theme.small, color: .tertiaryLabelColor)
        case .process(let k)?:
            text(row.tooltip ?? row.title, font: Theme.code, selectable: true)
            text("pid \(k.pid) · \(row.location) · part of a live session: close the session instead", font: Theme.small)
        case .chromeWindow?:
            text("\(row.badge ?? "") · selecting a window means all its tabs", font: Theme.small)
        case .chromeOverhead?:
            text(row.location.isEmpty ? "Part of Chrome itself (never closed)" : row.location, font: Theme.small)
        case nil:
            if row.kind == .chromeItself {
                text("Browser, GPU, utility, extension and background processes. Headroom never closes these.", font: Theme.small)
                for c in row.children { text("\(c.title)\(c.badge.map { " \($0)" } ?? "") · \(Fmt.bytes(c.bytes))", font: Theme.code) }
            }
        }
        if case .locked(let r) = row.protection {
            text("🔒 \(r.text)", font: Theme.small, color: .secondaryLabelColor)
        } else if !row.protection.reasons.isEmpty {
            text("Asks first: " + row.protection.reasons.map(\.text).joined(separator: "; "), font: Theme.small, color: .systemOrange)
        }
        stack.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: width + 28, height: min(stack.fittingSize.height, 560))
    }

    private func title(_ s: String) {
        let t = NSTextField.wrapping(s, font: NSFont.systemFont(ofSize: 13, weight: .semibold), width: width)
        stack.addArrangedSubview(t)
    }
    private func heading(_ s: String) {
        let t = NSTextField.label(s.uppercased(), font: Theme.section, color: .secondaryLabelColor)
        stack.addArrangedSubview(t)
        if let prev = stack.arrangedSubviews.dropLast().last { stack.setCustomSpacing(10, after: prev) }
    }
    private func text(_ s: String, font: NSFont = Theme.small, color: NSColor = .labelColor, selectable: Bool = false) {
        let t = NSTextField.wrapping(s, font: font, color: color, width: width)
        t.isSelectable = selectable
        stack.addArrangedSubview(t)
    }
    private func labeled(_ label: String, _ value: String) {
        let s = NSMutableAttributedString(string: label + ": ", attributes: [.font: Theme.smallBold, .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: value, attributes: [.font: Theme.small, .foregroundColor: NSColor.labelColor]))
        let t = NSTextField(wrappingLabelWithString: "")
        t.attributedStringValue = s
        t.preferredMaxLayoutWidth = width
        t.maximumNumberOfLines = 4
        t.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(t)
    }
    private func codeBox(_ s: String) -> NSTextField {
        let t = NSTextField.wrapping(s, font: Theme.code, color: .labelColor, width: width - 12)
        t.drawsBackground = true
        t.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6)
        t.isBezeled = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(t)
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6), t.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            t.topAnchor.constraint(equalTo: box.topAnchor, constant: 5), t.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -5),
            box.widthAnchor.constraint(equalToConstant: width),
        ])
        stack.addArrangedSubview(box)
        return t
    }
}

// MARK: - Recently Closed

@MainActor final class RecentlyClosedSheet: NSObject {
    let window: NSWindow
    private var records: [ClosedRecord] = []
    private let list = NSStackView.v([], spacing: 4)
    var onRestore: (([ClosedRecord]) -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        let title = NSTextField.label("Recently Closed", font: NSFont.systemFont(ofSize: 14, weight: .semibold))
        let sub = NSTextField.label("Kept for 7 days. Tabs reopen in Chrome; sessions reopen in tmux or Rex with claude --resume.",
                                    font: Theme.small, color: .secondaryLabelColor)
        let scroll = NSScrollView()
        let clip = FlippedClip(); clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        list.leadingAnchor.constraint(equalTo: clip.leadingAnchor).isActive = true
        list.topAnchor.constraint(equalTo: clip.topAnchor).isActive = true
        list.widthAnchor.constraint(equalToConstant: 496).isActive = true
        let done = NSButton.make("Done", target: self, action: #selector(close))
        done.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView.h([spacer, done])
        let root = NSStackView.v([title, sub, scroll, row], spacing: 10)
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 520),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            row.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        window.contentView = root
        window.setContentSize(NSSize(width: 560, height: 420))
    }

    func show(_ records: [ClosedRecord]) {
        self.records = records
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if records.isEmpty {
            list.addArrangedSubview(NSTextField.label("Nothing closed in the last 7 days.", font: Theme.body, color: .secondaryLabelColor))
            return
        }
        let df = DateFormatter()
        df.dateFormat = Calendar.current.isDateInToday(records[0].closedAt) ? "HH:mm" : "EEE HH:mm"
        var seen: [String] = []
        for r in records where !seen.contains(r.batchId) { seen.append(r.batchId) }
        for (bi, batch) in seen.enumerated() {
            let items = records.filter { $0.batchId == batch }
            let time = df.string(from: items[0].closedAt)
            let head = NSTextField.label("\(time) · \(CloseFlow.countText(items.compactMap { ItemID(string: $0.itemId) }))\(items[0].source == "cli" ? " · from the CLI" : "")",
                                         font: Theme.smallBold, color: .secondaryLabelColor)
            var hv: [NSView] = [head]
            if items.contains(where: \.restorable) {
                let b = NSButton.make("Restore all from \(time)", target: self, action: #selector(restoreBatch(_:)), small: true)
                b.tag = bi
                let sp = NSView(); sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
                hv += [sp, b]
            }
            let h = NSStackView.h(hv)
            h.widthAnchor.constraint(equalToConstant: 496).isActive = true
            list.addArrangedSubview(h)
            for r in items {
                let icon = Theme.symbol(r.kind == "tab" ? "globe" : r.kind == "session" ? "terminal" : "gearshape.2",
                                        size: 11, color: .secondaryLabelColor) ?? NSImage()
                let t = NSTextField.label(r.title, font: Theme.body)
                let bytes = NSTextField.label(ByteFormat.short(r.bytes), font: Theme.monoSmall, color: .secondaryLabelColor)
                let sp = NSView(); sp.setContentHuggingPriority(.defaultLow, for: .horizontal)
                var v: [NSView] = [NSImageView(image: icon), t, sp, bytes]
                if r.restorable {
                    let b = NSButton.make("Restore", target: self, action: #selector(restoreOne(_:)), small: true)
                    b.identifier = NSUserInterfaceItemIdentifier(r.id)
                    v.append(b)
                } else {
                    v.append(NSTextField.label(r.kind == "leftover" ? "not undoable" : "not restorable", font: Theme.small,
                                               color: .tertiaryLabelColor))
                }
                let row = NSStackView.h(v)
                row.toolTip = r.url ?? r.cwd ?? r.argv?.joined(separator: " ")
                row.widthAnchor.constraint(equalToConstant: 496).isActive = true
                list.addArrangedSubview(row)
            }
            if let last = list.arrangedSubviews.last { list.setCustomSpacing(12, after: last) }
        }
    }

    @objc private func restoreOne(_ b: NSButton) {
        guard let id = b.identifier?.rawValue, let r = records.first(where: { $0.id == id }) else { return }
        onRestore?([r])
    }
    @objc private func restoreBatch(_ b: NSButton) {
        var seen: [String] = []
        for r in records where !seen.contains(r.batchId) { seen.append(r.batchId) }
        guard b.tag < seen.count else { return }
        onRestore?(records.filter { $0.batchId == seen[b.tag] && $0.restorable })
    }
    @objc func close() { window.sheetParent?.endSheet(window) }
}
