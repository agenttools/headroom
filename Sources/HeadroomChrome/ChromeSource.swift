// ChromeSource: the live ChromeProvider (SPEC §4).
//
//   hosts()     starts the ChromeBridge on first use (app.sock server) and returns the connected hosts' lines.
//   snapshot()  classifies the main browsers' processes (§4.1), asks every connected helper for its tabs,
//               falls back to the JXA list for Google Chrome when no helper serves it and Automation is
//               already granted, then runs Attribution (§4.4).
//   close / discard / activate / restore / setMode go to the helper of the tab's browser; close, activate and
//               restore fall back to JXA for Google Chrome. Discard (Sleep) needs the helper.
//
// Safety:
//   - With HEADROOM_DRY_RUN=1, close/discard/restore return .dryRun and activate does nothing: nothing is sent
//     to Chrome (the executor checks dry run too; this is a second guard).
//   - JXA runs only against a running Google Chrome (a browser process whose path is the Google Chrome
//     binary) and only when Automation is already granted; it never asks for permission by itself.
//   - Incognito URLs are never written to disk. The restore-id file holds item ids and Chrome session ids only.
//
// Data source (ChromeSnapshot.source):
//   .helper(profiles:)  at least one main browser's tabs came from the helper
//   .appleScript        tabs came from the JXA list only (memory per tab "—")
//   .waiting            the helper is set up (host manifest present) and the bridge started < 35 s ago
//   .processesOnly      no tab list: only the process totals
//   .notRunning         no main Chrome browser process

import AppKit
import Foundation
import HeadroomContracts
import HeadroomCore

public final class ChromeSource: ChromeProvider, @unchecked Sendable {
    public struct Options: Sendable {
        /// Start the bridge on the first hosts()/snapshot() call. The app and the CLI both want this.
        public var autoStartBridge = true
        /// On the first call, wait this long for a host to connect (only if the host manifest is installed).
        /// Hosts poll for app.sock every 2 s.
        public var initialHostWait: TimeInterval = 2.5
        /// Retry a failed bridge start (e.g. another Headroom held app.sock) after this long.
        public var bridgeRetry: TimeInterval = 5
        /// Keep showing a helper's last tabs (with staleSince) for this long after it stops answering.
        public var staleLimit: TimeInterval = 60
        /// `.waiting` instead of `.processesOnly` for this long after the bridge starts.
        public var waitingWindow: TimeInterval = 35
        /// JXA listing cache. SPEC §9: 5 s while the window is key, 30 s while only visible (setCadence).
        public var jxaCacheTTL: TimeInterval = 5
        /// How often a helper-served Google Chrome is also listed with JXA, to find tabs the helper cannot see
        /// (incognito without "Allow in Incognito", profiles without the helper). Only with Automation granted.
        public var helperCheckTTL: TimeInterval = 15
        public var permissionCacheTTL: TimeInterval = 10
        /// Restore ids kept (item id → Chrome session id), newest first.
        public var restoreIdLimit = 200
        public init() {}
    }

    public let env: HeadroomEnv
    public let options: Options
    public let bridge: ChromeBridge
    /// nil disables the AppleScript fallback (tests that must never talk to Google Chrome).
    public let jxa: JXAFallback?

    private let lock = NSLock()
    private var startAttemptAt: Date?
    private var startedOnce = false
    public private(set) var bridgeError: String? {
        get { lock.withLock { _bridgeError } }
        set { lock.withLock { _bridgeError = newValue } }
    }
    private var _bridgeError: String?
    /// Last good helper replies per browser (all profiles), with when and for which browser start time.
    private var lastByBrowser: [Int32: BrowserCache] = [:]
    private struct BrowserCache {
        /// The browser process the replies belong to (guards against pid reuse after a Chrome restart).
        var key: ProcKey?
        var replies: [Int: (reply: Wire.SnapshotReply, at: Date)] = [:]
    }
    /// Which connection reported each tab, and its window (for routing close/discard/activate).
    private var routes: [TabRef: (conn: Int, windowId: Int)] = [:]
    private var jxaCache: (at: Date, listing: JXAFallback.Listing)?
    /// The helper-check listing, with the helper's window ids at the time (a change invalidates it).
    private var helperCheckCache: (at: Date, helperWindows: Set<Int>, listing: JXAFallback.Listing)?
    private var jxaTTL: TimeInterval?
    private var permCache: (at: Date, value: JXAFallback.Permission)?
    private var restoreIds: [String: RestoreId]?
    public private(set) var lastDiagnostics: Diagnostics {
        get { lock.withLock { _diag } }
        set { lock.withLock { _diag = newValue } }
    }
    private var _diag = Diagnostics()
    /// `via` of each tab the helper reopened in the last restore(): "sessions" (with history) or "create".
    public var lastRestoredVia: [String] { lock.withLock { _restoredVia } }
    private var _restoredVia: [String] = []

