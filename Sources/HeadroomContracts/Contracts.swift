// Contracts.swift — the shared contract between modules (SPEC §11, adapted so it compiles under Swift 6).
//
// Every other module depends on these types, so change them with care.
//
// Differences from the SPEC §11 sketch (all deliberate):
//  - Tuples in stored properties / protocol signatures became named structs
//    (OverheadStat, PlanItem, LockedItem, TabCloseRequest) so they can be Codable/Hashable.
//  - Tab ids are only unique per browser, so tab sets use TabRef(browserPid, tabId), not Int.
//  - Every public struct has an explicit public init (Swift's memberwise init is internal).
//  - Most types are Codable so `Headroom --dump-json` can print a WorldSnapshot directly.
//  - Ownership inputs (SessionRecord, TmuxPane, Wire.HostHello) live here so HeadroomCore can
//    run Ownership.assign without depending on HeadroomClaude or HeadroomChrome.
//  - ItemID has a stable string form (see ItemID.swift); ClosedRecord has an id and batchId.
//  - ActionExecutor gained protections(_:) and recentlyClosed() for the CLI.

import Foundation

public typealias Bytes = UInt64

// MARK: - Processes (SysKit)

/// A process identity that survives pid reuse: (pid, start time in whole seconds since 1970).
public struct ProcKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let pid: Int32
    public let startSec: Int
    public init(pid: Int32, startSec: Int) { self.pid = pid; self.startSec = startSec }
    public static func < (a: ProcKey, b: ProcKey) -> Bool { (a.pid, a.startSec) < (b.pid, b.startSec) }
    public var description: String { "\(pid)@\(startSec)" }
}

public struct ProcSample: Sendable, Hashable, Codable {
    public let key: ProcKey
    public let ppid: Int32
    public let pgid: Int32
    public let uid: UInt32
    /// proc_pidpath; empty when unreadable.
    public let path: String
    /// ri_phys_footprint (Activity Monitor "Memory").
    public let footprint: Bytes
    public let rss: Bytes
    /// user + system CPU time in nanoseconds (for CPU% deltas).
    public let cpuNs: UInt64
    public var pid: Int32 { key.pid }
    public init(key: ProcKey, ppid: Int32, pgid: Int32, uid: UInt32 = 501, path: String,
                footprint: Bytes, rss: Bytes, cpuNs: UInt64 = 0) {
        self.key = key; self.ppid = ppid; self.pgid = pgid; self.uid = uid; self.path = path
        self.footprint = footprint; self.rss = rss; self.cpuNs = cpuNs
    }
}

/// argv and a filtered environment (only `CLAUDE_*` keys and a few others SysKit chooses to keep,
/// never secrets) read once per ProcKey via KERN_PROCARGS2.
public struct ProcArgs: Sendable, Hashable, Codable {
    public let argv: [String]
    public let env: [String: String]
    public init(argv: [String], env: [String: String] = [:]) { self.argv = argv; self.env = env }
    public var argv0: String { argv.first ?? "" }
    /// Value of `--name=value` (or `--name value`) in argv.
    public func flag(_ name: String) -> String? {
        let p = "--\(name)="
        for (i, a) in argv.enumerated() {
            if a.hasPrefix(p) { return String(a.dropFirst(p.count)) }
            if a == "--\(name)", i + 1 < argv.count { return argv[i + 1] }
        }
        return nil
    }
    public func hasFlag(_ name: String) -> Bool {
        argv.contains { $0 == "--\(name)" || $0.hasPrefix("--\(name)=") }
    }
}

public struct ProcessTable: Sendable, Codable {
    public let byPid: [Int32: ProcSample]
    public let children: [Int32: [Int32]]
    public let takenAt: Date
    public init(byPid: [Int32: ProcSample], children: [Int32: [Int32]], takenAt: Date) {
        self.byPid = byPid; self.children = children; self.takenAt = takenAt
    }
    /// Builds `children` from the samples' ppid.
    public init(samples: [ProcSample], takenAt: Date = Date()) {
        var by: [Int32: ProcSample] = [:]
        var ch: [Int32: [Int32]] = [:]
        for s in samples { by[s.pid] = s }
        for s in samples where s.ppid != s.pid { ch[s.ppid, default: []].append(s.pid) }
        for k in ch.keys { ch[k]!.sort() }
        self.init(byPid: by, children: ch, takenAt: takenAt)
    }
    public static let empty = ProcessTable(byPid: [:], children: [:], takenAt: .distantPast)

