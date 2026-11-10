// JXA fallback (SPEC §4.5): lists, closes, activates and reopens Google Chrome tabs through
// /usr/bin/osascript when the helper extension is not connected.
//
// Rules:
//   - Never launch Chrome: every script first checks `app.running()` (which does not launch it), and
//     ChromeSource only calls these when a Google Chrome browser process is in the process table.
//   - Close and activate go by tab id (and the window id that holds it), never by index. Close checks each
//     tab's URL first and answers "changedSkipped" on a mismatch.
//   - Data goes in through `run(argv)` as JSON, never by pasting strings into the script source.
//   - One `osascript` per call, off the main thread, with a timeout (3 s for a list).
//   - Permission: `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` never prompts. The prompt is
//     requested only by `permission(ask: true)`, which only the first-run card's [Allow…] button calls.
//
// For tests, `appFactory` replaces `Application` with a JavaScript fake of Chrome's object model, so the
// scripts run for real in osascript without talking to any app.

import CoreServices
import Foundation
import HeadroomContracts
import HeadroomCore

public struct JXAFallback: Sendable {
    public static let chromeBundleId = "com.google.Chrome"
    public static let chromeAppName = "Google Chrome"
    public static let osascript = "/usr/bin/osascript"

    public var appName: String
    /// JavaScript source that defines `APP(name)`. Default: `Application(name)`.
    public var prelude: String
    public var listTimeout: TimeInterval = 3

    public init(appName: String = JXAFallback.chromeAppName, prelude: String = "const APP = n => Application(n);") {
        self.appName = appName
        self.prelude = prelude
    }

    // MARK: - Permission

    public enum Permission: String, Sendable, Codable {
        case granted, denied, notDetermined, notRunning, unknown
    }

