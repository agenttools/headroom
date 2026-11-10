// Colors, fonts and SF Symbols shared by the views.

import AppKit
import HeadroomActions
import HeadroomContracts

@MainActor enum Theme {
    static let chrome = NSColor.systemBlue
    static let claude = NSColor.systemPurple
    static let leftovers = NSColor.systemOrange
    static let other = NSColor.systemGray.withAlphaComponent(0.55)
    static let system = NSColor.systemGray.withAlphaComponent(0.85)
    static let free = NSColor.quaternaryLabelColor

    static let barGrey = NSColor.systemGray.withAlphaComponent(0.6)
    static let barAmber = NSColor.systemYellow
    static let barRed = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.2, alpha: 1)

    static func barColor(_ b: Bytes) -> NSColor {
        b < .mb(300) ? barGrey : b < .gb(1) ? barAmber : barRed
    }

    static func tone(_ t: Tone) -> NSColor {
        switch t {
        case .plain: .labelColor
        case .busy: .systemGreen
        case .idle: .secondaryLabelColor
        case .warn: .systemOrange
        case .locked: .tertiaryLabelColor
        case .muted: .secondaryLabelColor
        }
    }

    static let body = NSFont.systemFont(ofSize: 13)
    static let small = NSFont.systemFont(ofSize: 11)
    static let smallBold = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let monoSmall = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let code = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let section = NSFont.systemFont(ofSize: 11, weight: .bold)

    static func symbol(_ name: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
                       color: NSColor? = nil) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        if let color { cfg = cfg.applying(.init(paletteColors: [color])) }
        return img.withSymbolConfiguration(cfg)
    }

    static func glyph(_ g: Glyph) -> (symbol: String, color: NSColor, text: String?, help: String) {
        switch g {
        case .locked: ("lock.fill", .tertiaryLabelColor, nil, "Locked: Headroom never closes this")
        case .visible: ("eye.fill", .systemTeal, nil, "Visible or current tmux pane")
        case .busy: ("circle.fill", .systemGreen, nil, "Busy")
        case .remote: ("antenna.radiowaves.left.and.right", .systemIndigo, nil, "Remote Control is on")
        case .shared(let n): ("link", .secondaryLabelColor, "×\(n)", "Shares a renderer with \(n - 1) other tab\(n == 2 ? "" : "s")")
        case .sleeping: ("moon.zzz.fill", .secondaryLabelColor, nil, "Sleeping (discarded)")
        case .pinned: ("pin.fill", .secondaryLabelColor, nil, "Pinned tab")
        case .audible: ("speaker.wave.2.fill", .systemOrange, nil, "Playing audio")
        case .incognito: ("eyeglasses", .secondaryLabelColor, nil, "Incognito")
        case .worktree: ("arrow.triangle.branch", .secondaryLabelColor, nil, "Git worktree")
        case .automation: ("gearshape.2", .secondaryLabelColor, nil, "Automation browser")
        case .stale: ("exclamationmark.triangle.fill", .systemOrange, nil, "Stale")
        }
    }

    static func icon(for r: Row) -> NSImage? {
        switch r.kind {
        case .window: symbol("macwindow", size: 12, color: .secondaryLabelColor)
        case .chromeItself: symbol("shippingbox", size: 12, color: .secondaryLabelColor)
        case .overhead: symbol("cpu", size: 11, color: .tertiaryLabelColor)
        case .session: symbol("terminal", size: 11, color: r.isLocked ? .tertiaryLabelColor : .secondaryLabelColor)
        case .process: symbol(r.glyphs.contains(.automation) ? "globe" : "gearshape", size: 11, color: .tertiaryLabelColor)
        case .leftover: symbol("gearshape.2", size: 11, color: .systemOrange)
        case .subgroup: symbol("rectangle.split.3x1", size: 11, color: .secondaryLabelColor)
        default: nil
        }
    }

    /// Stable hue for a monogram.
    static func monogramColor(_ s: String) -> NSColor {
        var h: UInt32 = 5381
        for u in s.unicodeScalars { h = (h &* 33) &+ u.value }
        return NSColor(calibratedHue: CGFloat(h % 360) / 360, saturation: 0.55, brightness: 0.78, alpha: 1)
    }
}

extension NSTextField {
    @MainActor static func label(_ s: String = "", font: NSFont = Theme.body, color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    @MainActor static func wrapping(_ s: String, font: NSFont = Theme.body, color: NSColor = .labelColor,
                                    width: CGFloat) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = font
        f.textColor = color
        f.preferredMaxLayoutWidth = width
        f.translatesAutoresizingMaskIntoConstraints = false
        f.isSelectable = true
        return f
    }
}

extension NSButton {
    @MainActor static func make(_ title: String, target: AnyObject?, action: Selector?, small: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .push
        if small { b.controlSize = .small; b.font = Theme.small }
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}

extension NSStackView {
    @MainActor static func h(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal; s.spacing = spacing; s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    @MainActor static func v(_ views: [NSView], spacing: CGFloat = 6, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.spacing = spacing; s.alignment = alignment
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
}