    /// All descendants of `pid` (not including `pid`), breadth first.
    public func descendants(of pid: Int32) -> [Int32] {
        var out: [Int32] = []; var queue = children[pid] ?? []; var seen: Set<Int32> = [pid]
        while !queue.isEmpty {
            let p = queue.removeFirst()
            guard seen.insert(p).inserted else { continue }
            out.append(p); queue.append(contentsOf: children[p] ?? [])
        }
        return out
    }
    /// ppid chain from `pid`'s parent up to launchd (pid 1), nearest first.
    public func ancestors(of pid: Int32) -> [Int32] {
        var out: [Int32] = []; var cur = byPid[pid]?.ppid; var seen: Set<Int32> = [pid]
        while let c = cur, c > 0, seen.insert(c).inserted {
            out.append(c); cur = byPid[c]?.ppid
        }
        return out
    }
    public func footprint(of pids: some Sequence<Int32>) -> Bytes {
        pids.reduce(0) { $0 + (byPid[$1]?.footprint ?? 0) }
    }
}

public enum Pressure: Int, Sendable, Codable, CaseIterable {
    case normal = 1, warning = 2, critical = 4
    public var name: String { switch self { case .normal: "normal"; case .warning: "warning"; case .critical: "critical" } }
}

public struct SystemMemory: Sendable, Hashable, Codable {
    public let total, used, appMemory, wired, compressed, free, swapUsed, swapTotal: Bytes
    public let pressure: Pressure
    public init(total: Bytes, used: Bytes, appMemory: Bytes, wired: Bytes, compressed: Bytes,
                free: Bytes, swapUsed: Bytes, swapTotal: Bytes, pressure: Pressure) {
        self.total = total; self.used = used; self.appMemory = appMemory; self.wired = wired
        self.compressed = compressed; self.free = free; self.swapUsed = swapUsed
        self.swapTotal = swapTotal; self.pressure = pressure
    }
    public static let zero = SystemMemory(total: 0, used: 0, appMemory: 0, wired: 0, compressed: 0,
                                          free: 0, swapUsed: 0, swapTotal: 0, pressure: .normal)
}

public enum SignalResult: Sendable, Equatable, Hashable, Codable {
    case sent, gone, mismatch, refused(String), dryRun, failed(Int32)
}

public protocol SysKit: Sendable {
    func scan() -> ProcessTable
    /// Cached per key; nil for processes we cannot read (other uid, zombie, gone).
    func args(_ k: ProcKey) -> ProcArgs?
    /// PROC_PIDVNODEPATHINFO cwd.
    func cwd(_ pid: Int32) -> String?
    func systemMemory() -> SystemMemory
    /// pid exists and its start time still equals k.startSec.
    func isAlive(_ k: ProcKey) -> Bool
}

// MARK: - Ownership (§3)

public enum Owner: Sendable, Hashable, Codable {
    /// Main (the user's own) Chrome browser subtree.
    case chrome(browserPid: Int32)
    /// The live claude process itself.
    case session(ProcKey)
    /// A ppid descendant of a live claude.
    case claudeChild(ProcKey)
    /// An env-linked unit (CLAUDE_PID = live session), including automation browsers under it.
    case claudeBackground(ProcKey)
    /// Env-linked unit whose CLAUDE_PID is dead or mismatched.
    case leftover(pgid: Int32, deadClaudePid: Int32)
    /// Automation browser no session owns → "Other Chrome instances" (locked).
    case otherChrome(browserPid: Int32)
    /// A `/claude/versions/` process with no sessions JSON (always confirm).
    case unregisteredClaude(ProcKey)
    case unowned
}

public struct BrowserInstance: Sendable, Hashable, Codable {
    public let key: ProcKey
    public let isMain: Bool
    public let userDataDir: String?
    public let headless: Bool
    public let remoteDebugging: Bool
    public init(key: ProcKey, isMain: Bool, userDataDir: String?, headless: Bool, remoteDebugging: Bool = false) {
        self.key = key; self.isMain = isMain; self.userDataDir = userDataDir
        self.headless = headless; self.remoteDebugging = remoteDebugging
    }
}

