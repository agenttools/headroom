// The JXA scripts run for real in osascript, but against a JavaScript fake of Chrome's object model
// (the `APP` prelude), so no application is ever contacted. Host manifest tests use a scratch HOME.
import Darwin
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomChrome

/// A fake `Application("Google Chrome")` with the parts of the scripting dictionary the scripts use:
/// windows (id, mode, index, activeTab, activeTabIndex, tabs with id/title/url/close), byId, running, activate,
/// Tab/Window constructors. State lives in the script run only; `LOG` collects what was done.
func fakeChrome(_ windows: String, running: Bool = true, stuck: [Int] = []) -> String {
    #"""
    var STATE = \#(windows); var LOG = []; var STUCK = \#(stuck);
    function mkTab(w, t) { return { id: () => String(t.id), title: () => t.title, url: () => t.url,
      close: () => { if (STUCK.indexOf(t.id) >= 0) { LOG.push("stuck:" + t.id); return; }
                     w.tabs = w.tabs.filter(x => x !== t); LOG.push("close:" + t.id); } }; }
    function coll(arr, mk) { const c = function (i) { return mk(arr()[i]); };
      return new Proxy(c, { get: (t, p) => (typeof p === "string" && /^[0-9]+$/.test(p)) ? mk(arr()[+p]) : t[p],
                            set: (t, p, v) => { t[p] = v; return true; } }); }
    function mkWin(w) {
      const tabs = () => w.tabs;
      const t = coll(tabs, x => mkTab(w, x));
      t.byId = (id) => { const x = w.tabs.find(y => String(y.id) === String(id)); if (!x) throw new Error("no tab " + id); return mkTab(w, x); };
      t.push = (nt) => { const id = 900 + LOG.length; w.tabs.push({ id: id, title: "", url: nt.url }); LOG.push("open:" + nt.url + "@" + w.id); };
      const o = { id: () => String(w.id), tabs: t, activeTab: { url: null } };
      Object.defineProperty(o, "activeTabIndex", { set: (v) => { LOG.push("activeTabIndex:" + w.id + "=" + v); } });
      Object.defineProperty(o, "index", { set: (v) => { LOG.push("index:" + w.id + "=" + v); } });
      return o;
    }
    const APP = (name) => {
      const ws = () => STATE;
      const windows = coll(ws, mkWin);
      windows.id = () => STATE.map(w => String(w.id));
      windows.mode = () => STATE.map(w => w.mode || "normal");
      windows.index = () => STATE.map((w, i) => i + 1);
      windows.activeTab = { id: () => STATE.map(w => String(w.active)) };
      windows.tabs = { id: () => STATE.map(w => w.tabs.map(t => String(t.id))), title: () => STATE.map(w => w.tabs.map(t => t.title)),
                       url: () => STATE.map(w => w.tabs.map(t => t.url)) };
      windows.byId = (id) => { const w = STATE.find(x => String(x.id) === String(id)); if (!w) throw new Error("no window"); return mkWin(w); };
      return { running: () => \#(running), windows: windows, activate: () => LOG.push("activate:" + name),
               Tab: (p) => p, Window: () => ({ make: () => { STATE.unshift({ id: 77, tabs: [{ id: 1, title: "", url: "about:blank" }] }); LOG.push("newWindow"); } }) };
    };
    """#
}

/// Runs a script body with the fake and returns (script result, LOG).
func runFake(_ body: String, _ windows: String, args: [String] = [], running: Bool = true, stuck: [Int] = []) throws -> (String, [String]) {
    // Wrap run() so the log comes back with the result.
    let wrapped = body.replacingOccurrences(of: "function run(argv) {", with: "function inner(argv) {") +
        "\nfunction run(argv) { const r = inner(argv); return JSON.stringify({ r: r, log: LOG }); }"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-l", "JavaScript", "-e", fakeChrome(windows, running: running, stuck: stuck) + "\n" + wrapped, "Google Chrome"] + args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return (o["r"] as! String, o["log"] as! [String])
}

let twoWindows = #"""
[{ id: 501, active: 11, tabs: [{ id: 10, title: "Mail", url: "https://mail.test/" }, { id: 11, title: "Docs", url: "https://docs.test/" }] },
 { id: 502, mode: "incognito", active: 20, tabs: [{ id: 20, title: "Secret", url: "https://secret.test/" }] }]
"""#

@Suite struct JXAScriptTests {
    @Test func listParsesBulkForm() throws {
        let (out, log) = try runFake(JXAFallback.listBody, twoWindows)
        #expect(log.isEmpty)
        let l = try JXAFallback.parseListing(out).get()
        #expect(l.windows.map(\.id) == [501, 502] && l.windows[1].incognito && !l.windows[0].incognito)
        #expect(l.tabs.map(\.id) == [10, 11, 20])
        #expect(l.tabs[1].active && !l.tabs[0].active && l.tabs[1].index == 1 && l.tabs[1].url == "https://docs.test/")
        #expect(l.tabs[2].incognito && l.tabs[2].windowId == 502)
    }

    @Test func listWhenChromeIsNotRunningDoesNotTouchIt() throws {
        let (out, log) = try runFake(JXAFallback.listBody, twoWindows, running: false)
        #expect(log.isEmpty)
        if case .failure(.notRunning) = JXAFallback.parseListing(out) {} else { Issue.record("expected notRunning") }
        let (out2, _) = try runFake(JXAFallback.listBody, "[]")
        #expect(try JXAFallback.parseListing(out2).get().tabs.isEmpty)
    }

    @Test func closeChecksUrlAndGoesById() throws {
        let req = #"{"tabs":[{"id":11,"url":"https://docs.test/"},{"id":10,"url":"https://changed.test/"},{"id":99,"url":"x"},{"id":20,"url":"https://secret.test/"}]}"#
        let (out, log) = try runFake(JXAFallback.closeBody, twoWindows, args: [req])
        let res = (try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any])["results"] as! [String: String]
        #expect(res == ["11": "done", "10": "changedSkipped", "99": "gone", "20": "done"])
        #expect(log == ["close:11", "close:20"])  // tab 10 (URL changed) was not closed
    }

    @Test func closeReportsTabsThatStayOpen() throws {
        let req = #"{"tabs":[{"id":10,"url":"https://mail.test/"}]}"#
        let (out, _) = try runFake(JXAFallback.closeBody, twoWindows, args: [req], stuck: [10])
        #expect(out.contains(#""10":"stayedOpen""#))
    }

    @Test func closeWhenNotRunning() throws {
        let (out, log) = try runFake(JXAFallback.closeBody, twoWindows, args: [#"{"tabs":[{"id":10,"url":"x"}]}"#], running: false)
        #expect(out.contains("not running") && log.isEmpty)
    }

    @Test func activateSelectsTabAndRaisesWindow() throws {
        let (out, log) = try runFake(JXAFallback.activateBody, twoWindows, args: [#"{"tabId":11}"#])
        #expect(out.contains(#""done""#))
        #expect(log == ["activeTabIndex:501=2", "index:501=1", "activate:Google Chrome"])
        let (gone, log2) = try runFake(JXAFallback.activateBody, twoWindows, args: [#"{"tabId":5}"#])
        #expect(gone.contains(#""gone""#) && log2.isEmpty)
    }

    @Test func reopenUsesOldWindowElseFrontElseNew() throws {
        let req = #"{"items":[{"url":"https://a.test/","windowId":502},{"url":"https://b.test/","windowId":999},{"url":"https://c.test/"}]}"#
        let (out, log) = try runFake(JXAFallback.reopenBody, twoWindows, args: [req])
        #expect(out.contains(#"["done","done","done"]"#))
        #expect(log == ["open:https://a.test/@502", "open:https://b.test/@501", "open:https://c.test/@501"])
        let (_, log2) = try runFake(JXAFallback.reopenBody, "[]", args: [#"{"items":[{"url":"https://a.test/"}]}"#])
        #expect(log2 == ["newWindow"])
    }

    @Test func urlsWithQuotesAreData() throws {
        // A URL containing quotes and a script-looking string goes through argv/JSON, never into the source.
        let evil = #"https://x.test/?q=");LOG.push("pwned");("#
        let windows = #"[{ id: 1, active: 5, tabs: [{ id: 5, title: "t", url: \#(String(data: try JSONSerialization.data(withJSONObject: [evil]), encoding: .utf8)!.dropFirst().dropLast()) }] }]"#
        let payload = try JSONSerialization.data(withJSONObject: ["tabs": [["id": 5, "url": evil]]])
        let (out, log) = try runFake(JXAFallback.closeBody, windows, args: [String(data: payload, encoding: .utf8)!])
        #expect(out.contains(#""5":"done""#) && log == ["close:5"])
    }

    @Test func permissionStatusMapping() {
        #expect(JXAFallback.permission(fromStatus: 0) == .granted)
        #expect(JXAFallback.permission(fromStatus: -1743) == .denied)
        #expect(JXAFallback.permission(fromStatus: -1744) == .notDetermined)
        #expect(JXAFallback.permission(fromStatus: -600) == .notRunning)
        #expect(JXAFallback.permission(fromStatus: -50) == .unknown)
    }

    @Test func permissionForAnAppThatIsNotRunningNeverPrompts() {
        // A bundle id nothing runs as: the call returns at once without any UI.
        #expect(JXAFallback.permission(ask: false, bundleId: "dev.adder.headroom.no-such-app") == .notRunning)
    }
}

@Suite struct HostManifestTests {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path

    @Test func extensionIdFromTheCommittedKey() throws {
        let id = try #require(HostManifest.extensionId(manifestAt: repo + "/Extension/manifest.json"))
        #expect(id == "iocalbnflgmfkcdpjeobogdpgjdfkokp")  // docs/spike-s.md, scripts/extension-id.sh
        #expect(HostManifest.isValidExtensionId(id))
        #expect(!HostManifest.isValidExtensionId("iocalbnflgmfkcdpjeobogdpgjdfkokz"))
        #expect(HostManifest.extensionId(publicKeyBase64: "not base64!") == nil)
    }

    @Test func pathFollowsHome() {
        let env = HeadroomEnv(environment: ["HOME": "/scratch/home"])
        #expect(HostManifest(env: env).path == "/scratch/home/Library/Application Support/Google/Chrome/NativeMessagingHosts/dev.adder.headroom.json")
    }

    @Test func writeStatusRepair() throws {
        let s = Scratch(); defer { s.cleanup() }
        let env = HeadroomEnv(environment: ["HOME": s.path + "/home"])
        let m = HostManifest(env: env)
        let id = "iocalbnflgmfkcdpjeobogdpgjdfkokp"
        let host = s.path + "/Headroom.app/Contents/Helpers/headroom-host"
        try FileManager.default.createDirectory(atPath: (host as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: host, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        #expect(m.status(hostPath: host, extensionId: id) == .missing)
        #expect(try m.repair(hostPath: host, extensionId: id))
        #expect(m.status(hostPath: host, extensionId: id) == .ok)
        #expect(try !m.repair(hostPath: host, extensionId: id))  // already fine: not rewritten
        var st = stat()
        #expect(stat(m.path, &st) == 0 && st.st_mode & 0o777 == 0o644)
        let c = try #require(m.read())
        #expect(c.name == "dev.adder.headroom" && c.type == "stdio" && c.path == host && c.description == "Headroom tab memory bridge")
        #expect(c.allowed_origins == ["chrome-extension://iocalbnflgmfkcdpjeobogdpgjdfkokp/"])
        let text = try String(contentsOfFile: m.path, encoding: .utf8)
        #expect(text.contains(#""path" : "\#(host)""#))  // slashes not escaped: same as install.sh's file

        // The app moved: the manifest names the old host → mismatch → repair rewrites it.
        let moved = s.path + "/Moved.app/Contents/Helpers/headroom-host"
        try FileManager.default.createDirectory(atPath: (moved as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: moved, contents: Data(), attributes: [.posixPermissions: 0o755])
        if case .mismatch(let p) = m.status(hostPath: moved, extensionId: id) { #expect(p.count == 1) } else { Issue.record("expected mismatch") }
        #expect(try m.repair(hostPath: moved, extensionId: id))
        #expect(m.read()?.path == moved)
        // Another extension id.
        if case .mismatch = m.status(hostPath: moved, extensionId: String(repeating: "b", count: 32)) {} else { Issue.record("expected mismatch") }
        // A host binary that no longer exists.
        try FileManager.default.removeItem(atPath: moved)
        if case .mismatch(let p) = m.status(hostPath: nil, extensionId: id) { #expect(p.first?.contains("not an executable") == true) }
        else { Issue.record("expected mismatch") }
        // Junk file.
        try Data("{".utf8).write(to: URL(fileURLWithPath: m.path))
        if case .invalid = m.status(hostPath: host, extensionId: id) {} else { Issue.record("expected invalid") }
        #expect(try m.repair(hostPath: host, extensionId: id))
        #expect(m.status(hostPath: host, extensionId: id) == .ok)
        // Only our file exists in the folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: (m.path as NSString).deletingLastPathComponent) == ["dev.adder.headroom.json"])
    }

    @Test func refusesBadInput() {
        let s = Scratch(); defer { s.cleanup() }
        let m = HostManifest(directory: s.path)
        #expect(throws: HostManifest.ManifestError.self) { try m.write(hostPath: "relative/host", extensionId: "iocalbnflgmfkcdpjeobogdpgjdfkokp") }
        #expect(throws: HostManifest.ManifestError.self) { try m.write(hostPath: "/bin/cat", extensionId: "nope") }
        #expect(!FileManager.default.fileExists(atPath: m.path))
    }

    @Test func notAnAppBundleHasNoDefaults() {
        #expect(HostManifest.bundleDefaults() == nil)  // the test runner is not Headroom.app
    }
}
