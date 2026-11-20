// Headroom.app entry point.
//
//   Headroom                 live world (HEADROOM_MOCK=1 selects the mock world)
//   Headroom --mock          MockWorld + mock executor, dry run forced on (UI development, screenshots)
//   Headroom --dump-json     prints the WorldSnapshot and exits (SPEC §8.8)
//   Headroom --selftest [sys|ownership|claude|chrome]   read-only checks, exits 0 (pass) or 1 (SPEC §8.8)
//
// QA flags (honoured only with --mock, never against live data; the exception is the passive set
// --qa-snapshot / --qa-window-id-file / --qa-scope / --qa-filter, which also work live when HEADROOM_DRY_RUN=1):
//   --qa-window-id-file=<path>   writes the CGWindowID (for `screencapture -l`) once the list is filled
//   --qa-select=<id,id,…>        selects rows by id after the first refresh
//   --qa-close / --qa-close-now  then runs Close / Close Now on the selection (shows the sheet or the toast)
//   --qa-peek                    then opens Peek on the selection
//   --qa-recent                  then opens Recently Closed
//   --qa-filter=<text>           sets the filter
//   --qa-snapshot=<path.png>     renders the window (plus any sheet or popover over it) to a PNG, then quits
//   --qa-scope=chrome|claude     sets the scope
//   --qa-order-check=<path>      sort-freeze check (use HEADROOM_MOCK_JITTER=1), writes the result, quits
//   --qa-selection-check=<path>  Finder-style selection check with synthesized clicks and keys, quits
//   --qa-close-window            closes the window (the app must quit; the watchdog exits 3 if not)
//   --qa-undo-check=<path>       with --qa-select: ⌫, ⌘Z, ⇧⌘Z through the real menu and undo manager, quits
//   --qa-rex-check=<path>        Rex rows: Select ▾ submenu, grouping, glyph/Where, rex: filter, Peek, Jump; quits

import AppKit
import HeadroomActions
import HeadroomContracts
import HeadroomCore

let arguments = CommandLine.arguments
var env = HeadroomEnv.current
if arguments.contains("--mock") {
    env.mock = true
    env.dryRun = true
}

if arguments.contains("--dump-json") {
    let ctx = Headroom.context(env: env)
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var world = WorldSnapshot.empty
    Task.detached { world = await ctx.world.snapshot(); sem.signal() }
    sem.wait()
    let data = try HeadroomJSON.encoder().encode(world)
    FileHandle.standardOutput.write(data)
    print()
    exit(0)
}

if let i = arguments.firstIndex(where: { $0 == "--selftest" }) {
    let groups = arguments[(i + 1)...].filter { !$0.hasPrefix("-") }
    let known = Set(HeadroomSelfTest.groups)
    if let bad = groups.first(where: { !known.contains($0) }) {
        FileHandle.standardError.write(Data("unknown selftest group \(bad) (known: \(HeadroomSelfTest.groups.joined(separator: ", ")))\n".utf8))
        exit(1)
    }
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var report = SelfTestReport()
    let services = LiveServices(env: env)
    Task.detached { report = await HeadroomSelfTest.run(Array(groups), services: services); sem.signal() }
    sem.wait()
    services.chrome.stop()
    print(report.render())
    exit(report.passed ? 0 : 1)
}

struct QAOptions {
    var windowIdFile: String?
    var select: [String] = []
    var close = false
    var closeNow = false
    var peek = false
    var recent = false
    var filter: String?
    var snapshot: String?
    var scope: String?
    var orderCheck: String?
    var selectionCheck: String?
    var undoCheck: String?
    var rexCheck: String?
    var closeWindow = false

    var isActive = false
    /// Only --qa-snapshot / --qa-window-id-file / --qa-scope / --qa-filter: they read the window and never
    /// select, close or change anything, so they are allowed live, but only in dry run.
    var isPassive = false