public struct OwnershipMap: Sendable, Codable {
    /// Every pid appears at most once (the no-double-count invariant). Pids absent here are unowned.
    public let owner: [Int32: Owner]
    public let browsers: [BrowserInstance]
    /// Sessions that passed the §3 step-2 liveness check.
    public let liveSessions: [ProcKey]
    /// Session JSON files that failed the liveness check (never deleted; counted in the footer).
    public let staleSessionFiles: [String]
    public init(owner: [Int32: Owner], browsers: [BrowserInstance], liveSessions: [ProcKey] = [],
                staleSessionFiles: [String] = []) {
        self.owner = owner; self.browsers = browsers
        self.liveSessions = liveSessions; self.staleSessionFiles = staleSessionFiles
    }
    public static let empty = OwnershipMap(owner: [:], browsers: [])
    public var mainBrowsers: [BrowserInstance] { browsers.filter(\.isMain) }
    public func pids(ownedBy o: Owner) -> [Int32] { owner.compactMap { $0.value == o ? $0.key : nil }.sorted() }
}

// MARK: - Item identity (see ItemID.swift for the string codec)

public enum ItemID: Hashable, Sendable {
    case chromeWindow(browserPid: Int32, windowId: Int)
    case chromeTab(browserPid: Int32, tabId: Int)
    /// kind ∈ ChromeOverheadKind raw values: browser, gpu, utility, crashpad, extensions, background, otherInstances
    case chromeOverhead(browserPid: Int32, kind: String)
    /// Children, background units, automation browsers, overhead processes.
    case process(ProcKey)
    case session(ProcKey)
    case leftover(pgid: Int32, leaderStartSec: Int)
}

public enum ItemKind: String, Sendable, Codable, CaseIterable {
    case window, tab, overhead, process, session, leftover
}

// MARK: - Chrome

/// A tab identity that is unique across browsers (tab ids are only unique per browser pid).
public struct TabRef: Hashable, Sendable, Codable, Comparable {
    public let browserPid: Int32
    public let tabId: Int
    public init(browserPid: Int32, tabId: Int) { self.browserPid = browserPid; self.tabId = tabId }
    public var itemID: ItemID { .chromeTab(browserPid: browserPid, tabId: tabId) }
    public static func < (a: TabRef, b: TabRef) -> Bool { (a.browserPid, a.tabId) < (b.browserPid, b.tabId) }
}

public struct ChromeFrame: Sendable, Hashable, Codable {
    public let frameId, parentFrameId, processId: Int
    /// active, cached, prerender, pending
    public let lifecycle: String
    public init(frameId: Int, parentFrameId: Int, processId: Int, lifecycle: String) {
        self.frameId = frameId; self.parentFrameId = parentFrameId
        self.processId = processId; self.lifecycle = lifecycle
    }
}

public struct ChromeTab: Sendable, Hashable, Codable {
    public let browserPid: Int32
    public let id, windowId, index: Int
    public let title, url, host: String
    public let active, audible, pinned, discarded, incognito: Bool
    public let lastAccessed: Date?
    public let frames: [ChromeFrame]
    /// Fair-share footprint (§4.4); nil = per-tab memory unavailable ("—").
    public var display: Bytes?
    public var exclusive: Bytes
    /// |users[mainFrameProc]| − 1; > 0 shows "≈" and ⛓×N.
    public var sharedWith: Int
    public var procs: [ProcKey]
    public init(browserPid: Int32, id: Int, windowId: Int, index: Int, title: String, url: String, host: String,
                active: Bool = false, audible: Bool = false, pinned: Bool = false, discarded: Bool = false,
                incognito: Bool = false, lastAccessed: Date? = nil, frames: [ChromeFrame] = [],
                display: Bytes? = nil, exclusive: Bytes = 0, sharedWith: Int = 0, procs: [ProcKey] = []) {
        self.browserPid = browserPid; self.id = id; self.windowId = windowId; self.index = index
        self.title = title; self.url = url; self.host = host; self.active = active; self.audible = audible
        self.pinned = pinned; self.discarded = discarded; self.incognito = incognito
        self.lastAccessed = lastAccessed; self.frames = frames; self.display = display
        self.exclusive = exclusive; self.sharedWith = sharedWith; self.procs = procs
    }
    public var ref: TabRef { TabRef(browserPid: browserPid, tabId: id) }
    public var itemID: ItemID { .chromeTab(browserPid: browserPid, tabId: id) }
}

public struct ChromeWindow: Sendable, Hashable, Codable {
    public let browserPid: Int32
    public let id: Int
    public let focused, incognito: Bool
    public var tabIds: [Int]
    public init(browserPid: Int32, id: Int, focused: Bool = false, incognito: Bool = false, tabIds: [Int] = []) {
        self.browserPid = browserPid; self.id = id; self.focused = focused
        self.incognito = incognito; self.tabIds = tabIds
    }
    public var itemID: ItemID { .chromeWindow(browserPid: browserPid, windowId: id) }
}

