// Stable JSON models for the `headroom` CLI (`list --json`, `suggest --json`). Documented in docs/cli.md;
// agents consume these, so fields are only ever added, never renamed or removed. Bump `schema` on breaks.

import Foundation

/// `headroom list --kind …`
public enum ListKind: String, Sendable, Codable, CaseIterable {
    case tabs, sessions, leftovers, docker, all
    public func includes(_ k: ItemKind) -> Bool {
        switch self {
        case .all: [.tab, .session, .leftover, .container].contains(k)
        case .tabs: k == .tab
        case .sessions: k == .session
        case .leftovers: k == .leftover
        case .docker: k == .container
        }
    }
}

/// One line of Docker disk use (`list --json` → docker.disk).
public struct DockerDiskStatJSON: Codable, Sendable, Hashable {
    public let count: Int
    public let bytes: Bytes
    public let reclaimableBytes: Bytes
    public init(_ s: DockerDiskStat) { count = s.count; bytes = s.size; reclaimableBytes = s.reclaimable }
}

public struct DockerDiskJSON: Codable, Sendable, Hashable {
    public let totalBytes: Bytes
    public let reclaimableBytes: Bytes
    public let images, containers, volumes, buildCache: DockerDiskStatJSON
    /// When it was read (it is slow, so it is cached; `list --disk` reads it again).
    public let readAt: Date
    public init(_ d: DockerDisk) {
        totalBytes = d.total; reclaimableBytes = d.reclaimable
        images = DockerDiskStatJSON(d.images); containers = DockerDiskStatJSON(d.containers)
        volumes = DockerDiskStatJSON(d.volumes); buildCache = DockerDiskStatJSON(d.buildCache)
        readAt = d.at
    }
}

public struct DockerContainerJSON: Codable, Sendable, Hashable {
    /// The full container id. Headroom cannot close containers: this is not an ItemID.
    public let id: String
    public let name: String
    public let image: String
    public let project: String?
    public let service: String?
    public let state: String
    public let status: String
    /// Memory in use inside the VM (as `docker stats` shows it). nil = not read.
    public let bytes: Bytes?
    public let limitBytes: Bytes?
    /// Percent of one CPU. nil in the CLI (it takes one sample; CPU% needs two).
    public let cpuPercent: Double?
    public let pids: Int?
    public let createdAt: Date?
    public init(_ c: DockerContainer) {
        id = c.id; name = c.name; image = c.image; project = c.project; service = c.service
        state = c.state; status = c.status; bytes = c.memory; limitBytes = c.memoryLimit
        cpuPercent = c.cpuPercent; pids = c.pids; createdAt = c.createdAt
    }
}

/// `headroom list --json` → `docker` (read-only insight; omitted when this Mac has no Docker).
public struct DockerJSON: Codable, Sendable, Hashable {
    /// "running" | "notRunning"
    public let status: String
    /// "colima", "Docker Desktop", "OrbStack"…
    public let runtime: String
    /// What the VM holds on this Mac. nil = the VM's process was not identified.
    public let vmBytes: Bytes?
    /// Memory the VM may use.
    public let vmLimitBytes: Bytes?
    public let cpus: Int?
    /// Σ container memory inside the VM.
    public let containersBytes: Bytes
    public let running: Int
    public let stopped: Int
    public let images: Int
    /// Running containers, largest first.
    public let containers: [DockerContainerJSON]
    public let disk: DockerDiskJSON?
    public init(_ d: DockerSnapshot) {
        status = d.status.rawValue; runtime = d.runtime; vmBytes = d.vmFootprint; vmLimitBytes = d.vmMemoryLimit
        cpus = d.cpus; containersBytes = d.containersMemory; running = d.containers.count
        stopped = d.stoppedCount; images = d.imageCount
        containers = d.containers.sorted { ($0.memory ?? 0, $1.name) > ($1.memory ?? 0, $0.name) }
            .map(DockerContainerJSON.init)
        disk = d.disk.map(DockerDiskJSON.init)
    }
}

public struct ReasonJSON: Codable, Sendable, Hashable {
    public let code: String
    public let text: String
    public init(_ r: Reason) { code = r.code; text = r.text }
}

