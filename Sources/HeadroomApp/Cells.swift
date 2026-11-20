// Outline nodes, cell views and row views (§6.1): name cell with icon/monogram, glyphs and badge; memory
// cell with the 48 px bar; section (group) cells; the gutter bracket for shared renderers; full-width card
// and note rows.

import AppKit
import HeadroomActions
import HeadroomContracts

/// Reference wrapper NSOutlineView needs; reused across refreshes by row id so expansion state survives.
@MainActor final class Node: NSObject {
    var row: Row
    var children: [Node] = []
    weak var parent: Node?
    init(_ row: Row) { self.row = row }
    var id: String { row.id }
}

// MARK: - Name

@MainActor final class MonogramView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var color = NSColor.gray { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                    .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }
}

@MainActor final class NameCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("name")
    let icon = NSImageView()
    let mono = MonogramView()
    let title = NSTextField.label()
    let badge = NSTextField.label(font: Theme.small, color: .secondaryLabelColor)
    let glyphs = NSStackView()
    private var pulsing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        icon.translatesAutoresizingMaskIntoConstraints = false
        mono.translatesAutoresizingMaskIntoConstraints = false
        glyphs.orientation = .horizontal; glyphs.spacing = 3
        glyphs.translatesAutoresizingMaskIntoConstraints = false
        glyphs.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        for v in [icon, mono, title, glyphs, badge] as [NSView] { addSubview(v) }
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            mono.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            mono.centerYAnchor.constraint(equalTo: centerYAnchor),
            mono.widthAnchor.constraint(equalToConstant: 16), mono.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphs.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 5),
            glyphs.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: glyphs.trailingAnchor, constant: 5),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ r: Row) {
        if let m = r.monogram {
            mono.isHidden = false; icon.isHidden = true
            mono.text = m; mono.color = Theme.monogramColor(r.location.isEmpty ? m : r.location)
            mono.alphaValue = r.glyphs.contains(.sleeping) ? 0.45 : 1
        } else {
            mono.isHidden = true; icon.isHidden = false
            icon.image = Theme.icon(for: r)
        }
        title.stringValue = r.title
        title.textColor = r.isLocked ? .secondaryLabelColor : (r.glyphs.contains(.sleeping) ? .secondaryLabelColor : .labelColor)
        title.font = r.kind == .window || r.kind == .subgroup || r.kind == .chromeItself
            ? NSFont.systemFont(ofSize: 12.5, weight: .medium) : Theme.body
        badge.stringValue = r.badge ?? ""
        badge.textColor = r.badge?.hasPrefix("+") == true ? .systemPurple : .secondaryLabelColor
        badge.isHidden = r.badge == nil
        glyphs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var hasBusy = false
        for g in r.glyphs {
            let spec = Theme.glyph(g)
            let size: CGFloat = g == .busy ? 7 : 10
            let iv = NSImageView(image: Theme.symbol(spec.symbol, size: size, color: spec.color) ?? NSImage())
            iv.toolTip = spec.help
            if g == .busy { hasBusy = true; iv.wantsLayer = true; addPulse(iv) }
            if let t = spec.text {
                let l = NSTextField.label(t, font: Theme.monoSmall, color: spec.color)
                let s = NSStackView.h([iv, l], spacing: 1)
                s.toolTip = spec.help
                glyphs.addArrangedSubview(s)
            } else {
                glyphs.addArrangedSubview(iv)
            }
        }
        pulsing = hasBusy
        toolTip = r.tooltip
    }

    private func addPulse(_ v: NSView) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1; a.toValue = 0.35; a.duration = 0.9; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        v.layer?.add(a, forKey: "pulse")
    }
}

// MARK: - Text

@MainActor final class TextCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("text")
    let label = NSTextField.label(font: Theme.small, color: .secondaryLabelColor)
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ s: String, color: NSColor = .secondaryLabelColor, font: NSFont = Theme.small,
                   align: NSTextAlignment = .left, truncateMiddle: Bool = false) {
        label.stringValue = s; label.textColor = color; label.font = font; label.alignment = align
        label.lineBreakMode = truncateMiddle ? .byTruncatingMiddle : .byTruncatingTail
    }
}