public enum ChromeDataSource: Sendable, Equatable, Hashable, Codable {
    case notRunning, helper(profiles: Int), appleScript, processesOnly, waiting
    public var name: String {
        switch self {
        case .notRunning: "notRunning"; case .helper: "helper"; case .appleScript: "appleScript"
        case .processesOnly: "processesOnly"; case .waiting: "waiting"
        }
    }
}

/// Keys of ChromeSnapshot.overhead and ItemID.chromeOverhead(kind:).
public enum ChromeOverheadKind: String, Sendable, Codable, CaseIterable {
    case browser, gpu, utility, crashpad, extensions, background, otherInstances
    /// Renderers of tabs the helper cannot see (incognito without "Allow in Incognito", a profile without the
    /// helper). Only used when such tabs are known to exist.
    case hiddenTabs
}

public struct OverheadStat: Sendable, Hashable, Codable {
    public var count: Int
    public var bytes: Bytes
    public init(count: Int, bytes: Bytes) { self.count = count; self.bytes = bytes }
}

public struct ChromeSnapshot: Sendable, Codable {
    public var source: ChromeDataSource
    public var windows: [ChromeWindow]
    public var tabs: [ChromeTab]
    /// Keyed by ChromeOverheadKind.rawValue.
    public var overhead: [String: OverheadStat]
    /// Σ footprint over all main-browser pids plus unowned automation browsers ("Other Chrome instances"),
    /// so the section equals tabs + "Chrome itself". Never computed as a sum of tab values.
    public var total: Bytes
    /// Renderer footprints (main browser renderers only).
    public var procFootprint: [ProcKey: Bytes]
    /// users[c]: tabs with any frame in renderer c (ProcKey scopes it to one browser).
    public var procUsers: [ProcKey: Set<TabRef>]
    public var perTabUnavailable: String?
    public var staleSince: Date?
    /// A warning about tabs the helper cannot see ("Allow in Incognito" is off, a profile without the helper).
    public var helperNote: String?
    /// The helper extension's own renderer footprint, when it can be identified.
    public var helperBytes: Bytes?
    public init(source: ChromeDataSource, windows: [ChromeWindow] = [], tabs: [ChromeTab] = [],
                overhead: [String: OverheadStat] = [:], total: Bytes = 0,
                procFootprint: [ProcKey: Bytes] = [:], procUsers: [ProcKey: Set<TabRef>] = [:],
                perTabUnavailable: String? = nil, staleSince: Date? = nil, helperNote: String? = nil,
                helperBytes: Bytes? = nil) {
        self.source = source; self.windows = windows; self.tabs = tabs; self.overhead = overhead
        self.total = total; self.procFootprint = procFootprint; self.procUsers = procUsers
        self.perTabUnavailable = perTabUnavailable; self.staleSince = staleSince
        self.helperNote = helperNote; self.helperBytes = helperBytes
    }
    public static let notRunning = ChromeSnapshot(source: .notRunning)

    /// freed(S) = Σ fp[c] where users[c] ≠ ∅ and users[c] ⊆ S (§4.4).
    public func freed(_ tabs: Set<TabRef>) -> Bytes {
        var sum: Bytes = 0
        for (proc, users) in procUsers where !users.isEmpty && users.isSubset(of: tabs) {
            sum += procFootprint[proc] ?? 0
        }
        return sum
    }
    public func tab(_ ref: TabRef) -> ChromeTab? { tabs.first { $0.ref == ref } }
    public func tabs(inWindow w: ChromeWindow) -> [ChromeTab] {
        tabs.filter { $0.browserPid == w.browserPid && $0.windowId == w.id }.sorted { $0.index < $1.index }
    }
    public var overheadTotal: Bytes { overhead.values.reduce(0) { $0 + $1.bytes } }
}

/// One tab to close, with the URL the user saw (the extension/JXA skip it if it changed).
public struct TabCloseRequest: Sendable, Hashable, Codable {
    public let browserPid: Int32
    public let id: Int
    public let expectedURL: String
    public init(browserPid: Int32, id: Int, expectedURL: String) {
        self.browserPid = browserPid; self.id = id; self.expectedURL = expectedURL
    }
    public var itemID: ItemID { .chromeTab(browserPid: browserPid, tabId: id) }
}

