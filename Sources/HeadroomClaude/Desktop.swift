// SPEC §7.6 Jump, steps 4–5: the parts outside tmux (Ghostty focus, clipboard). Behind a protocol so tests
// record the calls instead of touching the user's desktop.

import AppKit
import CoreServices
import Foundation
import HeadroomContracts
import HeadroomCore

public protocol ClaudeDesktop: Sendable {
    /// Step 4: after the tmux client was switched, bring its terminal forward (the Ghostty window named
    /// `windowName` if Automation is granted and one matches, else just activate Ghostty).
    func focusTerminal(windowName: String?) async
    /// Step 5: no tmux client is attached. Copy `attachCommand` and open Ghostty.
    func noClientAttached(attachCommand: String) async
}

public struct GhosttyDesktop: ClaudeDesktop {
    public static let bundleId = "com.mitchellh.ghostty"
    public init() {}

    public func focusTerminal(windowName: String?) async {
        if let name = windowName, !name.isEmpty, Self.automationGranted() {
            let script = "tell application \"Ghostty\" to focus (first terminal whose name is \(Self.appleScriptString(name)))"
            let r = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 3)
            if r.ok { await activate(); return }
        }
        await activate()
    }

    /// pbcopy + `open -a Ghostty`: works from the app and the CLI alike, and never needs the main thread
    /// (the app's `--dump-json` path blocks it).
    public func noClientAttached(attachCommand: String) async {
        _ = await Shell.run("/usr/bin/pbcopy", [], timeout: 3, stdin: Data(attachCommand.utf8))
        _ = await Shell.run("/usr/bin/open", ["-a", "Ghostty"], timeout: 5)
    }

    /// NSRunningApplication.activate brings up Ghostty's last-key window (usually the most active client).
    func activate() async {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first
        if app?.activate() != true { _ = await Shell.run("/usr/bin/open", ["-a", "Ghostty"], timeout: 5) }
    }

    /// True only when Automation of Ghostty is already granted. Never prompts (askUserIfNeeded = false).
    public static func automationGranted() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        return status == noErr
    }

    /// An AppleScript string literal ("…" with \ and " escaped).
    public static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Records calls; for tests.
public final class RecordingDesktop: ClaudeDesktop, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    public init() {}
    public var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    public func focusTerminal(windowName: String?) async {
        lock.withLock { _calls.append("focus:\(windowName ?? "")") }
    }
    public func noClientAttached(attachCommand: String) async {
        lock.withLock { _calls.append("noClient:\(attachCommand)") }
    }
}