    init(_ args: [String]) {
        isActive = args.contains { $0.hasPrefix("--qa-") }
        for a in args {
            func value(_ p: String) -> String? { a.hasPrefix(p) ? String(a.dropFirst(p.count)) : nil }
            if let v = value("--qa-window-id-file=") { windowIdFile = v }
            if let v = value("--qa-select=") { select = v.split(separator: ",").map(String.init) }
            if let v = value("--qa-filter=") { filter = v }
            if let v = value("--qa-snapshot=") { snapshot = v }
            if let v = value("--qa-scope=") { scope = v }
            if let v = value("--qa-order-check=") { orderCheck = v }
            if let v = value("--qa-selection-check=") { selectionCheck = v }
            if let v = value("--qa-undo-check=") { undoCheck = v }
            if let v = value("--qa-rex-check=") { rexCheck = v }
            if a == "--qa-close" { close = true }
            if a == "--qa-close-window" { closeWindow = true }
            if a == "--qa-close-now" { closeNow = true }
            if a == "--qa-peek" { peek = true }
            if a == "--qa-recent" { recent = true }
        }
        let passiveFlags = ["--qa-snapshot=", "--qa-window-id-file=", "--qa-scope=", "--qa-filter="]
        let qaArgs = args.filter { $0.hasPrefix("--qa-") }
        isPassive = !qaArgs.isEmpty && qaArgs.allSatisfy { a in passiveFlags.contains { a.hasPrefix($0) } }
            && HeadroomEnv.current.dryRun
    }

    @MainActor func run(_ c: MainWindowController) {
        let qa = self
        if isActive {
            // Watchdog: a QA run never outlives two minutes.
            Thread.detachNewThread { Thread.sleep(forTimeInterval: 120); exit(3) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                if let f = qa.filter {
                    c.filterForQA(f)
                }
                if let sc = qa.scope, let s = HeadroomActions.ListScope(rawValue: sc) { c.scopeForQA(s) }
                if qa.closeWindow { c.window?.performClose(nil); return }   // must quit the app (DECISIONS Q3)
                if let p = qa.orderCheck { c.orderCheckForQA(path: p); return }
                if let p = qa.selectionCheck { c.selectionCheckForQA(path: p); return }
                if let p = qa.undoCheck { c.undoCheckForQA(path: p, ids: qa.select); return }
                if let p = qa.rexCheck { c.rexCheckForQA(path: p); return }
                if !qa.select.isEmpty { c.debugSelect(qa.select) }
                if qa.close { c.debugClose(skipSheet: false) }
                if qa.closeNow { c.debugClose(skipSheet: true) }
                if qa.peek { c.outlinePeek() }
                if qa.recent {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        MainActor.assumeIsolated { c.window?.attachedSheet.map { c.window?.endSheet($0) }; c.menuRecentlyClosed(nil) }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (qa.recent ? 1.6 : 0.8)) {
                    MainActor.assumeIsolated {
                        if let path = qa.windowIdFile, let n = c.window?.windowNumber {
                            try? "\(n) \(c.debugRowCount)\n".write(toFile: path, atomically: true, encoding: .utf8)
                        }
                        if let path = qa.snapshot, let w = c.window {
                            // Live data can take a few seconds for the first snapshot: wait for rows (max 15 s).
                            @MainActor func shoot(_ tries: Int) {
                                if c.debugRowCount == 0 && tries > 0 {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        MainActor.assumeIsolated { shoot(tries - 1) }
                                    }
                                    return
                                }
                                QASnapshot.write(w, to: path)
                                exit(0)
                            }
                            shoot(qa.isPassive ? 30 : 0)
                        }
                    }
                }
            }
        }
    }
}

/// Renders the window's frame view (title bar, toolbar, content) and composites attached sheets and
/// popovers on top. Used for QA screenshots when screen recording is not available.
@MainActor enum QASnapshot {
    static func write(_ w: NSWindow, to path: String) {
        guard let frameView = w.contentView?.superview else { return }
        let scale = w.backingScaleFactor
        let size = frameView.bounds.size
        guard let base = render(frameView) else { return }
        let out = NSImage(size: size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        var overlays: [NSWindow] = []
        if let s = w.attachedSheet { overlays.append(s) }
        for child in NSApp.windows where child !== w && child.isVisible && child.className.contains("Popover") {
            overlays.append(child)
        }
        for o in overlays {
            guard let v = o.contentView?.superview ?? o.contentView, let img = render(v) else { continue }
            let r = NSRect(x: o.frame.minX - w.frame.minX, y: o.frame.minY - w.frame.minY,
                           width: o.frame.width, height: o.frame.height)
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowBlurRadius = 18; shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.set()
            img.draw(in: r)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        rep.size = size
        _ = scale
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func render(_ v: NSView) -> NSImage? {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.addRepresentation(rep)
        return img
    }
}

let ctx = Headroom.context(env: env)
let app = NSApplication.shared
let delegate = AppDelegate(ctx: ctx, env: env, qa: QAOptions(arguments))
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