public protocol ChromeProvider: Sendable {
    /// Connected hosts' hellos (browserPid identifies the main browser for Ownership). [] if none.
    func hosts() async -> [Wire.HostHello]
    func snapshot(_ t: ProcessTable, _ o: OwnershipMap, _ sys: any SysKit) async -> ChromeSnapshot
    func close(_ tabs: [TabCloseRequest]) async -> [ItemID: Outcome]
    func discard(_ tabs: [ItemID]) async -> [ItemID: Outcome]
    func activate(_ tab: ItemID) async
    func restore(_ r: [ClosedRecord]) async -> [ClosedRecord: Outcome]
    /// "persistent" | "on-demand"
    func setMode(_ m: String) async
}

// MARK: - Claude

/// One ~/.claude/sessions/<pid>.json, decoded leniently (every field optional). Input to Ownership.
public struct SessionRecord: Sendable, Hashable, Codable {
    public var pid: Int32?
    public var sessionId: String?
    public var cwd: String?
    /// ms since 1970
    public var startedAt: Double?
    /// "Tue Sep 29 16:28:53 2026", UTC, en_US_POSIX "EEE MMM d HH:mm:ss yyyy"
    public var procStart: String?
    public var version: String?
    public var kind: String?
    public var entrypoint: String?
    /// "millrace:@151.%176" — stale except the %pane id (a hint only).
    public var tmux: String?
    public var name: String?
    public var nameSource: String?
    public var status: String?
    /// ms since 1970
    public var statusUpdatedAt: Double?
    public var updatedAt: Double?
    public var bridgeSessionId: String?
    /// Set by the reader, not the JSON.
    public var filePath: String?
    public init(pid: Int32? = nil, sessionId: String? = nil, cwd: String? = nil, startedAt: Double? = nil,
                procStart: String? = nil, version: String? = nil, kind: String? = nil, entrypoint: String? = nil,
                tmux: String? = nil, name: String? = nil, nameSource: String? = nil, status: String? = nil,
                statusUpdatedAt: Double? = nil, updatedAt: Double? = nil, bridgeSessionId: String? = nil,
                filePath: String? = nil) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd; self.startedAt = startedAt
        self.procStart = procStart; self.version = version; self.kind = kind; self.entrypoint = entrypoint
        self.tmux = tmux; self.name = name; self.nameSource = nameSource; self.status = status
        self.statusUpdatedAt = statusUpdatedAt; self.updatedAt = updatedAt
        self.bridgeSessionId = bridgeSessionId; self.filePath = filePath
    }
    /// The `%NN` pane id from the `tmux` field, if any.
    public var tmuxPaneHint: String? {
        guard let t = tmux, let r = t.range(of: "%") else { return nil }
        return String(t[r.lowerBound...])
    }
}

/// One line of `tmux list-panes -a -F …` (§5).
public struct TmuxPane: Sendable, Hashable, Codable {
    public let paneId: String
    public let panePid: Int32
    public let paneActive, windowActive: Bool
    public let sessionAttached: Int
    public let session: String
    public let windowIndex, paneIndex: Int
    public let windowName, paneTitle, currentCommand: String
    public init(paneId: String, panePid: Int32, paneActive: Bool, windowActive: Bool, sessionAttached: Int,
                session: String, windowIndex: Int, paneIndex: Int, windowName: String, paneTitle: String,
                currentCommand: String) {
        self.paneId = paneId; self.panePid = panePid; self.paneActive = paneActive
        self.windowActive = windowActive; self.sessionAttached = sessionAttached; self.session = session
        self.windowIndex = windowIndex; self.paneIndex = paneIndex; self.windowName = windowName
        self.paneTitle = paneTitle; self.currentCommand = currentCommand
    }
    public var visible: Bool { paneActive && windowActive && sessionAttached > 0 }
}

/// One line of `tmux list-clients -F …`.
public struct TmuxClientInfo: Sendable, Hashable, Codable {
    public let activity: Int
    public let tty: String
    public let session: String
    public init(activity: Int, tty: String, session: String) {
        self.activity = activity; self.tty = tty; self.session = session
    }
}

public struct TmuxLoc: Sendable, Hashable, Codable {
    public let paneId, session, windowName: String
    public let windowIndex, paneIndex: Int
    public let panePid: Int32
    public let visible, current: Bool
    public init(paneId: String, session: String, windowName: String, windowIndex: Int, paneIndex: Int,
                panePid: Int32 = 0, visible: Bool = false, current: Bool = false) {
        self.paneId = paneId; self.session = session; self.windowName = windowName
        self.windowIndex = windowIndex; self.paneIndex = paneIndex; self.panePid = panePid
        self.visible = visible; self.current = current
    }
    /// "hub:3.1"
    public var label: String { "\(session):\(windowIndex).\(paneIndex)" }
}

