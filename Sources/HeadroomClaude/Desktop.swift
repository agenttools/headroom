// SPEC §7.6 Jump, steps 4–5: the parts outside tmux and Rex (Ghostty focus, clipboard, bringing Rex.app forward).
// Behind a protocol so tests record the calls instead of touching the user's desktop.

import AppKit
import CoreServices
import Foundation
import HeadroomContracts
import HeadroomCore

/// What `focusTerminal` managed to do. Only `.exact` means the user is looking at the right terminal.
public enum TerminalFocus: Sendable, Equatable {
    /// The terminal on the given tty was focused and its app brought forward.
    case exact
    /// No tty was given (the session is not in tmux): the terminal app was brought forward, nothing more.
    case appOnly
    /// Automation ▸ Ghostty is not granted (denied, or never asked and this process may not ask). App forward only.
    case notAllowed
    /// Ghostty has no terminal on that tty (the client runs in another app, or Ghostty is not running). App forward
    /// only.
    case notFound
    /// The focus script failed for another reason (the text says why). App forward only.
    case failed(String)
}

public protocol ClaudeDesktop: Sendable {
    /// Step 4: after the tmux client on `tty` was switched, bring its terminal forward: the Ghostty terminal whose
    /// tty is `tty` when Automation is granted, else just Ghostty. `tty` nil (a session outside tmux): just Ghostty.
    func focusTerminal(tty: String?) async -> TerminalFocus
    /// Step 5: no tmux client is attached. Copy `attachCommand` and open Ghostty.
    func noClientAttached(attachCommand: String) async
    /// Rex Jump/Undo: bring Rex.app forward (opening a window if it has none).
    func focusRex() async
}

/// The live desktop: Ghostty for sessions in tmux (or in neither), Rex.app for sessions in Rex.
public struct GhosttyDesktop: ClaudeDesktop {
    public static let bundleId = "com.mitchellh.ghostty"
    /// Whether this process may show the macOS Automation prompt for Ghostty. The app sets it: the prompt then comes
    /// at the first Jump that needs it (SPEC §8.5), and macOS never shows it twice. The CLI never asks.
    public let mayAsk: Bool
    public init(mayAsk: Bool = false) { self.mayAsk = mayAsk }

    /// A tmux client's `client_tty` is the tty of the Ghostty terminal that shows it, and Ghostty's AppleScript
    /// dictionary has that tty (Ghostty 1.3+). So the terminal is found by tty, which is exact and unique. Its title
    /// is neither: it follows the tmux window name, which two clients can share and which changes while Claude works.
    public func focusTerminal(tty: String?) async -> TerminalFocus {
        guard let tty, !tty.isEmpty else { await activate(); return .appOnly }
        let outcome = await focusExact(tty: tty)
        await activate()            // `focus` puts the window in front of Ghostty's others; this brings Ghostty forward
        return outcome
    }

    private func focusExact(tty: String) async -> TerminalFocus {
        var permission = await Self.automation(ask: false)
        if permission == .notDetermined, mayAsk { permission = await Self.automation(ask: true) }
        switch permission {
        case .granted: break
        case .denied, .notDetermined: return .notAllowed
        case .notRunning: return .notFound
        case .other(let status): return .failed("macOS answered \(status) when asked about controlling Ghostty")
        }
        let r = await Shell.run("/usr/bin/osascript", ["-e", Self.focusScript(tty: tty)], timeout: 3)
        return Self.focusOutcome(ok: r.ok, stderr: r.stderr, timedOut: r.timedOut)
    }

    /// `tell application id "com.mitchellh.ghostty" to focus (first terminal whose tty is "<tty>")`.
    public static func focusScript(tty: String) -> String {
        "tell application id \(appleScriptString(bundleId)) to focus "
            + "(first terminal whose tty is \(appleScriptString(tty)))"
    }

