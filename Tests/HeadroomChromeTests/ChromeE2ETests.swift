// End to end, opt-in: ChromeSource + ChromeBridge ↔ the real headroom-host ↔ the real Extension/ in
// Chrome for Testing (headless, scratch --user-data-dir). Never touches Google Chrome: the AppleScript fallback
// is disabled (jxa: nil), the host manifest goes into the scratch profile's NativeMessagingHosts, and the bridge
// listens in a scratch HEADROOM_SUPPORT_DIR. It stops only the Chrome and the HTTP server it started.
//
//   swift build --scratch-path .build/e2e --product headroom-host
//   HEADROOM_DRY_RUN=1 HEADROOM_CFT_E2E=1 HEADROOM_E2E_HOST=$PWD/.build/e2e/debug/headroom-host \
//     swift test --scratch-path .build/e2e --filter HeadroomChromeTests.ChromeE2E
//
// HEADROOM_E2E_CFT overrides the Chrome for Testing binary (default: Playwright's chromium-1234).
// The test's own ChromeSource runs with dryRun off: it acts only on the scratch Chrome it started.

import Darwin
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomChrome

private let e2eEnabled = ProcessInfo.processInfo.environment["HEADROOM_CFT_E2E"] == "1"

@Suite(.serialized, .enabled(if: e2eEnabled)) struct ChromeE2E {
    let pe = ProcessInfo.processInfo.environment
    var repo: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path }

    @Test func helperEndToEndInChromeForTesting() async throws {
        let host = try #require(pe["HEADROOM_E2E_HOST"], "set HEADROOM_E2E_HOST to a built headroom-host")
        let cft = pe["HEADROOM_E2E_CFT"] ?? NSHomeDirectory() + "/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        try #require(FileManager.default.isExecutableFile(atPath: host))
        try #require(FileManager.default.isExecutableFile(atPath: cft))
        let s = Scratch("hr-e2e"); defer { s.cleanup() }
        let profile = s.path + "/profile", www = s.path + "/www"
        let ext = repo + "/Extension"

        // 1. The bridge (our ChromeSource) in a scratch support dir; dry run off for this scratch Chrome only.
        let env = HeadroomEnv(environment: ["HOME": s.path + "/home", "HEADROOM_SUPPORT_DIR": s.path, "HEADROOM_DRY_RUN": "0"])
        var o = ChromeSource.Options(); o.initialHostWait = 0
        let src = ChromeSource(env: env, options: o, jxa: nil)
        defer { src.stop() }
        let events = EventLog()
        src.setEventHandler { events.add($0) }
        _ = await src.hosts()
        #expect(src.bridge.isRunning)

        // 2. Host manifest in the scratch profile (Chrome for Testing reads <user-data-dir>/NativeMessagingHosts).
        let extId = try #require(HostManifest.extensionId(manifestAt: ext + "/manifest.json"))
        try HostManifest(directory: profile + "/NativeMessagingHosts").write(hostPath: host, extensionId: extId)

        // 3. Test pages on a local server we start.
        try FileManager.default.createDirectory(atPath: www, withIntermediateDirectories: true)
        let port = Int.random(in: 20000...40000)
        let pages: [String: String] = [
            "big.html": "<title>big</title><script>window.x=[];for(let i=0;i<40;i++){const a=new Float64Array(1e6);a.fill(i);x.push(a)}</script>320 MB",
            "iframe.html": "<title>iframe host</title><iframe src=\"http://localhost:\(port)/frame.html\"></iframe>",
            "frame.html": "<title>frame</title>cross-site frame",
            "victim.html": "<title>victim</title>close me", "sleepy.html": "<title>sleepy</title>discard me",
            "keep.html": "<title>keep</title>keep me",
        ]
        for (n, b) in pages { try Data("<!doctype html>\(b)".utf8).write(to: URL(fileURLWithPath: www + "/" + n)) }
        let http = Process()
        http.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        http.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", www]
        http.standardOutput = FileHandle.nullDevice; http.standardError = FileHandle.nullDevice
        try http.run()
        defer { if http.isRunning { http.terminate() } }
        let origin = "http://127.0.0.1:\(port)"

        // 4. Chrome for Testing, headless, scratch profile, the unpacked extension, test tabs.
        let chrome = Process()
        chrome.executableURL = URL(fileURLWithPath: cft)
        chrome.arguments = ["--user-data-dir=\(profile)", "--load-extension=\(ext)", "--disable-extensions-except=\(ext)",
                            "--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-sync",
                            "--disable-background-networking", "--use-mock-keychain", "--remote-debugging-port=0",
                            "\(origin)/big.html"]
        // The test runner's DYLD_* variables would make Chrome load the wrong frameworks.
        var cenv = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("__XPC_DYLD") }
        cenv["HEADROOM_SUPPORT_DIR"] = s.path
        chrome.environment = cenv
        chrome.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: s.path + "/chrome.log", contents: nil)
        chrome.standardError = FileHandle(forWritingAtPath: s.path + "/chrome.log")
        try await Task.sleep(for: .milliseconds(400))  // let the server bind
        try chrome.run()
        let browserPid = chrome.processIdentifier
        // Headless Chrome takes one URL on the command line; open the others through its own DevTools
        // HTTP endpoint (this scratch Chrome only).
        var port0: String?
        _ = await until(15) {
            port0 = (try? String(contentsOfFile: profile + "/DevToolsActivePort", encoding: .utf8))?.split(separator: "\n").first.map(String.init)
            return port0 != nil
        }
        let devtools = try #require(port0, "no DevToolsActivePort")
        for name in ["iframe", "victim", "sleepy", "keep"] {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(devtools)/json/new?\(origin)/\(name).html")!)
            req.httpMethod = "PUT"
            _ = try await URLSession.shared.data(for: req)
        }
        defer {
            // Only the Chrome we started (our child, with our scratch profile in its argv).
            if chrome.isRunning, chrome.arguments?.contains("--user-data-dir=\(profile)") == true { chrome.terminate() }
        }

        // 5. The host connects and the extension says hello.
        let connected = await until(25) { src.helperConnected }
        #expect(connected)
        if !connected {
            let log = (try? String(contentsOfFile: s.path + "/chrome.log", encoding: .utf8)) ?? ""
            print("chrome.log (last lines):\n" + log.split(separator: "\n").suffix(30).joined(separator: "\n"))
            print("events: \(events.all); chrome running: \(chrome.isRunning) status: \(chrome.isRunning ? -1 : chrome.terminationStatus) reason: \(chrome.isRunning ? 0 : chrome.terminationReason.rawValue)")
        }
        let conns = src.bridge.connections()
        try #require(conns.count == 1)
        #expect(conns[0].browserPid == browserPid)
        let hostPid = conns[0].host.hostPid
        #expect(conns[0].ext?.mode == "persistent")

        // 6. Snapshot + attribution, once all 5 pages have loaded (the big page takes a moment).
        let sys = ChromeSource.liveSysKit(env: env)
        func snap() async -> ChromeSnapshot { let t = sys.scan(); return await src.snapshot(t, .empty, sys) }
        var cs = await snap()
        let loaded = await until(30) {
            let urls = Set(cs.tabs.map(\.url))
            return pages.keys.filter { $0 != "frame.html" }.allSatisfy { urls.contains("\(origin)/\($0)") }
                && (cs.tabs.first { $0.url.hasSuffix("/big.html") }?.display ?? 0) > 300 * MB
                && (cs.tabs.first { $0.url.hasSuffix("/iframe.html") }?.procs.count ?? 0) == 2
        } refresh: { cs = await snap() }
        #expect(loaded, "tabs: \(cs.tabs.map { "\($0.url) \($0.display.map(ByteFormat.short) ?? "—")" })")
        #expect(cs.source == .helper(profiles: 1))
        let d = src.lastDiagnostics
        #expect(d.joinStats[browserPid]?.unmatched == 0, "join \(String(describing: d.joinStats[browserPid]))")
        let big = try #require(cs.tabs.first { $0.url.hasSuffix("/big.html") })
        #expect(big.display! > 300 * MB && big.display! < 420 * MB, "big page shows \(ByteFormat.short(big.display!))")
        let iframe = try #require(cs.tabs.first { $0.url.hasSuffix("/iframe.html") })
        #expect(iframe.frames.count == 2 && iframe.procs.count == 2)
        let tabSum = cs.tabs.reduce(Bytes(0)) { $0 + ($1.display ?? 0) }
        #expect(tabSum + cs.overheadTotal == cs.total)
        #expect(cs.total > 400 * MB && cs.overhead["browser"]?.count == 1 && (cs.overhead["extensions"]?.count ?? 0) >= 1)
        print("E2E attribution: big \(ByteFormat.short(big.display!)); tabs \(ByteFormat.short(tabSum)) + Chrome itself \(ByteFormat.short(cs.overheadTotal)) = \(ByteFormat.short(cs.total))")

        // 7. Close with a changed URL → changedSkipped, and the tab stays.
        let victim = try #require(cs.tabs.first { $0.url.hasSuffix("/victim.html") })
        let skipped = await src.close([TabCloseRequest(browserPid: browserPid, id: victim.id, expectedURL: origin + "/elsewhere.html")])
        #expect(skipped[victim.itemID] == .changedSkipped)
        cs = await snap()
        #expect(cs.tab(victim.ref) != nil)

        // 8. Close → done, with a restore id; then Undo (restore) → reopened with history.
        let closed = await src.close([TabCloseRequest(browserPid: browserPid, id: victim.id, expectedURL: victim.url)])
        #expect(closed[victim.itemID] == .done)
        #expect(src.restoreId(for: victim.itemID.stringValue) != nil)
        cs = await snap()
        #expect(cs.tab(victim.ref) == nil)
        let rec = ClosedRecord(batchId: "e2e", kind: "tab", itemId: victim.itemID.stringValue, closedAt: Date(), title: victim.title,
                               bytes: victim.display ?? 0, url: victim.url, browserPid: browserPid, windowId: victim.windowId, index: victim.index)
        let restored = await src.restore([rec])
        #expect(restored[rec] == .done)
        #expect(src.lastRestoredVia == ["sessions"])  // reopened through chrome.sessions, so with its history
        #expect(await until(5) { cs.tabs.contains { $0.url == victim.url } } refresh: { cs = await snap() })

        // 9. Discard (Sleep) a background tab → done; it then shows as discarded with 0 bytes.
        let sleepy = try #require(cs.tabs.first { $0.url.hasSuffix("/sleepy.html") && !$0.active })
        let slept = await src.discard([sleepy.itemID])
        #expect(slept[sleepy.itemID] == .done)
        #expect(await until(5) { cs.tab(sleepy.ref)?.discarded == true } refresh: { cs = await snap() })
        #expect(cs.tab(sleepy.ref)?.display == 0)
        #expect(cs.tabs.reduce(Bytes(0)) { $0 + ($1.display ?? 0) } + cs.overheadTotal == cs.total)

        // 10. Activate (Jump) → the helper selects the tab.
        let keep = try #require(cs.tabs.first { $0.url.hasSuffix("/keep.html") })
        #expect(await src.activateTab(keep.itemID) == .done)
        #expect(await until(5) { cs.tab(keep.ref)?.active == true } refresh: { cs = await snap() })

        // 11. A dirty event arrived at some point (tabs opened/closed).
        #expect(events.count { if case .dirty = $0 { true } else { false } } >= 1)

        // 12. Chrome quits → the host exits and the bridge sees the disconnect.
        chrome.terminate()
        #expect(await until(10) { src.bridge.connections().isEmpty })
        #expect(await until(5) { kill(hostPid, 0) != 0 }, "host \(hostPid) still alive")
        #expect(events.count { if case .disconnected = $0 { true } else { false } } == 1)
    }
}

/// Polls `f`, running `refresh` between tries.
func until(_ timeout: TimeInterval, _ f: () -> Bool, refresh: () async -> Void) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if f() { return true }
        try? await Task.sleep(for: .milliseconds(250))
        await refresh()
    }
    return f()
}

/// `--selftest chrome` against the live system, opt-in (read-only: see ChromeSelfTest).
///   HEADROOM_DRY_RUN=1 HEADROOM_LIVE_SELFTEST=1 swift test --scratch-path .build/e2e --filter HeadroomChromeTests.LiveChromeSelfTest
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HEADROOM_LIVE_SELFTEST"] == "1")) struct LiveChromeSelfTest {
    @Test func selftestChrome() async {
        let r = await ChromeSelfTest.run(env: .current)
        print(r.render())
        #expect(r.passed)
    }
}

@Suite struct SelfTestSocketCheck {
    @Test func scratchSocketRoundTripPasses() async {
        let checks = await ChromeSelfTest.socketRoundTrip()
        #expect(checks.count == 2 && checks.allSatisfy(\.passed), "\(checks)")
    }
}