public struct LinkedUnit: Sendable, Hashable, Codable {
    public let root: ProcKey
    public let pgid: Int32
    /// Display label from the root's argv, e.g. "bun run dev --port 3217".
    public let command: String
    public let argv: [String]
    public let cwd: String?
    public let members: [ProcKey]
    public let footprint: Bytes
    public let isAutomationBrowser: Bool
    public init(root: ProcKey, pgid: Int32, command: String, argv: [String] = [], cwd: String? = nil,
                members: [ProcKey], footprint: Bytes, isAutomationBrowser: Bool = false) {
        self.root = root; self.pgid = pgid; self.command = command; self.argv = argv; self.cwd = cwd
        self.members = members; self.footprint = footprint; self.isAutomationBrowser = isAutomationBrowser
    }
    public var itemID: ItemID { .process(root) }
}

public struct ClaudeSession: Sendable, Hashable, Codable {
    public let key: ProcKey
    public let sessionId, cwd, title, project: String
    public let worktree, branch: String?
    public let cwdExists, hasTranscript, busy, remoteControl, isLauncher, unregistered: Bool
    /// Raw JSON status ("idle", "busy", …, or "unknown").
    public let status: String
    public let statusSince, lastActivity: Date?
    public let startedAt: Date
    public let cpuPercent: Double
    public let lastPrompt, lastAssistant, awaySummary: String?
    public let tmux: TmuxLoc?
    public let kind, version: String
    public let selfFootprint, selfRSS: Bytes
    /// ppid descendants (tool shells, MCP servers …).
    public let children: [LinkedUnit]
    /// env-linked units, including automation browsers.
    public let background: [LinkedUnit]
    public init(key: ProcKey, sessionId: String, cwd: String, title: String, project: String,
                worktree: String? = nil, branch: String? = nil, cwdExists: Bool = true, hasTranscript: Bool = true,
                busy: Bool = false, remoteControl: Bool = false, isLauncher: Bool = false, unregistered: Bool = false,
                status: String = "idle", statusSince: Date? = nil, lastActivity: Date? = nil, startedAt: Date,
                cpuPercent: Double = 0, lastPrompt: String? = nil, lastAssistant: String? = nil,
                awaySummary: String? = nil, tmux: TmuxLoc? = nil, kind: String = "interactive",
                version: String = "", selfFootprint: Bytes, selfRSS: Bytes = 0,
                children: [LinkedUnit] = [], background: [LinkedUnit] = []) {
        self.key = key; self.sessionId = sessionId; self.cwd = cwd; self.title = title; self.project = project
        self.worktree = worktree; self.branch = branch; self.cwdExists = cwdExists
        self.hasTranscript = hasTranscript; self.busy = busy; self.remoteControl = remoteControl
        self.isLauncher = isLauncher; self.unregistered = unregistered; self.status = status
        self.statusSince = statusSince; self.lastActivity = lastActivity; self.startedAt = startedAt
        self.cpuPercent = cpuPercent; self.lastPrompt = lastPrompt; self.lastAssistant = lastAssistant
        self.awaySummary = awaySummary; self.tmux = tmux; self.kind = kind; self.version = version
        self.selfFootprint = selfFootprint; self.selfRSS = selfRSS
        self.children = children; self.background = background
    }
    public var itemID: ItemID { .session(key) }
    public var backgroundBytes: Bytes { background.reduce(0) { $0 + $1.footprint } }
    public var childrenBytes: Bytes { children.reduce(0) { $0 + $1.footprint } }
    /// claude + children + background.
    public var total: Bytes { selfFootprint + childrenBytes + backgroundBytes }
    /// Idle age reference = max(statusSince, lastActivity) (§5). Meaningful only when !busy.
    public var idleSince: Date? {
        switch (statusSince, lastActivity) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        default: nil
        }
    }
    public var resumeCommand: String {
        "cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))' && claude --resume \(sessionId)"
    }
}

public struct LeftoverGroup: Sendable, Hashable, Codable {
    /// Always .leftover(pgid:leaderStartSec:)
    public let id: ItemID
    public let unit: LinkedUnit
    public let deadClaudePid: Int32
    public let sessionId, sessionTitle, cwd: String?
    public let startedAt: Date
    public init(id: ItemID, unit: LinkedUnit, deadClaudePid: Int32, sessionId: String? = nil,
                sessionTitle: String? = nil, cwd: String? = nil, startedAt: Date) {
        self.id = id; self.unit = unit; self.deadClaudePid = deadClaudePid; self.sessionId = sessionId
        self.sessionTitle = sessionTitle; self.cwd = cwd; self.startedAt = startedAt
    }
}