    /// `AEDeterminePermissionToAutomateTarget` for Google Chrome. With `ask: false` it never shows a prompt.
    /// Can block briefly; call it off the main thread.
    public static func permission(ask: Bool, bundleId: String = chromeBundleId) -> Permission {
        var addr = AEAddressDesc()
        let status: OSStatus = bundleId.withCString { p in
            guard AECreateDesc(DescType(typeApplicationBundleID), p, strlen(p), &addr) == noErr else { return OSStatus(-1) }
            defer { AEDisposeDesc(&addr) }
            return AEDeterminePermissionToAutomateTarget(&addr, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        }
        return permission(fromStatus: status)
    }

    static func permission(fromStatus s: OSStatus) -> Permission {
        switch s {
        case OSStatus(noErr): .granted
        case OSStatus(errAEEventNotPermitted): .denied                 // -1743
        case OSStatus(errAEEventWouldRequireUserConsent): .notDetermined // -1744
        case OSStatus(procNotFound): .notRunning                       // -600
        default: .unknown
        }
    }

    /// Where the "denied" card links to.
    public static let automationSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    // MARK: - Scripts

    static let listBody = #"""
    function run(argv) {
      const c = APP(argv[0]);
      if (!c.running()) return JSON.stringify({ running: false });
      for (let attempt = 0; attempt < 2; attempt++) {
        const w = c.windows;
        const wid = w.id();
        if (wid.length === 0) return JSON.stringify({ running: true, windows: [] });
        const r = { running: true, wid: wid, mode: w.mode(), idx: w.index(), active: w.activeTab.id(),
                    ids: w.tabs.id(), titles: w.tabs.title(), urls: w.tabs.url() };
        const n = wid.length;
        const ok = [r.mode, r.idx, r.active, r.ids, r.titles, r.urls].every(a => a.length === n) &&
                   r.ids.every((ids, i) => r.titles[i].length === ids.length && r.urls[i].length === ids.length);
        if (ok) return JSON.stringify(r);
      }
      return JSON.stringify({ running: true, error: "tabs changed while listing" });
    }
    """#

    /// argv[1] = {"tabs":[{"id":…,"url":…}]}. Finds each tab's window by id, checks the URL, closes by id,
    /// then re-reads the ids: a tab still there (a "Leave site?" dialog) is reported as stayedOpen.
    static let closeBody = #"""
    function run(argv) {
      const c = APP(argv[0]);
      const req = JSON.parse(argv[1]);
      if (!c.running()) return JSON.stringify({ error: "Chrome is not running" });
      const wids = c.windows.id();
      const tids = c.windows.tabs.id();
      const find = id => { for (let i = 0; i < tids.length; i++) { const j = tids[i].map(String).indexOf(String(id));
                           if (j >= 0) return { w: wids[i], t: tids[i][j] }; } return null; };
      const results = {}, closed = [];
      for (const t of req.tabs) {
        const loc = find(t.id);
        if (!loc) { results[t.id] = "gone"; continue; }
        try {
          const tab = c.windows.byId(loc.w).tabs.byId(loc.t);
          if (tab.url() !== t.url) { results[t.id] = "changedSkipped"; continue; }
          tab.close();
          results[t.id] = "done"; closed.push(t.id);
        } catch (e) { results[t.id] = "failed:" + e.message; }
      }
      if (closed.length) {
        let after = [];
        try { after = [].concat(...c.windows.tabs.id()).map(String); } catch (e) {}
        for (const id of closed) if (after.indexOf(String(id)) >= 0) results[id] = "stayedOpen";
      }
      return JSON.stringify({ results: results });
    }
    """#

    /// argv[1] = {"tabId":…}. Sets the window's active tab index, brings the window to the front, activates Chrome.
    static let activateBody = #"""
    function run(argv) {
      const c = APP(argv[0]);
      const req = JSON.parse(argv[1]);
      if (!c.running()) return JSON.stringify({ result: "failed:Chrome is not running" });
      const wids = c.windows.id();
      const tids = c.windows.tabs.id();
      for (let i = 0; i < tids.length; i++) {
        const j = tids[i].map(String).indexOf(String(req.tabId));
        if (j < 0) continue;
        const w = c.windows.byId(wids[i]);
        w.activeTabIndex = j + 1;
        w.index = 1;
        c.activate();
        return JSON.stringify({ result: "done" });
      }
      return JSON.stringify({ result: "gone" });
    }
    """#

    /// argv[1] = {"items":[{"url":…,"windowId":…}]}. Reopens each URL in its old window if it still exists,
    /// else in the front window, else in a new window. (No history: that needs the helper's sessions API.)
    static let reopenBody = #"""
    function run(argv) {
      const c = APP(argv[0]);
      const req = JSON.parse(argv[1]);
      if (!c.running()) return JSON.stringify({ error: "Chrome is not running" });
      const out = [];
      for (const it of req.items) {
        try {
          const wids = c.windows.id().map(String);
          let w = null;
          if (it.windowId != null && wids.indexOf(String(it.windowId)) >= 0) w = c.windows.byId(c.windows.id()[wids.indexOf(String(it.windowId))]);
          else if (wids.length > 0) w = c.windows[0];
          if (w) { w.tabs.push(c.Tab({ url: it.url })); }
          else { c.Window().make(); c.windows[0].activeTab.url = it.url; }
          out.push("done");
        } catch (e) { out.push("failed:" + e.message); }
      }
      return JSON.stringify({ results: out });
    }
    """#

    // MARK: - Calls

    public struct ListedTab: Sendable, Hashable, Codable {
        public let windowId: Int
        public let id: Int
        public let index: Int
        public let title: String
        public let url: String
        public let active: Bool
        public let incognito: Bool
    }

    public struct ListedWindow: Sendable, Hashable, Codable {
        public let id: Int
        /// 1 = frontmost
        public let index: Int
        public let incognito: Bool
    }

    public struct Listing: Sendable, Codable {
        public var running: Bool
        public var windows: [ListedWindow]
        public var tabs: [ListedTab]
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case notRunning
        case notPermitted(String)
        case timeout
        case failed(String)
        public var description: String {
            switch self {
            case .notRunning: "Chrome is not running"
            case .notPermitted(let s): "Headroom is not allowed to control Chrome (\(s))"
            case .timeout: "Chrome did not answer in time"
            case .failed(let s): s
            }
        }
    }

    func script(_ body: String) -> String { prelude + "\n" + body }

    func runScript(_ body: String, args: [String], timeout: TimeInterval) async -> Result<String, Failure> {
        let r = await Shell.run(Self.osascript, ["-l", "JavaScript", "-e", script(body), appName] + args, timeout: timeout)
        if r.timedOut { return .failure(.timeout) }
        guard r.status == 0 else {
            let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if err.contains("-1743") || err.contains("Not authorized") || err.contains("not allowed") { return .failure(.notPermitted(err)) }
            if err.contains("-600") || err.contains("isn’t running") || err.contains("isn't running") { return .failure(.notRunning) }
            return .failure(.failed(err.isEmpty ? "osascript exited with \(r.status)" : err))
        }
        return .success(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func json(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    private static func int(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: i
        case let d as Double: Int(exactly: d)
        case let s as String: Int(s)
        case let n as NSNumber: n.intValue
        default: nil
        }
    }

    /// One bulk call (SPEC §4.5; measured at about 0.1 s).
    public func list() async -> Result<Listing, Failure> {
        switch await runScript(Self.listBody, args: [], timeout: listTimeout) {
        case .failure(let f): return .failure(f)
        case .success(let out): return Self.parseListing(out)
        }
    }

    static func parseListing(_ out: String) -> Result<Listing, Failure> {
        guard let o = json(out) else { return .failure(.failed("unreadable osascript output")) }
        if o["running"] as? Bool == false { return .failure(.notRunning) }
        if let e = o["error"] as? String { return .failure(.failed(e)) }
        guard let wid = o["wid"] as? [Any] else { return .success(Listing(running: true, windows: [], tabs: [])) }
        let mode = o["mode"] as? [Any] ?? [], idx = o["idx"] as? [Any] ?? [], active = o["active"] as? [Any] ?? []
        let ids = o["ids"] as? [[Any]] ?? [], titles = o["titles"] as? [[Any]] ?? [], urls = o["urls"] as? [[Any]] ?? []
        var windows: [ListedWindow] = []
        var tabs: [ListedTab] = []
        for (i, w) in wid.enumerated() {
            guard let wId = int(w), i < ids.count else { continue }
            let incognito = (i < mode.count ? mode[i] as? String : nil) == "incognito"
            windows.append(ListedWindow(id: wId, index: i < idx.count ? int(idx[i]) ?? i + 1 : i + 1, incognito: incognito))
            let activeId = i < active.count ? int(active[i]) : nil
            for (j, t) in ids[i].enumerated() {
                guard let tId = int(t) else { continue }
                let title = i < titles.count && j < titles[i].count ? titles[i][j] as? String ?? "" : ""
                let url = i < urls.count && j < urls[i].count ? urls[i][j] as? String ?? "" : ""
                tabs.append(ListedTab(windowId: wId, id: tId, index: j, title: title, url: url,
                                      active: tId == activeId, incognito: incognito))
            }
        }
        return .success(Listing(running: true, windows: windows, tabs: tabs))
    }

    /// Closes tabs by id after checking each URL. Outcomes: done, changedSkipped, alreadyGone, stayedOpen, failed.
    public func close(_ tabs: [(id: Int, url: String)]) async -> Result<[Int: Outcome], Failure> {
        let payload = ["tabs": tabs.map { ["id": $0.id, "url": $0.url] as [String: Any] }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let arg = String(data: data, encoding: .utf8) else {
            return .failure(.failed("cannot encode request"))
        }
        let timeout = max(3, 0.25 * Double(tabs.count) + 2)
        switch await runScript(Self.closeBody, args: [arg], timeout: timeout) {
        case .failure(let f): return .failure(f)
        case .success(let out):
            guard let o = Self.json(out) else { return .failure(.failed("unreadable osascript output")) }
            if let e = o["error"] as? String { return .failure(e.contains("not running") ? .notRunning : .failed(e)) }
            let res = o["results"] as? [String: String] ?? [:]
            var map: [Int: Outcome] = [:]
            for t in tabs {
                let s = res[String(t.id)] ?? "failed:no result"
                map[t.id] = s == "stayedOpen" ? .stayedOpen : Wire.outcome(s)
            }
            return .success(map)
        }
    }

    public func activate(tabId: Int) async -> Outcome {
        guard let data = try? JSONSerialization.data(withJSONObject: ["tabId": tabId]),
              let arg = String(data: data, encoding: .utf8) else { return .failed("cannot encode request") }
        switch await runScript(Self.activateBody, args: [arg], timeout: 3) {
        case .failure(let f): return .failed(f.description)
        case .success(let out):
            return Wire.outcome((Self.json(out)?["result"] as? String) ?? "failed:unreadable osascript output")
        }
    }

    /// Reopens URLs (no history). Outcomes in the order of `items`.
    public func reopen(_ items: [(url: String, windowId: Int?)]) async -> Result<[Outcome], Failure> {
        let payload = ["items": items.map { i -> [String: Any] in
            var d: [String: Any] = ["url": i.url]
            if let w = i.windowId { d["windowId"] = w }
            return d
        }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let arg = String(data: data, encoding: .utf8) else {
            return .failure(.failed("cannot encode request"))
        }
        switch await runScript(Self.reopenBody, args: [arg], timeout: max(3, 0.5 * Double(items.count) + 2)) {
        case .failure(let f): return .failure(f)
        case .success(let out):
            guard let o = Self.json(out) else { return .failure(.failed("unreadable osascript output")) }
            if let e = o["error"] as? String { return .failure(e.contains("not running") ? .notRunning : .failed(e)) }
            let res = o["results"] as? [String] ?? []
            return .success(items.indices.map { $0 < res.count ? Wire.outcome(res[$0]) : .failed("no result") })
        }
    }
}