public struct SystemJSON: Codable, Sendable, Hashable {
    public let totalBytes, usedBytes, compressedBytes, wiredBytes, freeBytes, swapUsedBytes, swapTotalBytes: Bytes
    /// "normal" | "warning" | "critical"
    public let pressure: String
    public init(_ s: SystemMemory) {
        totalBytes = s.total; usedBytes = s.used; compressedBytes = s.compressed; wiredBytes = s.wired
        freeBytes = s.free; swapUsedBytes = s.swapUsed; swapTotalBytes = s.swapTotal; pressure = s.pressure.name
    }
}

public struct SectionTotalsJSON: Codable, Sendable, Hashable {
    /// ChromeDataSource.name
    public let chromeSource: String
    public let chromeBytes: Bytes
    public let chromeOverheadBytes: Bytes
    public let chromePerTabUnavailable: String?
    public let sessionsBytes: Bytes
    public let leftoversBytes: Bytes
    public let staleSessionFiles: Int
    public let headroomBytes: Bytes
    /// Tabs the helper cannot see (incognito without "Allow in Incognito", a profile without the helper).
    public var chromeHelperNote: String? = nil
}

/// One row of `headroom list --json`. Flat on purpose: fields that do not apply to a kind are omitted.
public struct ListItem: Codable, Sendable, Hashable {
    /// Stable ItemID string, e.g. "tab:812:1234", "session:41321:1790699334".
    public let id: String
    /// "tab" | "session" | "leftover"
    public let kind: String
    public let title: String
    /// Footprint bytes (fair share for tabs; claude+children+background for sessions). nil = unknown ("—").
    public let bytes: Bytes?
    public let url: String?
    public let cwd: String?
    /// Seconds since last activity (sessions: max(statusUpdatedAt, lastActivity); tabs: lastAccessed).
    public let idleSeconds: Int?
    public let lastActivity: Date?
    /// tab: "active" | "audible" | "sleeping" | "background"; session: "busy" | "idle"; leftover: "orphaned"
    public let status: String
    /// "none" | "confirm" | "locked"
    public let protection: String
    public let reasons: [ReasonJSON]

    // Tabs
    public let browserPid: Int32?
    public let windowId: Int?
    public let pinned: Bool?
    public let audible: Bool?
    public let incognito: Bool?
    public let sharedWith: Int?
    // Sessions
    public let pid: Int32?
    public let sessionId: String?
    /// "hub:3.1"
    public let tmux: String?
    public let branch: String?
    public let worktree: String?
    public let backgroundBytes: Bytes?
    public let remoteControl: Bool?
    public let lastPrompt: String?
    public let resumeCommand: String?
    // Leftovers
    public let pgid: Int32?
    public let command: String?
    public let deadClaudePid: Int32?
    /// Leftovers: when the process group's leader started, and how long it has run (seconds).
    public var startedAt: Date? = nil
    public var runningSeconds: Int? = nil
    /// Rex location "foundry:2.1" (session:tab.pane); nil when not in Rex. `tmux` stays tmux-only.
    public var rex: String? = nil

    public init(id: String, kind: String, title: String, bytes: Bytes?, url: String? = nil, cwd: String? = nil,
                idleSeconds: Int? = nil, lastActivity: Date? = nil, status: String, protection: String,
                reasons: [ReasonJSON], browserPid: Int32? = nil, windowId: Int? = nil, pinned: Bool? = nil,
                audible: Bool? = nil, incognito: Bool? = nil, sharedWith: Int? = nil, pid: Int32? = nil,
                sessionId: String? = nil, tmux: String? = nil, branch: String? = nil, worktree: String? = nil,
                backgroundBytes: Bytes? = nil, remoteControl: Bool? = nil, lastPrompt: String? = nil,
                resumeCommand: String? = nil, pgid: Int32? = nil, command: String? = nil, deadClaudePid: Int32? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.bytes = bytes; self.url = url; self.cwd = cwd
        self.idleSeconds = idleSeconds; self.lastActivity = lastActivity; self.status = status
        self.protection = protection; self.reasons = reasons; self.browserPid = browserPid
        self.windowId = windowId; self.pinned = pinned; self.audible = audible; self.incognito = incognito
        self.sharedWith = sharedWith; self.pid = pid; self.sessionId = sessionId; self.tmux = tmux
        self.branch = branch; self.worktree = worktree; self.backgroundBytes = backgroundBytes
        self.remoteControl = remoteControl; self.lastPrompt = lastPrompt; self.resumeCommand = resumeCommand
        self.pgid = pgid; self.command = command; self.deadClaudePid = deadClaudePid
    }
}