public struct ClaudeSnapshot: Sendable, Codable {
    public var sessions: [ClaudeSession]
    public var leftovers: [LeftoverGroup]
    public var staleFiles: [String]
    public init(sessions: [ClaudeSession] = [], leftovers: [LeftoverGroup] = [], staleFiles: [String] = []) {
        self.sessions = sessions; self.leftovers = leftovers; self.staleFiles = staleFiles
    }
    public static let empty = ClaudeSnapshot()
    public var sessionsTotal: Bytes { sessions.reduce(0) { $0 + $1.total } }
    public var leftoversTotal: Bytes { leftovers.reduce(0) { $0 + $1.unit.footprint } }
}

public protocol ClaudeProvider: Sendable {
    /// Parsed ~/.claude/sessions/*.json (input to Ownership.assign; no liveness check yet).
    func sessionRecords() async -> [SessionRecord]
    func snapshot(_ t: ProcessTable, _ o: OwnershipMap, _ sys: any SysKit) async -> ClaudeSnapshot
    func jump(_ s: ProcKey) async
    func reopen(_ r: [ClosedRecord]) async -> [ClosedRecord: Outcome]
}

// MARK: - World

public struct WorldSnapshot: Sendable, Codable {
    public let system: SystemMemory
    public let chrome: ChromeSnapshot
    public let claude: ClaudeSnapshot
    public let ownership: OwnershipMap
    /// Headroom's own footprint (app or CLI) + connected hosts.
    public let selfBytes: Bytes
    /// The helper extension's renderer footprint, when known.
    public let helperBytes: Bytes?
    public let at: Date
    public let isMock: Bool
    public init(system: SystemMemory, chrome: ChromeSnapshot, claude: ClaudeSnapshot, ownership: OwnershipMap,
                selfBytes: Bytes, helperBytes: Bytes? = nil, at: Date, isMock: Bool = false) {
        self.system = system; self.chrome = chrome; self.claude = claude; self.ownership = ownership
        self.selfBytes = selfBytes; self.helperBytes = helperBytes; self.at = at; self.isMock = isMock
    }
    public static let empty = WorldSnapshot(system: .zero, chrome: .notRunning, claude: .empty,
                                            ownership: .empty, selfBytes: 0, at: .distantPast)
}

/// How the App and the CLI obtain a snapshot (live: SysKit+Ownership+providers; mock: MockWorld).
public protocol WorldProvider: Sendable {
    func snapshot() async -> WorldSnapshot
}

// MARK: - Actions

public enum Reason: Sendable, Hashable, Codable {
    case busy(String?), recentActivity, visiblePane, notInTmux, hasBackground(Int, Bytes),
         noTranscript, cwdMissing, unregistered, audible, pinned, emptiesWindow(Int), closesAllWindows,
         leftover, manyItems, launcher, pidMismatch, chromeCore,
         /// A child or background process of a live session: close the session instead.
         childProcess
}

public enum Protection: Sendable, Hashable, Codable {
    case none, confirm([Reason]), locked(Reason)
    public var isLocked: Bool { if case .locked = self { true } else { false } }
    public var reasons: [Reason] {
        switch self { case .none: []; case .confirm(let r): r; case .locked(let r): [r] }
    }
    /// "none" | "confirm" | "locked"
    public var level: String {
        switch self { case .none: "none"; case .confirm: "confirm"; case .locked: "locked" }
    }
}

public enum Outcome: Sendable, Hashable, Codable {
    case done, alreadyGone, changedSkipped, stayedOpen, stillAlive, dryRun, failed(String)
}

public struct PlanItem: Sendable, Hashable, Codable {
    public let id: ItemID
    public let protection: Protection
    /// freed() estimate for this item.
    public let bytes: Bytes
    public let title: String
    public init(id: ItemID, protection: Protection, bytes: Bytes, title: String = "") {
        self.id = id; self.protection = protection; self.bytes = bytes; self.title = title
    }
}

public struct LockedItem: Sendable, Hashable, Codable {
    public let id: ItemID
    public let reason: Reason
    public init(id: ItemID, reason: Reason) { self.id = id; self.reason = reason }
}