    public struct Diagnostics: Sendable {
        public var joinStats: [Int32: (tabs: Int, unmatched: Int)] = [:]
        public var unaccounted: Int64 = 0
        public var mismatchNote: String?
        public var helperErrors: [String] = []
        public var jxaError: String?
        public var at: Date?
    }

    enum SnapResult: Sendable { case ok(Wire.SnapshotReply), failed(String) }

    struct RestoreId: Codable { let sid: String; let at: Date }

    public init(env: HeadroomEnv = .current, options: Options = Options(), jxa: JXAFallback? = JXAFallback(),
                bridge: ChromeBridge? = nil) {
        self.env = env
        self.options = options
        self.jxa = jxa
        self.bridge = bridge ?? ChromeBridge(env: env)
    }

    // MARK: - Bridge

    /// Starts the bridge if needed (see Options). Safe to call often.
    public func ensureBridge() async {
        guard options.autoStartBridge, !bridge.isRunning else { return }
        let now = Date()
        let attempt: Bool = lock.withLock {
            if let t = startAttemptAt, now.timeIntervalSince(t) < options.bridgeRetry { return false }
            startAttemptAt = now
            return true
        }
        guard attempt else { return }
        do {
            try bridge.start()
            bridgeError = nil
        } catch {
            bridgeError = "\(error)"
            return
        }
        let first: Bool = lock.withLock { defer { startedOnce = true }; return !startedOnce }
        // Wait for the first host only when one can come: the helper is set up and Google Chrome is running.
        if first, options.initialHostWait > 0, HostManifest(env: env).status(hostPath: nil, extensionId: "").isInstalledFile,
           Self.googleChromeRunning() {
            _ = await bridge.waitForHosts(timeout: options.initialHostWait)
        }
    }

    /// SPEC §9 cadence: the JXA list is reused for 5 s while the window is key and 30 s while it is only visible.
    public func setCadence(windowKey: Bool) {
        lock.withLock { jxaTTL = windowKey ? 5 : 30 }
    }

    /// Bridge events (connected, hello, dirty, disconnected), e.g. to refresh on `dirty`.
    public func setEventHandler(_ h: (@Sendable (ChromeBridge.Event) -> Void)?) { bridge.setEventHandler(h) }

    public func stop() { bridge.stop() }

    public func hosts() async -> [Wire.HostHello] {
        await ensureBridge()
        var seen = Set<Int32>()
        return bridge.connections().map(\.host).filter { seen.insert($0.hostPid).inserted }
    }

    /// True once any connected host has relayed the extension's hello (the setup sheet's step 3).
    public var helperConnected: Bool { bridge.connections().contains { $0.ext != nil } }

    // MARK: - Snapshot