/// `headroom list --json`
public struct ListSnapshot: Codable, Sendable {
    public static let currentSchema = 1
    public let schema: Int
    public let generatedAt: Date
    public let dryRun: Bool
    public let mock: Bool
    public let system: SystemJSON
    public let totals: SectionTotalsJSON
    public let items: [ListItem]
    /// Docker containers, VM and disk use (additive). nil when not asked for or when there is no Docker.
    public var docker: DockerJSON? = nil

    /// Builds the list from a world and the executor's protections. Items are sorted by bytes, descending.
    /// Incognito tab URLs are omitted.
    public init(world w: WorldSnapshot, protections: [ItemID: Protection], kind: ListKind = .all,
                dryRun: Bool, now: Date = Date()) {
        func prot(_ id: ItemID) -> Protection { protections[id] ?? .none }
        func idle(_ d: Date?) -> Int? { d.map { max(0, Int(now.timeIntervalSince($0))) } }
        var items: [ListItem] = []
        if kind.includes(.tab) {
            for t in w.chrome.tabs {
                let p = prot(t.itemID)
                let status = t.discarded ? "sleeping" : t.audible ? "audible" : t.active ? "active" : "background"
                items.append(ListItem(
                    id: t.itemID.stringValue, kind: "tab", title: t.title, bytes: t.display,
                    url: t.incognito ? nil : t.url, idleSeconds: t.active ? 0 : idle(t.lastAccessed),
                    lastActivity: t.lastAccessed, status: status, protection: p.level,
                    reasons: p.reasons.map(ReasonJSON.init), browserPid: t.browserPid, windowId: t.windowId,
                    pinned: t.pinned, audible: t.audible, incognito: t.incognito, sharedWith: t.sharedWith))
            }
        }
        if kind.includes(.session) {
            for s in w.claude.sessions {
                let p = prot(s.itemID)
                var item = ListItem(
                    id: s.itemID.stringValue, kind: "session", title: s.title, bytes: s.total, cwd: s.cwd,
                    idleSeconds: s.busy ? nil : idle(s.idleSince), lastActivity: s.lastActivity,
                    status: s.busy ? "busy" : "idle", protection: p.level, reasons: p.reasons.map(ReasonJSON.init),
                    pid: s.key.pid, sessionId: s.sessionId, tmux: s.tmux?.label, branch: s.branch,
                    worktree: s.worktree, backgroundBytes: s.backgroundBytes, remoteControl: s.remoteControl,
                    lastPrompt: s.lastPrompt, resumeCommand: s.hasTranscript ? s.resumeCommand : nil)
                item.rex = s.rex?.label
                items.append(item)
            }
        }
        if kind.includes(.leftover) {
            for l in w.claude.leftovers {
                let p = prot(l.id)
                var item = ListItem(
                    id: l.id.stringValue, kind: "leftover", title: l.sessionTitle ?? l.unit.command,
                    bytes: l.unit.footprint, cwd: l.cwd ?? l.unit.cwd, idleSeconds: nil, lastActivity: nil,
                    status: "orphaned", protection: p.level, reasons: p.reasons.map(ReasonJSON.init),
                    sessionId: l.sessionId, pgid: l.unit.pgid, command: l.unit.command,
                    deadClaudePid: l.deadClaudePid)
                item.startedAt = l.startedAt
                item.runningSeconds = max(0, Int(now.timeIntervalSince(l.startedAt)))
                items.append(item)
            }
        }
        items.sort { ($0.bytes ?? 0, $1.id) > ($1.bytes ?? 0, $0.id) }
        self.schema = Self.currentSchema
        self.generatedAt = w.at
        self.dryRun = dryRun
        self.mock = w.isMock
        self.system = SystemJSON(w.system)
        self.totals = SectionTotalsJSON(
            chromeSource: w.chrome.source.name, chromeBytes: w.chrome.total,
            chromeOverheadBytes: w.chrome.overheadTotal, chromePerTabUnavailable: w.chrome.perTabUnavailable,
            sessionsBytes: w.claude.sessionsTotal, leftoversBytes: w.claude.leftoversTotal,
            staleSessionFiles: w.claude.staleFiles.count, headroomBytes: w.selfBytes,
            chromeHelperNote: w.chrome.helperNote)
        self.items = items
        self.docker = kind.includes(.container) && w.docker.status != .notFound ? DockerJSON(w.docker) : nil
    }
}