public struct ClosePlan: Sendable, Codable {
    /// Closable items after window expansion and de-duplication.
    public let items: [PlanItem]
    public let locked: [LockedItem]
    public let estimate: Bytes
    /// The snapshot the plan was made from (the executor revalidates against live state anyway).
    public let world: WorldSnapshot
    /// Sheet checkbox "Also stop N background processes".
    public var stopBackground: Bool
    /// Busy sessions are skipped unless the user picked "Close All".
    public var skipBusy: Bool
    public init(items: [PlanItem], locked: [LockedItem], estimate: Bytes, world: WorldSnapshot,
                stopBackground: Bool = true, skipBusy: Bool = true) {
        self.items = items; self.locked = locked; self.estimate = estimate; self.world = world
        self.stopBackground = stopBackground; self.skipBusy = skipBusy
    }
    /// Any item has a confirm reason.
    public var needsSheet: Bool {
        items.contains { if case .confirm = $0.protection { true } else { false } }
    }
    /// The sheet shows even under ⌥ (busy / leftover / unregistered), and the CLI refuses without --force-confirm.
    public var sheetMandatory: Bool {
        items.contains { item in
            item.protection.reasons.contains { r in
                switch r { case .busy, .leftover, .unregistered: true; default: false }
            }
        }
    }
    public var isEmpty: Bool { items.isEmpty }
}

public struct ClosedRecord: Codable, Sendable, Hashable {
    /// Stable record id (UUID string); `headroom undo <record-id>`.
    public let id: String
    /// Shared by all records of one close batch (one ⌘Z).
    public let batchId: String
    /// "tab" | "session" | "leftover" | "process"
    public let kind: String
    /// ItemID.stringValue of the closed item.
    public let itemId: String
    public let closedAt: Date
    public let title: String
    public let bytes: Bytes
    /// "app" | "cli"
    public var source: String
    // Tabs
    public var url: String?
    public var browserPid: Int32?
    public var windowId, index: Int?
    public var chromeSessionId: String?
    public var incognito: Bool?
    // Sessions / leftovers
    public var sessionId, cwd, tmuxSession: String?
    public var argv: [String]?
    public init(id: String = UUID().uuidString, batchId: String, kind: String, itemId: String, closedAt: Date,
                title: String, bytes: Bytes, source: String = "app", url: String? = nil, browserPid: Int32? = nil,
                windowId: Int? = nil, index: Int? = nil, chromeSessionId: String? = nil, incognito: Bool? = nil,
                sessionId: String? = nil, cwd: String? = nil, tmuxSession: String? = nil, argv: [String]? = nil) {
        self.id = id; self.batchId = batchId; self.kind = kind; self.itemId = itemId; self.closedAt = closedAt
        self.title = title; self.bytes = bytes; self.source = source; self.url = url; self.browserPid = browserPid
        self.windowId = windowId; self.index = index; self.chromeSessionId = chromeSessionId
        self.incognito = incognito; self.sessionId = sessionId; self.cwd = cwd
        self.tmuxSession = tmuxSession; self.argv = argv
    }
    /// Leftovers (and incognito tabs without helper access) cannot be restored.
    public var restorable: Bool { kind == "tab" ? (url != nil) : kind == "session" && sessionId != nil }
}

public enum ActionEvent: Sendable {
    case progress(ItemID, Outcome)
    case needsForce([ItemID])
    case finished([ClosedRecord])
}

public protocol ActionExecutor: Sendable {
    /// Protection for every closable/lockable row in `w` (used by list/suggest and the UI glyphs).
    func protections(_ w: WorldSnapshot) -> [ItemID: Protection]
    func plan(_ sel: Set<ItemID>, _ w: WorldSnapshot) -> ClosePlan
    func execute(_ p: ClosePlan) -> AsyncStream<ActionEvent>
    func forceQuit(_ ids: [ItemID]) async
    func sleep(_ tabs: [ItemID]) async -> [ItemID: Outcome]
    func undo(_ r: [ClosedRecord]) async -> [ClosedRecord: Outcome]
    func jump(_ id: ItemID) async
    /// Recently Closed store (closed.jsonl, newest first, last 7 days). Shared by App and CLI.
    func recentlyClosed() async -> [ClosedRecord]
}

/// What both the App and the CLI get from `Headroom.live()` / `Headroom.mock()` (HeadroomActions).
public struct HeadroomContext: Sendable {
    public let world: any WorldProvider
    public let executor: any ActionExecutor
    public let env: HeadroomEnv
    public let isMock: Bool
    public init(world: any WorldProvider, executor: any ActionExecutor, env: HeadroomEnv, isMock: Bool) {
        self.world = world; self.executor = executor; self.env = env; self.isMock = isMock
    }
}
