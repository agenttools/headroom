// Footer, Undo toast (§6.3), confirm sheet (§7.3), first-run card and setup sheet (§8.6), inline notes.

import AppKit
import HeadroomActions
import HeadroomChrome
import HeadroomContracts

// MARK: - Footer

@MainActor final class FooterView: NSView {
    let summary = NSTextField.label(font: Theme.body)
    let cost = NSTextField.label(font: Theme.small, color: .tertiaryLabelColor)
    let keys = NSTextField.label("⌫ Close   ↩ Jump   ␣ Peek", font: Theme.small, color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        keys.alignment = .right
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [summary, cost, keys] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            summary.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -12),
            cost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            cost.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 2),
            cost.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            keys.centerYAnchor.constraint(equalTo: summary.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Toast

@MainActor final class ToastView: NSVisualEffectView {
    var onUndo: (() -> Void)?
    var onAction: ((ToastLine.Action) -> Void)?
    var onDismiss: (() -> Void)?
    private let stack = NSStackView.v([], spacing: 4)
    private let headline = NSTextField.label(font: NSFont.systemFont(ofSize: 13, weight: .medium))
    private var remaining: TimeInterval = 8
    private var timer: Timer?
    private var hovering = false
    /// Bumped by show(): a fade-out started for an older toast must not hide a newer one.
    private var generation = 0
    private(set) var model: ToastModel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 10)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ m: ToastModel) {
        generation += 1
        model = m
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        headline.stringValue = m.headline
        var top: [NSView] = [headline]
        if m.undoable {
            let undo = NSButton.make("Undo ⌘Z", target: self, action: #selector(undoTapped), small: true)
            undo.bezelStyle = .inline
            top.append(undo)
        }
        let close = NSButton(image: Theme.symbol("xmark", size: 9, color: .secondaryLabelColor) ?? NSImage(),
                             target: self, action: #selector(dismissTapped))
        close.isBordered = false
        top.append(close)
        stack.addArrangedSubview(NSStackView.h(top, spacing: 10))
        for (i, line) in m.lines.enumerated() {
            let l = NSTextField.label(line.text, font: Theme.small, color: .secondaryLabelColor)
            var views: [NSView] = [l]
            if let t = line.actionTitle {
                let b = NSButton.make(t, target: self, action: #selector(lineTapped(_:)), small: true)
                b.bezelStyle = .inline
                b.tag = i
                views.append(b)
            }
            stack.addArrangedSubview(NSStackView.h(views, spacing: 8))
        }
        remaining = 8
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.remaining -= 0.25
                if self.remaining <= 0 { self.dismissTapped() }
            }
        }
        isHidden = false
        alphaValue = 1
    }

    func update(headline text: String) {
        headline.stringValue = text
        model?.headline = text
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// The undo result replaces this toast (performUndo shows its own), so no fade-out here; the auto-dismiss
    /// timer keeps running in case there was nothing to undo.
    @objc private func undoTapped() { onUndo?() }
    @objc private func lineTapped(_ b: NSButton) {
        guard let m = model, b.tag < m.lines.count, let a = m.lines[b.tag].action else { return }
        onAction?(a)
    }
    @objc func dismissTapped() {
        timer?.invalidate(); timer = nil
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.generation == gen else { return }      // a newer toast is showing
                self.isHidden = true; self.onDismiss?()
            }
        })
    }
}

// MARK: - Confirm sheet

@MainActor final class ConfirmSheet: NSObject {
    let window: NSWindow
    private let model: SheetModel
    private let checkbox: NSButton?
    private var completion: ((SheetModel.Button, Bool) -> Void)?