    /// Reads osascript's result. Ghostty answers -1719 (or -1728) when no terminal has that tty, and macOS answers
    /// -1743 when Automation is not permitted after all.
    public static func focusOutcome(ok: Bool, stderr: String, timedOut: Bool) -> TerminalFocus {
        if ok { return .exact }
        if timedOut { return .failed("Ghostty did not answer") }
        if stderr.contains("(-1719)") || stderr.contains("(-1728)") { return .notFound }
        if stderr.contains("(-1743)") { return .notAllowed }
        // "51:53: execution error: Ghostty got an error: … (-10000)" → "Ghostty got an error: … (-10000)"
        var said = stderr.split(separator: "\n").last.map(String.init) ?? ""
        if let r = said.range(of: "execution error: ") { said = String(said[r.upperBound...]) }
        said = said.trimmingCharacters(in: .whitespaces)
        return .failed(said.isEmpty ? "osascript failed" : said)
    }

    /// pbcopy + `open -b <Ghostty>`: works from the app and the CLI alike, and never needs the main thread
    /// (the app's `--dump-json` path blocks it).
    public func noClientAttached(attachCommand: String) async {
        _ = await Shell.run("/usr/bin/pbcopy", [], timeout: 3, stdin: Data(attachCommand.utf8))
        _ = await Shell.run("/usr/bin/open", ["-b", Self.bundleId], timeout: 5)
    }

    /// `open -b com.superlogical.rex` launches Rex or sends it a reopen event (which shows a window when it has none),
    /// with no Apple Events permission needed. Then waits up to 1 s for Rex to be the active app, because Rex's client
    /// actions (`do session.select`) need the app in front.
    public func focusRex() async {
        _ = await Shell.run("/usr/bin/open", ["-b", KnownPaths.rexAppBundleId], timeout: 5)
        for _ in 0..<20 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: KnownPaths.rexAppBundleId).first?.isActive == true {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Brings Ghostty forward with its front window on top (after `focus`, the terminal just focused; otherwise the
    /// window used last). NSRunningApplication.activate is only a request, because macOS activation is cooperative.
    /// So the result is checked for up to 0.5 s, and `open -b` (which also starts Ghostty) is the fallback.
    func activate() async {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first?.activate() == true {
            for _ in 0..<10 {
                if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first?.isActive == true {
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        _ = await Shell.run("/usr/bin/open", ["-b", Self.bundleId], timeout: 5)
    }

    /// The state of Automation ▸ Ghostty for this process.
    public enum Automation: Sendable, Equatable {
        case granted, denied, notDetermined, notRunning
        case other(OSStatus)

        public init(status: OSStatus) {
            switch status {
            case OSStatus(noErr): self = .granted
            case OSStatus(errAEEventNotPermitted): self = .denied                      // -1743
            case OSStatus(errAEEventWouldRequireUserConsent): self = .notDetermined    // -1744
            case OSStatus(procNotFound): self = .notRunning                            // -600
            default: self = .other(status)
            }
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` for Ghostty. With `ask: false` it never shows a prompt. With
    /// `ask: true` it shows the system prompt if the user has not decided yet and blocks until they answer, so it
    /// runs on a Dispatch queue (never the main thread, never a Swift concurrency thread).
    public static func automation(ask: Bool) async -> Automation {
        await withCheckedContinuation { (cont: CheckedContinuation<Automation, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
                guard let desc = target.aeDesc else { cont.resume(returning: .other(OSStatus(paramErr))); return }
                let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
                cont.resume(returning: Automation(status: status))
            }
        }
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
    private var _focusResult: TerminalFocus = .exact
    public init() {}
    public var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    /// What focusTerminal answers for a tty (a nil tty always answers .appOnly).
    public var focusResult: TerminalFocus {
        get { lock.withLock { _focusResult } }
        set { lock.withLock { _focusResult = newValue } }
    }
    public func focusTerminal(tty: String?) async -> TerminalFocus {
        lock.withLock {
            _calls.append("focus:\(tty ?? "")")
            return tty == nil ? .appOnly : _focusResult
        }
    }
    public func noClientAttached(attachCommand: String) async {
        lock.withLock { _calls.append("noClient:\(attachCommand)") }
    }
    public func focusRex() async {
        lock.withLock { _calls.append("rex:focus") }
    }
}