    public func snapshot(_ t: ProcessTable, _ o: OwnershipMap, _ sys: any SysKit) async -> ChromeSnapshot {
        await ensureBridge()
        let now = Date()
        let conns = bridge.connections()
        let mains = ChromeProcesses.mainBrowserPids(t, o, hostBrowserPids: Set(conns.map(\.browserPid)))
        let procs = ChromeProcesses.collect(t, o, mainBrowsers: mains, excluding: Set(conns.map(\.host.hostPid)),
                                            args: { sys.args($0) })
        let other = ChromeProcesses.otherInstances(t, o)
        var diag = Diagnostics(at: now)

        guard !mains.isEmpty else {
            lock.withLock { lastByBrowser.removeAll(); routes.removeAll() }
            let r = Attribution.attribute(procs: [], tabs: [], perTabBrowsers: [], otherInstances: other)
            lastDiagnostics = diag
            return ChromeSnapshot(source: .notRunning, overhead: r.overhead, total: r.total)
        }

        // 1. Helper replies, all connections at once.
        let mainSet = Set(mains)
        let wanted = conns.filter { mainSet.contains($0.browserPid) }
        let replies: [(Int, SnapResult)] = await withTaskGroup(of: (Int, SnapResult).self) { g in
            for c in wanted {
                g.addTask { [bridge] in
                    switch await bridge.request(c.id, { Wire.SnapshotRequest(req: $0) }) {
                    case .success(let d):
                        if let r = try? JSONDecoder().decode(Wire.SnapshotReply.self, from: d) { return (c.id, .ok(r)) }
                        return (c.id, .failed("unreadable snapshot reply"))
                    case .failure(let e): return (c.id, .failed("\(e)"))
                    }
                }
            }
            var out: [(Int, SnapResult)] = []
            for await x in g { out.append(x) }
            return out
        }
        let connById = Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, $0) })

        var helperTabs: [ChromeTab] = [], helperWindows: [ChromeWindow] = []
        var perTab = Set<Int32>()
        var staleSince: Date?
        var newRoutes: [TabRef: (conn: Int, windowId: Int)] = [:]
        var profiles = 0
        lock.withLock {
            // Per browser: the last good reply of each connection (profile). A reply that was not refreshed this
            // round (the host failed or disconnected) is still shown for `staleLimit`, and marks the data stale.
            for (cid, r) in replies {
                guard let c = connById[cid] else { continue }
                switch r {
                case .ok(let rep):
                    let key = t.byPid[c.browserPid]?.key
                    var entry = lastByBrowser[c.browserPid] ?? BrowserCache(key: key)
                    if entry.key != key { entry = BrowserCache(key: key) }
                    entry.replies[cid] = (rep, now)
                    lastByBrowser[c.browserPid] = entry
                case .failed(let e):
                    diag.helperErrors.append("connection \(cid) (browser \(c.browserPid)): \(e)")
                }
            }
            for b in lastByBrowser.keys where !mainSet.contains(b) || lastByBrowser[b]?.key != t.byPid[b]?.key {
                lastByBrowser[b] = nil
            }
            for b in mains {
                guard var entry = lastByBrowser[b] else { continue }
                entry.replies = entry.replies.filter { now.timeIntervalSince($0.value.at) <= options.staleLimit }
                lastByBrowser[b] = entry.replies.isEmpty ? nil : entry
                guard !entry.replies.isEmpty else { continue }
                for (_, v) in entry.replies where v.at < now { staleSince = min(staleSince ?? v.at, v.at) }
                let ordered = entry.replies.sorted { $0.key < $1.key }
                let merged = WireMapping.merge(ordered.map(\.value.reply), browserPid: b)
                helperTabs += merged.tabs
                helperWindows += merged.windows
                perTab.insert(b)
                profiles += ordered.count
                for (cid, v) in ordered {
                    for tab in v.reply.tabs where newRoutes[TabRef(browserPid: b, tabId: tab.id)] == nil {
                        newRoutes[TabRef(browserPid: b, tabId: tab.id)] = (cid, tab.windowId)
                    }
                }
            }
            routes = newRoutes
        }

        // 1b. Tabs the helper cannot see. The extension only lists tabs it has access to: incognito tabs need
        // "Allow in Incognito", and a profile without the helper sends nothing. With Automation granted, a JXA
        // list of the one Google Chrome finds whole windows the helper did not report; their tabs are merged
        // (memory "—") and their renderers go to "Tabs the helper can't see", not "Background pages".
        var incognitoOff = Set<Int32>()
        for c in wanted where perTab.contains(c.browserPid) && c.ext?.incognitoAllowed == false {
            incognitoOff.insert(c.browserPid)
        }
        var blind = Set<Int32>()
        var hiddenTabs: [ChromeTab] = [], hiddenWindows: [ChromeWindow] = []
        let helperGoogle = mains.filter { perTab.contains($0) && Self.isGoogleChrome(t.byPid[$0]?.path) }
        let noHelperGoogle = mains.filter { !perTab.contains($0) && Self.isGoogleChrome(t.byPid[$0]?.path) }
        var checkedHidden = false
        if helperGoogle.count == 1, noHelperGoogle.isEmpty, let b = helperGoogle.first, jxa != nil,
           await automationPermission() == .granted {
            let seenWindows = Set(helperWindows.filter { $0.browserPid == b }.map(\.id))
            if case .success(let l) = await helperCheckList(helperWindows: seenWindows) {
                checkedHidden = true
                let unseen = l.windows.filter { !seenWindows.contains($0.id) }
                for w in unseen {
                    let tabsOfW = l.tabs.filter { $0.windowId == w.id }.sorted { $0.index < $1.index }
                    guard !tabsOfW.isEmpty else { continue }
                    hiddenWindows.append(ChromeWindow(browserPid: b, id: w.id, incognito: w.incognito, tabIds: tabsOfW.map(\.id)))
                    for x in tabsOfW {
                        hiddenTabs.append(ChromeTab(browserPid: b, id: x.id, windowId: x.windowId, index: x.index,
                                                    title: x.title, url: x.url, host: WireMapping.host(of: x.url),
                                                    active: x.active, incognito: x.incognito))
                    }
                }
                if !hiddenTabs.isEmpty {
                    blind.insert(b)
                    lock.withLock { for x in hiddenTabs where routes[x.ref] == nil { routes[x.ref] = (0, x.windowId) } }
                }
            }
        }
        var helperNote: String?
        if !hiddenTabs.isEmpty {
            let inc = hiddenTabs.filter(\.incognito).count, other = hiddenTabs.count - inc
            var parts: [String] = []
            if inc > 0 { parts.append("\(inc) incognito tab\(inc == 1 ? "" : "s") (turn on “Allow in Incognito” for Headroom in chrome://extensions)") }
            if other > 0 { parts.append("\(other) tab\(other == 1 ? "" : "s") in a profile without the helper (add the helper there too)") }
            helperNote = "The helper can't see " + parts.joined(separator: " and ")
                + ". Their memory is under Chrome itself ▸ Tabs the helper can't see."
        } else if !incognitoOff.isEmpty && !checkedHidden {
            helperNote = "“Allow in Incognito” is off for the Headroom helper: incognito tabs are not listed, and their memory is counted under Chrome itself. Turn it on in chrome://extensions ▸ Headroom ▸ Details."
        }

        // 2. JXA for Google Chrome browsers the helper does not serve.
        var jxaTabs: [ChromeTab] = [], jxaWindows: [ChromeWindow] = []
        let jxaTargets = mains.filter { !perTab.contains($0) && Self.isGoogleChrome(t.byPid[$0]?.path) }
        var usedJXA = false
        if jxaTargets.count == 1, let b = jxaTargets.first, jxa != nil, await automationPermission() == .granted {
            switch await jxaList() {
            case .success(let l):
                usedJXA = true
                for w in l.windows {
                    let ids = l.tabs.filter { $0.windowId == w.id }.sorted { $0.index < $1.index }.map(\.id)
                    jxaWindows.append(ChromeWindow(browserPid: b, id: w.id, focused: w.index == 1, incognito: w.incognito, tabIds: ids))
                }
                for x in l.tabs {
                    jxaTabs.append(ChromeTab(browserPid: b, id: x.id, windowId: x.windowId, index: x.index, title: x.title,
                                             url: x.url, host: WireMapping.host(of: x.url), active: x.active,
                                             incognito: x.incognito))
                }
                lock.withLock { for x in l.tabs { routes[TabRef(browserPid: b, tabId: x.id)] = (0, x.windowId) } }
            case .failure(let f):
                diag.jxaError = f.description
            }
        }

        let r = Attribution.attribute(procs: procs, tabs: helperTabs + hiddenTabs + jxaTabs, perTabBrowsers: perTab,
                                      otherInstances: other, blindBrowsers: blind)
        diag.joinStats = r.joinStats
        diag.unaccounted = r.unaccounted
        diag.mismatchNote = r.mismatchNote
        lastDiagnostics = diag

        let source: ChromeDataSource
        if !perTab.isEmpty {
            source = .helper(profiles: max(1, profiles))
        } else if usedJXA {
            source = .appleScript
        } else if let since = bridge.runningSince, now.timeIntervalSince(since) < options.waitingWindow,
                  HostManifest(env: env).status(hostPath: nil, extensionId: "").isInstalledFile {
            source = .waiting
        } else {
            source = .processesOnly
        }
        return ChromeSnapshot(source: source, windows: helperWindows + hiddenWindows + jxaWindows, tabs: r.tabs,
                              overhead: r.overhead, total: r.total, procFootprint: r.procFootprint,
                              procUsers: r.procUsers, perTabUnavailable: r.perTabUnavailable, staleSince: staleSince,
                              helperNote: helperNote, helperBytes: Self.helperFootprint(procs, conns: wanted))
    }

    /// The helper extension's renderer: the extension renderer of the helper's browser that started with the
    /// helper's service worker (hello `swStart`, the worker's performance.timeOrigin). Counted only when exactly
    /// one extension renderer started in that window, so a Chrome launch (every extension at once) gives nil.
    static func helperFootprint(_ procs: [ChromeProc], conns: [ChromeBridge.Connection]) -> Bytes? {
        var sum: Bytes = 0, found = false
        var used = Set<ProcKey>()
        for c in conns {
            guard let ms = c.ext?.swStart, ms > 0 else { continue }
            let sec = Int(ms / 1000)
            let hits = procs.filter { p in
                p.browserPid == c.browserPid && p.kind == .extensionRenderer
                    && p.key.startSec >= sec - 3 && p.key.startSec <= sec + 1
            }
            guard hits.count == 1, let h = hits.first, used.insert(h.key).inserted else { continue }
            sum += h.footprint; found = true
        }
        return found ? sum : nil
    }

    /// A live SysKit (for callers and tests that only link HeadroomChrome).
    public static func liveSysKit(env: HeadroomEnv) -> any SysKit { LiveSysKit(env: env) }

    static func isGoogleChrome(_ path: String?) -> Bool { path == KnownPaths.chromeExecutable }

    /// A process runs the Google Chrome binary (a browser process; helpers have other paths).
    static func googleChromeRunning() -> Bool {
        let uid = getuid()
        return LiveSysKit.allPids().contains { pid in
            guard let info = LiveSysKit.bsdInfo(pid), info.pbi_uid == uid else { return false }
            return isGoogleChrome(LiveSysKit.pidPath(pid))
        }
    }

    /// Automation permission for Google Chrome, cached; never prompts.
    public func automationPermission() async -> JXAFallback.Permission {
        let now = Date()
        if let c = lock.withLock({ permCache }), now.timeIntervalSince(c.at) < options.permissionCacheTTL { return c.value }
        let p = await Task.detached(priority: .utility) { JXAFallback.permission(ask: false) }.value
        lock.withLock { permCache = (now, p) }
        return p
    }

    /// Asks for Automation permission (shows the system prompt once). Only the first-run card's [Allow…] calls this.
    public func requestAutomationPermission() async -> JXAFallback.Permission {
        let p = await Task.detached(priority: .userInitiated) { JXAFallback.permission(ask: true) }.value
        lock.withLock { permCache = (Date(), p) }
        return p
    }

    private func helperCheckList(helperWindows: Set<Int>) async -> Result<JXAFallback.Listing, JXAFallback.Failure> {
        guard let jxa else { return .failure(.failed("AppleScript fallback disabled")) }
        let now = Date()
        if let c = lock.withLock({ helperCheckCache }), c.helperWindows == helperWindows,
           now.timeIntervalSince(c.at) < options.helperCheckTTL { return .success(c.listing) }
        let r = await jxa.list()
        if case .success(let l) = r { lock.withLock { helperCheckCache = (now, helperWindows, l) } }
        if case .failure(.notPermitted) = r { lock.withLock { permCache = (now, .denied) } }
        return r
    }

    private func jxaList() async -> Result<JXAFallback.Listing, JXAFallback.Failure> {
        guard let jxa else { return .failure(.failed("AppleScript fallback disabled")) }
        let now = Date()
        let ttl = lock.withLock { jxaTTL } ?? options.jxaCacheTTL
        if let c = lock.withLock({ jxaCache }), now.timeIntervalSince(c.at) < ttl { return .success(c.listing) }
        let r = await jxa.list()
        if case .success(let l) = r { lock.withLock { jxaCache = (now, l) } }
        if case .failure(.notPermitted) = r { lock.withLock { permCache = (now, .denied) } }
        return r
    }

    /// JXA may act on browser `b` only if it is the running Google Chrome and Automation is granted.
    private func jxaAllowed(_ b: Int32) async -> Bool {
        guard jxa != nil, Self.isGoogleChrome(LiveSysKit.pidPath(b)) else { return false }
        return await automationPermission() == .granted
    }

    // MARK: - Actions

    private func connectionsFor(_ b: Int32) -> [ChromeBridge.Connection] { bridge.connections(browserPid: b) }

    private static func failure(_ e: ChromeBridge.RequestError) -> Outcome {
        switch e {
        case .timeout: .failed("Chrome helper did not answer in time")
        case .notConnected, .disconnected: .failed("Chrome helper disconnected")
        case .writeFailed: .failed("could not send to the Chrome helper")
        case .encodeFailed: .failed("could not encode the request")
        }
    }

    /// Sends one request per connection and merges per-tab result strings. A tab sent to several connections
    /// (profile unknown) takes the first answer that is not "gone".
    private func perTabRequest(_ plan: [Int: [Int]], make: @escaping @Sendable (Int, [Int]) -> any Encodable & Sendable,
                               onReply: @escaping @Sendable (Wire.ResultReply) -> Void) async -> [Int: Outcome] {
        let results: [(Int, [Int], Result<Data, ChromeBridge.RequestError>)] = await withTaskGroup(of: (Int, [Int], Result<Data, ChromeBridge.RequestError>).self) { g in
            for (cid, ids) in plan {
                g.addTask { [bridge] in
                    let msg = { (req: Int) in AnyEncodable(make(req, ids)) }
                    return (cid, ids, await bridge.request(cid, msg))
                }
            }
            var out: [(Int, [Int], Result<Data, ChromeBridge.RequestError>)] = []
            for await x in g { out.append(x) }
            return out
        }
        var out: [Int: Outcome] = [:]
        for (_, ids, r) in results.sorted(by: { $0.0 < $1.0 }) {
            var o: [Int: Outcome] = [:]
            switch r {
            case .failure(let e): for id in ids { o[id] = Self.failure(e) }
            case .success(let d):
                guard let rep = try? JSONDecoder().decode(Wire.ResultReply.self, from: d) else {
                    for id in ids { o[id] = .failed("unreadable reply from the Chrome helper") }
                    break
                }
                onReply(rep)
                let err = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
                for id in ids {
                    if let s = rep.results?[String(id)] { o[id] = Wire.outcome(s) }
                    else { o[id] = .failed(err ?? "no result for this tab") }
                }
            }
            for (id, v) in o {
                if let prev = out[id], prev != .alreadyGone { continue }
                out[id] = v
            }
        }
        return out
    }

    /// connection id → tab ids, from the last snapshot's routes (unknown tabs go to every connection of b).
    private func route(_ b: Int32, _ ids: [Int], conns: [ChromeBridge.Connection]) -> [Int: [Int]] {
        let live = Set(conns.map(\.id))
        var plan: [Int: [Int]] = [:]
        let known = lock.withLock { routes }
        for id in ids {
            if let r = known[TabRef(browserPid: b, tabId: id)], live.contains(r.conn) { plan[r.conn, default: []].append(id) }
            else { for c in live { plan[c, default: []].append(id) } }
        }
        return plan
    }

    public func close(_ tabs: [TabCloseRequest]) async -> [ItemID: Outcome] {
        if env.dryRun { return Dictionary(tabs.map { ($0.itemID, Outcome.dryRun) }, uniquingKeysWith: { a, _ in a }) }
        var out: [ItemID: Outcome] = [:]
        for (b, all) in Dictionary(grouping: tabs, by: \.browserPid) {
            let conns = connectionsFor(b)
            var group = all
            // Tabs the helper cannot see (listed by the JXA helper check, route connection 0) close through JXA.
            let jxaRouted = conns.isEmpty ? [] : lock.withLock {
                all.filter { routes[TabRef(browserPid: b, tabId: $0.id)]?.conn == 0 }
            }
            if !jxaRouted.isEmpty {
                group = all.filter { r in !jxaRouted.contains(r) }
                if await jxaAllowed(b), let jxa {
                    switch await jxa.close(jxaRouted.map { ($0.id, $0.expectedURL) }) {
                    case .success(let m): for r in jxaRouted { out[r.itemID] = m[r.id] ?? .failed("no result") }
                    case .failure(let f): for r in jxaRouted { out[r.itemID] = .failed(f.description) }
                    }
                    lock.withLock { jxaCache = nil; helperCheckCache = nil }
                } else {
                    for r in jxaRouted { out[r.itemID] = .failed("the helper cannot see this tab, and Chrome control is not allowed") }
                }
                if group.isEmpty { continue }
            }
            if !conns.isEmpty {
                let urls = Dictionary(group.map { ($0.id, $0.expectedURL) }, uniquingKeysWith: { a, _ in a })
                let got = await perTabRequest(route(b, group.map(\.id), conns: conns),
                                              make: { req, ids in Wire.CloseRequest(req: req, tabs: ids.map { Wire.CloseTab(id: $0, url: urls[$0] ?? "") }) },
                                              onReply: { [weak self] rep in
                    guard let self, let rs = rep.restore else { return }
                    self.rememberRestoreIds(rs.compactMap { k, v in Int(k).map { (ItemID.chromeTab(browserPid: b, tabId: $0), v) } })
                })
                for r in group { out[r.itemID] = got[r.id] ?? .failed("no result") }
            } else if await jxaAllowed(b), let jxa {
                switch await jxa.close(group.map { ($0.id, $0.expectedURL) }) {
                case .success(let m): for r in group { out[r.itemID] = m[r.id] ?? .failed("no result") }
                case .failure(let f): for r in group { out[r.itemID] = .failed(f.description) }
                }
                lock.withLock { jxaCache = nil; helperCheckCache = nil }
            } else {
                for r in group { out[r.itemID] = .failed("Chrome is not connected") }
            }
        }
        return out
    }

    public func discard(_ tabs: [ItemID]) async -> [ItemID: Outcome] {
        if env.dryRun { return Dictionary(tabs.map { ($0, Outcome.dryRun) }, uniquingKeysWith: { a, _ in a }) }
        var out: [ItemID: Outcome] = [:]
        var byBrowser: [Int32: [Int]] = [:]
        for id in tabs {
            guard case let .chromeTab(b, t) = id else { out[id] = .failed("not a tab"); continue }
            byBrowser[b, default: []].append(t)
        }
        for (b, ids) in byBrowser {
            let conns = connectionsFor(b)
            guard !conns.isEmpty else {
                for t in ids { out[.chromeTab(browserPid: b, tabId: t)] = .failed("Sleep needs the Headroom helper extension") }
                continue
            }
            let got = await perTabRequest(route(b, ids, conns: conns),
                                          make: { req, ids in Wire.DiscardRequest(req: req, tabIds: ids) }, onReply: { _ in })
            for t in ids { out[.chromeTab(browserPid: b, tabId: t)] = got[t] ?? .failed("no result") }
        }
        return out
    }

    public func activate(_ tab: ItemID) async {
        _ = await activateTab(tab)
    }

    /// Jump to a tab: the helper selects the tab and focuses its window; then Chrome is brought to the front.
    @discardableResult
    public func activateTab(_ tab: ItemID) async -> Outcome {
        guard case let .chromeTab(b, t) = tab else { return .failed("not a tab") }
        if env.dryRun { return .dryRun }
        let conns = connectionsFor(b)
        var result: Outcome
        if !conns.isEmpty {
            let wid = lock.withLock { routes[TabRef(browserPid: b, tabId: t)]?.windowId } ?? 0
            let got = await perTabRequest(route(b, [t], conns: conns),
                                          make: { req, _ in Wire.ActivateRequest(req: req, tabId: t, windowId: wid) }, onReply: { _ in })
            result = got[t] ?? .failed("no result")
        } else if await jxaAllowed(b), let jxa {
            return await jxa.activate(tabId: t)   // the script activates Chrome itself
        } else {
            return .failed("Chrome is not connected")
        }
        // Bring Chrome itself forward (the extension focuses the window, not the app). NSRunningApplication is
        // not main-actor bound, so this also works from the CLI.
        if result == .done { _ = NSRunningApplication(processIdentifier: b)?.activate() }
        return result
    }

    public func restore(_ records: [ClosedRecord]) async -> [ClosedRecord: Outcome] {
        if env.dryRun { return Dictionary(records.map { ($0, Outcome.dryRun) }, uniquingKeysWith: { a, _ in a }) }
        var out: [ClosedRecord: Outcome] = [:]
        let all = bridge.connections()
        var viaHelper: [Int: [ClosedRecord]] = [:]
        var viaJXA: [ClosedRecord] = []
        for r in records {
            guard r.kind == "tab", let url = r.url, !url.isEmpty else { out[r] = .failed("not a restorable tab"); continue }
            let sid = r.chromeSessionId ?? restoreId(for: r.itemId)
            let target = all.first { $0.browserPid == r.browserPid && $0.ext != nil } ?? all.first { $0.browserPid == r.browserPid }
                ?? all.first { $0.ext != nil } ?? all.first
            if let target {
                viaHelper[target.id, default: []].append(r)
            } else if r.incognito == true && sid == nil {
                out[r] = .failed("incognito tabs can only be reopened with the helper extension")
            } else {
                viaJXA.append(r)
            }
        }
        for (cid, recs) in viaHelper {
            let items = recs.map { r in
                Wire.RestoreItem(sessionId: r.chromeSessionId ?? restoreId(for: r.itemId), url: r.url ?? "",
                                 windowId: r.windowId, index: r.index)
            }
            let res = await bridge.request(cid) {
                Wire.RestoreRequest(req: $0, items: items)
            }
            switch res {
            case .failure(let e): for r in recs { out[r] = Self.failure(e) }
            case .success(let d):
                let rep = try? JSONDecoder().decode(Wire.ResultReply.self, from: d)
                let restored = rep?.restored ?? []
                lock.withLock { _restoredVia = restored.map(\.via) }
                for (i, r) in recs.enumerated() {
                    guard i < restored.count else { out[r] = .failed("no result"); continue }
                    let x = restored[i]
                    out[r] = (x.via == "sessions" || x.via == "create") ? .done : .failed("Chrome could not reopen the tab")
                }
            }
        }
        if !viaJXA.isEmpty {
            // Only a running Google Chrome (never launch it).
            if let jxa, Self.googleChromeRunning(), await automationPermission() == .granted {
                switch await jxa.reopen(viaJXA.map { ($0.url ?? "", $0.windowId) }) {
                case .success(let os): for (i, r) in viaJXA.enumerated() { out[r] = os[i] }
                case .failure(let f): for r in viaJXA { out[r] = .failed(f.description) }
                }
            } else {
                for r in viaJXA { out[r] = .failed("Chrome is not connected") }
            }
        }
        return out
    }

    public func setMode(_ m: String) async {
        guard m == "persistent" || m == "on-demand" else { return }
        for c in bridge.connections() { bridge.send(c.id, Wire.SetMode(mode: m)) }
    }

    /// Asks every helper to reload itself (after an extension update).
    public func reloadHelpers() {
        for c in bridge.connections() { bridge.send(c.id, Wire.Bare.reload) }
    }

    // MARK: - Restore ids (item id → chrome.sessions sessionId), so Undo keeps history, also across CLI runs

    var restoreIdsPath: String { env.supportDir + "/chrome-restore.json" }

    /// The Chrome session id the helper reported when this tab was closed (nil if unknown).
    public func restoreId(for itemId: String) -> String? {
        lock.withLock { loadRestoreIds()[itemId]?.sid }
    }

    private func loadRestoreIds() -> [String: RestoreId] {  // lock held
        if let r = restoreIds { return r }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let r = FileManager.default.contents(atPath: restoreIdsPath).flatMap { try? dec.decode([String: RestoreId].self, from: $0) } ?? [:]
        restoreIds = r
        return r
    }

    private func rememberRestoreIds(_ pairs: [(ItemID, String)]) {
        guard !pairs.isEmpty else { return }
        lock.withLock {
            var r = loadRestoreIds()
            let now = Date()
            for (id, sid) in pairs { r[id.stringValue] = RestoreId(sid: sid, at: now) }
            if r.count > options.restoreIdLimit {
                let keep = r.sorted { $0.value.at > $1.value.at }.prefix(options.restoreIdLimit)
                r = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            restoreIds = r
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
            if let d = try? enc.encode(r) {
                try? FileManager.default.createDirectory(atPath: env.supportDir, withIntermediateDirectories: true)
                try? d.write(to: URL(fileURLWithPath: restoreIdsPath), options: .atomic)
            }
        }
    }
}

/// Type-erased Encodable for building requests generically.
struct AnyEncodable: Encodable, Sendable {
    let value: any Encodable & Sendable
    init(_ v: any Encodable & Sendable) { value = v }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

extension HostManifest.Status {
    /// The file exists and is a host manifest (the id is not checked).
    var isInstalledFile: Bool {
        switch self {
        case .missing, .invalid: false
        case .ok, .mismatch: true
        }
    }
}