    init(model m: SheetModel) {
        model = m
        let sheetWindow = CancelableWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled],
                                           backing: .buffered, defer: false)
        window = sheetWindow
        checkbox = m.checkboxText.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        super.init()
        let width: CGFloat = 480
        var views: [NSView] = []
        let title = NSTextField.wrapping(m.title, font: NSFont.systemFont(ofSize: 14, weight: .semibold), width: width)
        views.append(title)
        if let note = m.mandatoryNote {
            views.append(NSTextField.wrapping(note, font: Theme.small, color: .systemOrange, width: width))
        }
        let list = NSStackView.v([], spacing: 3)
        for g in m.groups {
            list.addArrangedSubview(NSTextField.label(g.heading.uppercased(), font: Theme.section, color: .secondaryLabelColor))
            for l in g.lines {
                let head = NSMutableAttributedString(string: l.title, attributes: [.font: Theme.body, .foregroundColor: NSColor.labelColor])
                head.append(NSAttributedString(string: "  " + l.bytesText,
                                               attributes: [.font: Theme.monoSmall, .foregroundColor: NSColor.secondaryLabelColor]))
                let t = NSTextField(labelWithAttributedString: head)
                t.lineBreakMode = .byTruncatingTail
                t.translatesAutoresizingMaskIntoConstraints = false
                t.widthAnchor.constraint(lessThanOrEqualToConstant: width - 20).isActive = true
                list.addArrangedSubview(t)
                let why = (l.reasons + l.context.map { "note: \($0)" }).joined(separator: " · ")
                if !why.isEmpty {
                    let r = NSTextField.wrapping(why, font: Theme.small, color: l.busy ? .systemOrange : .secondaryLabelColor,
                                                 width: width - 20)
                    list.addArrangedSubview(r)
                }
            }
            list.setCustomSpacing(10, after: list.arrangedSubviews.last!)
        }
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedClip()
        flipped.drawsBackground = false
        scroll.contentView = flipped
        scroll.documentView = list
        list.leadingAnchor.constraint(equalTo: flipped.leadingAnchor).isActive = true
        list.topAnchor.constraint(equalTo: flipped.topAnchor).isActive = true
        list.widthAnchor.constraint(equalToConstant: width).isActive = true
        list.layoutSubtreeIfNeeded()
        let listHeight = min(max(list.fittingSize.height, 40), 300)
        scroll.heightAnchor.constraint(equalToConstant: listHeight).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        views.append(scroll)
        if let cb = checkbox {
            cb.state = .on
            views.append(cb)
            let cmds = m.backgroundUnits.map { "pid \($0.root.pid) · \($0.command) · \(ByteFormat.short($0.footprint))" }
                .joined(separator: "\n")
            views.append(NSTextField.wrapping(cmds, font: Theme.code, color: .secondaryLabelColor, width: width - 20))
        }
        if let l = m.lockedNote { views.append(NSTextField.wrapping(l, font: Theme.small, color: .secondaryLabelColor, width: width)) }
        if let f = m.footnote { views.append(NSTextField.wrapping(f, font: Theme.small, color: .tertiaryLabelColor, width: width)) }

        var buttons: [NSView] = []
        for b in m.buttons.reversed() {
            let nb = NSButton.make(b.title, target: self, action: #selector(tapped(_:)))
            nb.tag = m.buttons.firstIndex(of: b)!
            if b == m.defaultButton { nb.keyEquivalent = "\r" }
            if b == .cancel { nb.keyEquivalent = b == m.defaultButton ? "\r" : "\u{1b}" }
            buttons.insert(nb, at: 0)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView.h([spacer] + buttons, spacing: 8)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        views.append(row)

        let root = NSStackView.v(views, spacing: 10)
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        window.contentView = root
        window.setContentSize(root.fittingSize)
        // Esc always cancels, also when Cancel is the Return button (every selected session is busy).
        sheetWindow.onCancel = { [weak self] in self?.finish(.cancel) }
    }

    func begin(on parent: NSWindow, completion: @escaping (SheetModel.Button, Bool) -> Void) {
        self.completion = completion
        parent.beginSheet(window) { _ in }
    }

    @objc private func tapped(_ b: NSButton) { finish(model.buttons[b.tag]) }

    private func finish(_ choice: SheetModel.Button) {
        guard let c = completion else { return }
        completion = nil
        let stop = checkbox?.state != .off
        window.sheetParent?.endSheet(window)
        c(choice, stop)
    }
}

