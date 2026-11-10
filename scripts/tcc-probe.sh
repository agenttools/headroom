#!/usr/bin/env bash
# tcc-probe.sh — SPEC §10 check, to run by hand: is the Automation (TCC) prompt of an `osascript`
# CHILD process attributed to the app that started it? Headroom's JXA fallback and Ghostty jump rely on it.
#
#   scripts/tcc-probe.sh            build build/HeadroomTCCProbe.app and open it
#   scripts/tcc-probe.sh --build    only build it
#   scripts/tcc-probe.sh --reset    forget the probe's Automation grant afterwards (tccutil, probe id only)
#
# The probe is a tiny window app (bundle id dev.adder.headroom.tccprobe). Its button runs
#   /usr/bin/osascript -e 'tell application "Ghostty" to count windows'
# as a child process (read-only: it only counts windows) and shows the result.
# PASS: macOS asks "“HeadroomTCCProbe” wants access to control “Ghostty”…" (not osascript / Terminal),
#       and after Allow the window shows a number, and System Settings ▸ Automation lists HeadroomTCCProbe.
# FAIL: the prompt names another app, or the result is error -1743 with no prompt. Then Headroom should
#       run its AppleScript in-process with NSAppleScript on a dedicated serial thread instead.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-open}"
ID="dev.adder.headroom.tccprobe"
if [[ "$MODE" == "--reset" ]]; then tccutil reset AppleEvents "$ID"; exit 0; fi

APP="build/HeadroomTCCProbe.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
SRC="$(mktemp -d)/probe.swift"
cat >"$SRC" <<'SWIFT'
import AppKit
final class D: NSObject, NSApplicationDelegate {
    var w: NSWindow!; let label = NSTextField(labelWithString: "Click to run osascript (child) → Ghostty")
    func applicationDidFinishLaunching(_ n: Notification) {
        w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 140), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Headroom TCC probe"
        let b = NSButton(title: "Run osascript", target: self, action: #selector(run))
        let s = NSStackView(views: [label, b]); s.orientation = .vertical; s.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        w.contentView = s; w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate()
    }
    @objc func run() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Ghostty\" to count windows"]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { label.stringValue = "could not start osascript: \(error)"; return }
        DispatchQueue.global().async {
            p.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { self.label.stringValue = "exit \(p.terminationStatus): \(text.trimmingCharacters(in: .whitespacesAndNewlines))" }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
let app = NSApplication.shared; let d = D(); app.delegate = d; app.setActivationPolicy(.regular); app.run()
SWIFT
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/HeadroomTCCProbe" "$SRC"
rm -rf "$(dirname "$SRC")"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleIdentifier string $ID" -c "Add :CFBundleName string HeadroomTCCProbe" \
  -c "Add :CFBundleExecutable string HeadroomTCCProbe" -c "Add :CFBundlePackageType string APPL" \
  -c "Add :NSPrincipalClass string NSApplication" -c "Add :LSMinimumSystemVersion string 15.0" \
  -c "Add :NSAppleEventsUsageDescription string 'Headroom TCC probe: checks whether an osascript child asks as this app.'" \
  "$APP/Contents/Info.plist" >/dev/null
SIGN="$(security find-identity -p codesigning 2>/dev/null | awk '/"Headroom Local Signing"/ { print $2; exit }')"
codesign --force --sign "${SIGN:--}" --timestamp=none "$APP" 2>/dev/null
codesign --verify --strict "$APP"
echo "built $APP (signed with ${SIGN:-ad-hoc})"
[[ "$MODE" == "--build" ]] || open -n "$APP"