// MARK: - suggest

public enum Verdict: String, Codable, Sendable, CaseIterable {
    /// Rules say closing is safe (and Undo can bring it back where applicable).
    case safe
    /// A candidate, but the app would show the confirm sheet (CLI needs --force-confirm).
    case confirm
    /// Do not close.
    case keep
}

public struct Suggestion: Codable, Sendable, Hashable {
    /// Encodes as the ItemID string.
    public let id: ItemID
    public let verdict: Verdict
    /// Plain-English reason, e.g. "idle 6h, not busy, no background processes".
    public let reason: String
    /// Estimated bytes freed.
    public let bytes: Bytes
    public let title: String?
    public init(id: ItemID, verdict: Verdict, reason: String, bytes: Bytes, title: String? = nil) {
        self.id = id; self.verdict = verdict; self.reason = reason; self.bytes = bytes; self.title = title
    }
}

/// A kind of item `suggest` could not evaluate, and why (additive).
public struct SuggestSkip: Codable, Sendable, Hashable {
    /// "tab" | "session" | "leftover"
    public let kind: String
    public let reason: String
    public init(kind: String, reason: String) { self.kind = kind; self.reason = reason }
}

/// `headroom suggest --json`
public struct SuggestReport: Codable, Sendable {
    public let schema: Int
    public let generatedAt: Date
    /// "rules" | "claude"
    public let source: String
    public let suggestions: [Suggestion]
    /// Σ bytes of the "safe" suggestions.
    public let safeBytes: Bytes
    /// Ready-to-run command for the "safe" suggestions, e.g. "headroom close tab:812:1234 session:…".
    public let closeCommand: String?
    /// Ready-to-run command for the "confirm" suggestions: "headroom close --force-confirm …" (additive).
    public let confirmCommand: String?
    /// Prose from `--ask` (Claude's answer after the JSON), if any.
    public let notes: String?
    /// ChromeDataSource.name of the snapshot (additive).
    public var chromeSource: String? = nil
    /// Kinds that were not evaluated, e.g. tabs without per-tab memory or last-used times (additive).
    public var skipped: [SuggestSkip]? = nil
    public init(generatedAt: Date, source: String = "rules", suggestions: [Suggestion], notes: String? = nil,
                chromeSource: String? = nil, skipped: [SuggestSkip]? = nil) {
        self.chromeSource = chromeSource
        self.skipped = skipped
        self.schema = ListSnapshot.currentSchema
        self.generatedAt = generatedAt; self.source = source; self.suggestions = suggestions
        let safe = suggestions.filter { $0.verdict == .safe }
        self.safeBytes = safe.reduce(0) { $0 + $1.bytes }
        self.closeCommand = safe.isEmpty ? nil : "headroom close " + safe.map(\.id.stringValue).joined(separator: " ")
        let confirm = suggestions.filter { $0.verdict == .confirm }
        self.confirmCommand = confirm.isEmpty ? nil
            : "headroom close --force-confirm " + confirm.map(\.id.stringValue).joined(separator: " ")
        self.notes = notes
    }
}

public enum HeadroomJSON {
    /// Pretty, sorted keys, ISO-8601 dates: the stable CLI encoding.
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