/// A sheet window where Esc runs `onCancel` whatever the buttons' key equivalents are.
final class CancelableWindow: NSWindow {
    var onCancel: (() -> Void)?
    private func isEsc(_ e: NSEvent) -> Bool {
        e.keyCode == 53 && e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad]).isEmpty
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, isEsc(event), let c = onCancel { c(); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if isEsc(event), let c = onCancel { c(); return }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if let c = onCancel { c() } else { super.cancelOperation(sender) }
    }
}

final class FlippedClip: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - First-run card (§8.6)

@MainActor final class SetupCardView: NSView {
    let headline = NSTextField.label(font: NSFont.systemFont(ofSize: 12.5, weight: .semibold))
    private var allowTitle: NSTextField?
    private var allowDetail: NSTextField?
    private var allowButton: NSButton?
    private let allowAction: Selector
    private weak var actionTarget: AnyObject?
    init(total: Bytes, setup: Selector, allow: Selector, target: AnyObject) {
        allowAction = allow
        actionTarget = target
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        update(total: total)
        func option(_ n: String, _ title: String, _ detail: String, _ button: String, _ action: Selector)
            -> (NSView, NSTextField, NSTextField, NSButton) {
            let num = NSTextField.label(n, font: NSFont.systemFont(ofSize: 12, weight: .bold), color: .controlAccentColor)
            let t = NSTextField.label(title, font: NSFont.systemFont(ofSize: 12, weight: .medium))
            let d = NSTextField.label(detail, font: Theme.small, color: .secondaryLabelColor)
            let b = NSButton.make(button, target: target, action: action, small: true)
            let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return (NSStackView.h([num, t, d, spacer, b], spacing: 6), t, d, b)
        }
        let o1 = option("①", "Headroom helper extension", "memory per tab, Sleep, Undo with history", "Set up…", setup).0
        let (o2, t2, d2, b2) = option("②", "Let Headroom control Chrome", "lists and closes tabs, no per-tab memory", "Allow…", allow)
        allowTitle = t2; allowDetail = d2; allowButton = b2
        let foot = NSTextField.label("Headroom never reads page content, cookies or history.", font: Theme.small, color: .tertiaryLabelColor)
        let s = NSStackView.v([headline, o1, o2, foot], spacing: 7)
        s.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            o1.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -28),
            o2.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -28),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(total: Bytes) {
        let t = "Chrome is using \(ByteFormat.short(total)). To see and close individual tabs, choose one or both:"
        if headline.stringValue != t { headline.stringValue = t }
    }

    /// Once Automation was denied, macOS never asks again: option ② then links to System Settings.
    func setAutomationDenied(_ denied: Bool) {
        allowTitle?.stringValue = denied ? "Chrome control was denied" : "Let Headroom control Chrome"
        allowDetail?.stringValue = denied ? "turn on Google Chrome under Headroom in Automation settings"
            : "lists and closes tabs, no per-tab memory"
        allowButton?.title = denied ? "Open Automation Settings…" : "Allow…"
        allowButton?.target = denied ? self : actionTarget
        allowButton?.action = denied ? #selector(openAutomationSettings) : allowAction
    }

    @objc private func openAutomationSettings() {
        if let u = URL(string: JXAFallback.automationSettingsURL) { NSWorkspace.shared.open(u) }
    }
}

/// "[Set up…]": three steps that tick themselves off (bridge file, Load unpacked, waiting for the hello).
@MainActor final class SetupSheet: NSObject {
    let window: NSWindow
    private let step1 = NSTextField.label()
    private let step3 = NSTextField.label()
    private let env: HeadroomEnv

