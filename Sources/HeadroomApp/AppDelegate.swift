// AppDelegate: one window, quits when it closes (DECISIONS Q3), reopens on a Dock click, main menu with the
// §7.2 keys.

import AppKit
import HeadroomActions
import HeadroomChrome
import HeadroomContracts

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let ctx: HeadroomContext
    let env: HeadroomEnv
    let qa: QAOptions
    var controller: MainWindowController?

    init(ctx: HeadroomContext, env: HeadroomEnv, qa: QAOptions) {
        self.ctx = ctx; self.env = env; self.qa = qa
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Mock runs keep their preferences apart from the real app's (window frame, columns, filters).
        // QA runs start from clean preferences every time.
        var prefs = UserDefaults.standard
        if ctx.isMock || qa.isActive {
            let suite = qa.isActive ? "dev.adder.headroom.qa" : "dev.adder.headroom.mock"
            if qa.isActive { UserDefaults.standard.removePersistentDomain(forName: suite) }
            prefs = UserDefaults(suiteName: suite) ?? .standard
        }
        let c = MainWindowController(ctx: ctx, env: env, prefs: prefs, persistLayout: !ctx.isMock && !qa.isActive)
        controller = c
        NSApp.mainMenu = buildMenu(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.window?.initialFirstResponder = c.outlineCtl.outline
        c.window?.makeFirstResponder(c.outlineCtl.outline)
        NSApp.activate()
        if ctx.isMock || qa.isPassive { qa.run(c) }
        if let chrome = (ctx.world as? LiveWorld)?.chrome { wireChrome(chrome, c) }
    }

    /// Live only: refresh on the helper's `dirty` / connect / disconnect events (SPEC §9), and check the
    /// native-messaging bridge file (SPEC §8.4: repaired at launch when its path or id is wrong).
    private func wireChrome(_ chrome: ChromeSource, _ c: MainWindowController) {
        chrome.setEventHandler { event in
            switch event {
            case .dirty, .hello, .disconnected:
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak c] in c?.refreshFromEvent() } }
            default: break
            }
        }
        // Only the installed bundle (~/Applications/Headroom.app) repairs, only a file that already exists
        // (install.sh / the setup sheet create it), and never in dry run: dry run changes nothing outside
        // Headroom's own support folder. A build/ or copied bundle only logs the mismatch.
        let m = HostManifest(env: env)
        guard FileManager.default.fileExists(atPath: m.path) else { return }
        if !env.dryRun, let d = HostManifest.installedBundleDefaults(env: env) {
            if let changed = try? m.repair(hostPath: d.hostPath, extensionId: d.extensionId), changed {
                NSLog("Headroom: repaired the native-messaging bridge file at %@", m.path)
            }
        } else if let d = HostManifest.bundleDefaults(),
                  !m.status(hostPath: d.hostPath, extensionId: d.extensionId).isOK {
            NSLog("Headroom: the native-messaging bridge file points elsewhere (%@); not changed by this copy of the app", m.path)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        (ctx.world as? LiveWorld)?.chrome.stop()     // removes run/app.sock
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// ⌘W / ⌘Q while a close is still running (sessions get up to 5 s to exit, then background processes and
    /// leftovers are stopped and Recently Closed is written): hide the window and quit when it finishes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = controller, c.inFlightCloses > 0 else { return .terminateNow }
        c.window?.orderOut(nil)
        c.onClosesFinished = { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Menu

    private func buildMenu(_ c: MainWindowController) -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = m
            main.addItem(i)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                  target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.tag = tag
            return i
        }
        let sep = { NSMenuItem.separator() }
        sub("Headroom", [
            item("About Headroom", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            sep(),
            item("Hide Headroom", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            sep(),
            item("Quit Headroom", #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub("File", [
            item("Refresh Now", #selector(MainWindowController.menuRefresh(_:)), "r", target: c),
            sep(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        sub("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z", [.command, .shift]),
            sep(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            sep(),
            item("Filter…", #selector(MainWindowController.menuFind(_:)), "f", target: c),
        ])
        let select = NSMenu(title: "Select")
        select.delegate = PresetMenuDelegate.shared
        PresetMenuDelegate.shared.controller = c
        let selectItem = NSMenuItem(title: "Select", action: nil, keyEquivalent: "")
        selectItem.submenu = select
        let backspace = String(UnicodeScalar(8))
        sub("Items", [
            item("Close", #selector(MainWindowController.menuClose(_:)), backspace, [], target: c),
            item("Close Now", #selector(MainWindowController.menuCloseNow(_:)), backspace, [.option], target: c),
            item("Sleep Tab", #selector(MainWindowController.menuSleep(_:)), backspace, [.control], target: c),
            sep(),
            item("Jump", #selector(MainWindowController.menuJump(_:)), "\r", [], target: c),
            item("Peek", #selector(MainWindowController.menuPeek(_:)), " ", [], target: c),
            sep(),
            item("Reveal Folder in Finder", #selector(MainWindowController.menuReveal(_:)), "r", [.command, .shift], target: c),
            item("Open Transcript", #selector(MainWindowController.menuTranscript(_:)), "o", target: c),
            item("Select Tabs on the Same Site", #selector(MainWindowController.menuSameSite(_:)), "s", [.command, .shift], target: c),
            selectItem,
        ])
        let chromeGroup = NSMenu(title: "Group Chrome By")
        chromeGroup.addItem(item("Window", #selector(MainWindowController.menuChromeGrouping(_:)), "", [], target: c, tag: 0))
        chromeGroup.addItem(item("None", #selector(MainWindowController.menuChromeGrouping(_:)), "", [], target: c, tag: 1))
        let claudeGroup = NSMenu(title: "Group Claude By")
        claudeGroup.addItem(item("None", #selector(MainWindowController.menuClaudeGrouping(_:)), "", [], target: c, tag: 0))
        // Tag 1 is ClaudeGrouping.tmux, which groups by tmux session or Rex session (the tag indexes allCases).
        claudeGroup.addItem(item("tmux or Rex Session", #selector(MainWindowController.menuClaudeGrouping(_:)), "", [], target: c, tag: 1))
        let cg = NSMenuItem(title: "Group Chrome By", action: nil, keyEquivalent: ""); cg.submenu = chromeGroup
        let lg = NSMenuItem(title: "Group Claude By", action: nil, keyEquivalent: ""); lg.submenu = claudeGroup
        sub("View", [
            item("All", #selector(MainWindowController.menuScope(_:)), "1", target: c, tag: 0),
            item("Chrome", #selector(MainWindowController.menuScope(_:)), "2", target: c, tag: 1),
            item("Claude", #selector(MainWindowController.menuScope(_:)), "3", target: c, tag: 2),
            sep(), cg, lg,
        ])
        sub("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Recently Closed", #selector(MainWindowController.menuRecentlyClosed(_:)), "y", target: c),
        ])
        return main
    }
}

@MainActor final class PresetMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = PresetMenuDelegate()
    weak var controller: MainWindowController?
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        controller?.populatePresets(menu)
    }
}