// MARK: - Memory

@MainActor final class BarView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var color: NSColor = Theme.barGrey { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 48, height: 6) }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: bounds.midY - 3, width: bounds.width, height: 6)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        guard fraction > 0 else { return }
        var r = track
        r.size.width = max(2, bounds.width * min(1, fraction))
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
    }
}

@MainActor final class MemoryCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("memory")
    let label = NSTextField.label(font: Theme.mono)
    let bar = BarView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        label.alignment = .right
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label); addSubview(bar)
        textField = label
        NSLayoutConstraint.activate([
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bar.widthAnchor.constraint(equalToConstant: 48),
            bar.heightAnchor.constraint(equalToConstant: 8),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: bar.leadingAnchor, constant: -8),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ r: Row, max: Bytes, showBar: Bool) {
        label.stringValue = Fmt.bytes(r.bytes, approx: r.approx)
        label.textColor = r.bytes == nil ? .tertiaryLabelColor : (r.isLocked ? .secondaryLabelColor : .labelColor)
        label.toolTip = r.rss.map { "RSS \(ByteFormat.short($0))" } ?? (r.bytes == nil ? "Per-tab memory unavailable" : nil)
        bar.isHidden = !showBar || r.bytes == nil
        if let b = r.bytes, max > 0 {
            bar.fraction = CGFloat(Double(b) / Double(max))
            bar.color = Theme.barColor(b)
        }
    }
}

// MARK: - Section (group row, spans the full width)

@MainActor final class SectionCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("section")
    let title = NSTextField.label(font: Theme.section, color: .secondaryLabelColor)
    let badge = NSTextField.label(font: Theme.small, color: .tertiaryLabelColor)
    let total = NSTextField.label(font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: .labelColor)
    let swatch = NSView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 2
        swatch.translatesAutoresizingMaskIntoConstraints = false
        total.alignment = .right
        total.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [swatch, title, badge, total] as [NSView] { addSubview(v) }
        textField = title
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 8), swatch.heightAnchor.constraint(equalToConstant: 8),
            title.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: total.leadingAnchor, constant: -8),
            total.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -68),
            total.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ r: Row) {
        title.stringValue = r.title
        badge.stringValue = r.badge ?? ""
        total.stringValue = r.bytes.map { ByteFormat.short($0) } ?? ""
        let c: NSColor = switch r.section {
        case .chrome: Theme.chrome
        case .claude: Theme.claude
        case .leftovers: Theme.leftovers
        case .docker: Theme.docker
        }
        swatch.layer?.backgroundColor = c.cgColor
    }
}

// MARK: - Row views

@MainActor final class ItemRowView: NSTableRowView {
    var bracket: Bracket? { didSet { needsDisplay = true } }
    var bracketX: CGFloat = 0
    var locked = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let b = bracket else { return }
        let x = bracketX
        let path = NSBezierPath()
        let top = b == .top ? bounds.midY : bounds.minY
        let bottom = b == .bottom ? bounds.midY : bounds.maxY
        // Flipped: minY is the top of the row.
        path.move(to: NSPoint(x: x, y: top))
        path.line(to: NSPoint(x: x, y: bottom))
        if b == .top || b == .bottom {
            path.move(to: NSPoint(x: x, y: bounds.midY))
            path.line(to: NSPoint(x: x + 5, y: bounds.midY))
        }
        path.lineWidth = 1.5
        NSColor.systemTeal.withAlphaComponent(0.8).setStroke()
        path.stroke()
    }
}

/// Full-width custom content (the Chrome setup card, inline notes).
@MainActor final class ContentRowView: NSTableRowView {
    let content: NSView
    init(content: NSView, inset: CGFloat) {
        self.content = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isSelected: Bool { get { false } set {} }
}