    init(env: HeadroomEnv) {
        self.env = env
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        super.init()
        let w: CGFloat = 480
        let title = NSTextField.label("Set up the Headroom helper", font: NSFont.systemFont(ofSize: 14, weight: .semibold))
        let copyURL = NSButton.make("Copy “chrome://extensions”", target: self, action: #selector(copyExtensionsURL), small: true)
        let copyPath = NSButton.make("Copy folder path", target: self, action: #selector(copyFolder), small: true)
        let step2 = NSTextField.wrapping("2. In Chrome, open chrome://extensions, turn on Developer mode, click Load unpacked, press ⌘⇧G and paste the folder path.",
                                         font: Theme.body, width: w)
        let note = NSTextField.wrapping("Chrome may show a notice about developer-mode extensions. The helper must be added once per Chrome profile.",
                                        font: Theme.small, color: .secondaryLabelColor, width: w)
        let done = NSButton.make("Done", target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView.h([spacer, done])
        row.widthAnchor.constraint(equalToConstant: w).isActive = true
        let s = NSStackView.v([title, step1, step2, NSStackView.h([copyURL, copyPath]), step3, note, row], spacing: 10)
        s.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        window.contentView = s
        installBridgeFile()
        update(helperConnected: false)
        window.setContentSize(s.fittingSize)
    }

    /// SPEC §8.6 step 1 is automatic: the installed app writes the bridge file (idempotent) when the sheet
    /// opens. Dry run, and copies of the app outside ~/Applications, only say what would happen.
    private var installNote: String?
    private func installBridgeFile() {
        let m = HostManifest(env: env)
        guard let d = HostManifest.installedBundleDefaults(env: env) else {
            if !FileManager.default.fileExists(atPath: m.path) {
                installNote = "run install.sh, or open the installed ~/Applications/Headroom.app"
            }
            return
        }
        if env.dryRun || env.mock {
            if !m.status(hostPath: d.hostPath, extensionId: d.extensionId).isOK { installNote = "dry run: would install it" }
            return
        }
        do { try m.repair(hostPath: d.hostPath, extensionId: d.extensionId) }
        catch { installNote = "could not write it: \(error)" }
    }

    func update(helperConnected: Bool) {
        let installed = FileManager.default.fileExists(atPath: env.nativeHostManifest)
        step1.stringValue = installed ? "✓ 1. Bridge file installed"
            : "1. Bridge file not installed yet" + (installNote.map { " (\($0))" } ?? "")
        step1.textColor = installed ? .systemGreen : .secondaryLabelColor
        step3.stringValue = helperConnected ? "✓ 3. Helper connected" : "3. Waiting for the helper…"
        step3.textColor = helperConnected ? .systemGreen : .secondaryLabelColor
    }

    @objc private func copyExtensionsURL() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("chrome://extensions", forType: .string)
    }
    @objc private func copyFolder() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(env.extensionDir, forType: .string)
    }
    @objc func close() { window.sheetParent?.endSheet(window) }
}

// MARK: - Inline notes (§6.1 empty and error states)

@MainActor final class NoteView: NSView {
    init(row: Row, target: AnyObject, clear: Selector, setup: Selector) {
        super.init(frame: .zero)
        var views: [NSView] = []
        let symbol: String
        var color = NSColor.secondaryLabelColor
        switch row.note {
        case .helperStale: symbol = "exclamationmark.triangle.fill"; color = .systemOrange
        case .noMatches: symbol = "line.3.horizontal.decrease.circle"
        case .perTabUnavailable: symbol = "info.circle"
        case .helperBlind: symbol = "eye.slash"; color = .systemOrange
        case .waitingForHelper: symbol = "hourglass"
        case .dockerDisk: symbol = "internaldrive"
        default: symbol = "info.circle"
        }
        toolTip = row.tooltip
        views.append(NSImageView(image: Theme.symbol(symbol, size: 11, color: color) ?? NSImage()))
        views.append(NSTextField.label(row.title, font: Theme.small, color: color))
        switch row.note {
        case .noMatches: views.append(NSButton.make("Clear", target: target, action: clear, small: true))
        case .perTabUnavailable: views.append(NSButton.make("Set up…", target: target, action: setup, small: true))
        default: break
        }
        let s = NSStackView.h(views, spacing: 6)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.centerYAnchor.constraint(equalTo: centerYAnchor),
            s.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
