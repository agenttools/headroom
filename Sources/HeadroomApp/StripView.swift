// The memory strip (§6.1): "39.8 of 48 GB used ● Normal Swap 3.0/4.0 GB Compressed 6.1 GB … updated 2s ago",
// the segmented bar (Chrome, Claude, Leftovers, Other apps, System, Free) with the selection's "frees"
// drawn as a hatch inside the Chrome/Claude/Leftovers segments, and the legend.

import AppKit
import HeadroomActions
import HeadroomContracts

@MainActor final class StripView: NSView {
    struct Model: Equatable {
        var system: SystemMemory = .zero
        var chrome: Bytes = 0
        var claude: Bytes = 0
        var leftovers: Bytes = 0
        /// The Docker VM's footprint on this Mac (0 when there is none or it cannot be identified).
        var docker: Bytes = 0
        var freesChrome: Bytes = 0
        var freesClaude: Bytes = 0
        var freesLeftovers: Bytes = 0
        var updated: Date = .distantPast
        var stale = false
        var mock = false
        var dryRun = false
        var frees: Bytes { freesChrome + freesClaude + freesLeftovers }
    }

    /// Only the parts that changed are redrawn: the bar and the text lines on model changes, the small
    /// "updated Xs ago" label once a second. (Redrawing the whole strip every second cost ~90 MB of
    /// graphics memory in backing stores.)
    var model = Model() {
        didSet {
            guard model != oldValue else { return }
            var barModel = model; barModel.updated = .distantPast
            var oldBar = oldValue; oldBar.updated = .distantPast
            if barModel != oldBar { bar.model = model; updateText() }
            updateAge()
        }
    }
    let info = NSButton()
    private let line1 = NSTextField.label()
    private let age = NSTextField.label(font: Theme.small, color: .tertiaryLabelColor)
    private let legend = NSTextField.label()
    private let bar = StripBar()
    private var ageTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        info.image = Theme.symbol("info.circle", size: 12, color: .secondaryLabelColor)
        info.isBordered = false
        info.target = self
        info.action = #selector(showInfo)
        info.toolTip = "What the numbers mean"
        info.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        age.alignment = .right
        age.setContentCompressionResistancePriority(.required, for: .horizontal)
        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
        for v in [line1, age, info, bar, legend, sep] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            line1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            line1.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            line1.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -12),
            info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            info.centerYAnchor.constraint(equalTo: line1.centerYAnchor),
            age.trailingAnchor.constraint(equalTo: info.leadingAnchor, constant: -8),
            age.centerYAnchor.constraint(equalTo: line1.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bar.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 7),
            bar.heightAnchor.constraint(equalToConstant: 16),
            legend.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            legend.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 7),
            legend.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateText(); updateAge()
        ageTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAge() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func showInfo() {
        let p = NSPopover()
        p.behavior = .transient
        let vc = NSViewController()
        let t = NSTextField.wrapping(
            "Memory is each process's footprint, the same as Activity Monitor's Memory column. It includes compressed and swapped memory and excludes shared read-only code. 'Frees ≈' counts only processes that would exit completely. After closing, Headroom shows the measured drop.",
            font: Theme.small, width: 300)
        let box = NSView()
        box.addSubview(t)
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            t.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            t.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            t.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            box.widthAnchor.constraint(equalToConstant: 324),
        ])
        vc.view = box
        p.contentViewController = vc
        p.show(relativeTo: info.bounds, of: info, preferredEdge: .maxY)
    }

    static func gb(_ b: Bytes) -> String { String(format: "%.1f", Double(b) / 1_073_741_824) }

    private func updateText() {
        let m = model, s = m.system
        let line = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor = .labelColor, _ font: NSFont = Theme.body) {
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        if s.total > 0 {
            add("\(Self.gb(s.used)) of \(Self.gb(s.total)) GB used", .labelColor, NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold))
            let (pc, pn): (NSColor, String) = switch s.pressure {
            case .normal: (.systemGreen, "Normal"); case .warning: (.systemYellow, "Warning"); case .critical: (.systemRed, "Critical")
            }
            add("   ● ", pc); add(pn, .secondaryLabelColor)
            add("   Swap \(Self.gb(s.swapUsed))/\(Self.gb(s.swapTotal)) GB", .secondaryLabelColor, Theme.mono)
            add("   Compressed \(Self.gb(s.compressed)) GB", .secondaryLabelColor, Theme.mono)
        } else {
            add("Reading memory…", .secondaryLabelColor)
        }
        line1.attributedStringValue = line

        let lg = NSMutableAttributedString()
        func item(_ color: NSColor, _ glyph: String, _ label: String) {
            lg.append(NSAttributedString(string: glyph + " ", attributes: [.font: Theme.small, .foregroundColor: color]))
            lg.append(NSAttributedString(string: label + "    ", attributes: [.font: Theme.small, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let p = StripBar.parts(m)
        item(Theme.chrome, "■", "Chrome \(Self.gb(m.chrome))")
        item(Theme.claude, "■", "Claude \(Self.gb(m.claude))")
        item(Theme.leftovers, "■", "Leftovers \(Self.gb(m.leftovers))")
        if m.docker > 0 { item(Theme.docker, "■", "Docker \(Self.gb(m.docker))") }
        if m.frees > 0 { item(.labelColor, "▨", "selection frees ≈\(Self.gb(m.frees))") }
        item(Theme.other, "■", "Other \(Self.gb(p.other))")
        item(Theme.system, "■", "System \(Self.gb(p.system))")
        item(.tertiaryLabelColor, "□", "Free \(Self.gb(p.free))")
        if p.excess > 0 {
            // Footprints include compressed (at full size) and swapped memory; see ⓘ.
            item(.systemOrange, "≠", "footprints exceed RAM in use by \(Self.gb(p.excess)) GB (compressed/swapped)")
        }
        // One line: an attributed string without a paragraph style wraps, and the second line was cut off.
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = .byTruncatingTail
        lg.addAttribute(.paragraphStyle, value: oneLine, range: NSRange(location: 0, length: lg.length))
        legend.attributedStringValue = lg
    }

    private func updateAge() {
        let m = model
        var tags: [String] = []
        if m.mock { tags.append("MOCK DATA") }
        if m.dryRun { tags.append("DRY RUN") }
        let s = NSMutableAttributedString()
        if !tags.isEmpty {
            s.append(NSAttributedString(string: tags.joined(separator: " · ") + "   ",
                                        attributes: [.font: Theme.smallBold, .foregroundColor: NSColor.systemOrange]))
        }
        let text: String
        if m.updated == .distantPast { text = "not updated yet" } else {
            let secs = max(0, Date().timeIntervalSince(m.updated))
            text = "updated " + (secs < 60 ? "\(Int(secs))s" : Fmt.age(secs)) + " ago"
        }
        s.append(NSAttributedString(string: text, attributes: [.font: Theme.small,
                                                                .foregroundColor: m.stale ? NSColor.systemOrange : NSColor.tertiaryLabelColor]))
        if age.attributedStringValue != s { age.attributedStringValue = s }
    }
}

/// The segmented bar with the selection hatch. Redrawn only when its numbers change.
@MainActor final class StripBar: NSView {
    var model = StripView.Model() { didSet { needsDisplay = true } }

    struct Parts {
        var chrome, claude, leftovers, docker, other, system, free: Bytes
        /// Section footprints are scaled by this to fit the RAM in use (1 = no scaling).
        var scale: Double
        /// Σ section footprints − (used − wired) when positive: footprints count compressed pages at full
        /// size and swapped pages too, so under pressure they add up to more than the RAM they sit in.
        var excess: Bytes
    }

    /// Footprints (Chrome, Claude, Leftovers, the Docker VM) and `used` are different units: footprint counts compressed
    /// pages uncompressed plus swap. When the footprints exceed the RAM in use (minus wired), they are scaled
    /// down so the bar ends at `used` and never overflows; the legend says so.
    static func parts(_ m: StripView.Model) -> Parts {
        let s = m.system
        let systemBytes = s.wired
        let room = s.used > systemBytes ? s.used - systemBytes : 0
        let known = m.chrome + m.claude + m.leftovers + m.docker
        let free = s.total > s.used ? s.total - s.used : 0
        if known > room && known > 0 {
            let scale = Double(room) / Double(known)
            func sc(_ b: Bytes) -> Bytes { Bytes(Double(b) * scale) }
            return Parts(chrome: sc(m.chrome), claude: sc(m.claude), leftovers: sc(m.leftovers),
                         docker: sc(m.docker), other: 0,
                         system: systemBytes, free: free, scale: scale, excess: known - room)
        }
        return Parts(chrome: m.chrome, claude: m.claude, leftovers: m.leftovers, docker: m.docker,
                     other: room - known,
                     system: systemBytes, free: free, scale: 1, excess: 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = model
        let bar = bounds
        let total = Double(max(m.system.total, 1))
        let p = Self.parts(m)
        func sc(_ b: Bytes) -> Bytes { Bytes(Double(b) * p.scale) }
        let segs: [(Bytes, NSColor, Bytes)] = [
            (p.chrome, Theme.chrome, sc(m.freesChrome)), (p.claude, Theme.claude, sc(m.freesClaude)),
            (p.leftovers, Theme.leftovers, sc(m.freesLeftovers)), (p.docker, Theme.docker, 0),
            (p.other, Theme.other, 0),
            (p.system, Theme.system, 0), (p.free, Theme.free, 0),
        ]
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).addClip()
        Theme.free.setFill(); bar.fill()
        var x = bar.minX
        for (b, color, frees) in segs where b > 0 {
            let w = bar.width * CGFloat(Double(b) / total)
            let r = NSRect(x: x, y: bar.minY, width: w, height: bar.height)
            color.setFill(); r.fill()
            if frees > 0 {
                let fw = min(w, bar.width * CGFloat(Double(frees) / total))
                hatch(NSRect(x: r.maxX - fw, y: r.minY, width: fw, height: r.height))
            }
            NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill()
            NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func hatch(_ r: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1.5
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: NSPoint(x: x, y: r.minY))
            p.line(to: NSPoint(x: x + r.height, y: r.maxY))
            x += 4
        }
        p.stroke()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
