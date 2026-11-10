// Journal (actions.jsonl) and RecentlyClosed (closed.jsonl + restored.jsonl), under env.supportDir.
// Shared by the App and the CLI, so CLI closes show up in the app's ⌘Y and vice versa.
//
//   actions.jsonl   one line per signal, tab close, discard, restore: {ts, kind, pid, startSec, pgid, signal,
//                   reason, result, itemId, target, dryRun, source}. Append-only audit log.
//   closed.jsonl    one ClosedRecord per closed item. Incognito URLs are never written. Pruned after 7 days.
//   restored.jsonl  {id, ts} per record that Undo restored (so Recently Closed hides it). Pruned with closed.
//
// Writes are single O_APPEND write(2) calls under flock(2), so the App and the CLI can append concurrently.
// In dry run nothing is written to closed.jsonl: records stay in memory for this process only, so a dry
// run never leaves fake closes in Recently Closed. actions.jsonl is always written (dryRun: true).

import Darwin
import Foundation
import HeadroomContracts

public struct ActionLogEntry: Codable, Sendable, Hashable {
    public var ts: Date
    /// "signal" | "closeTab" | "discard" | "restore" | "intent"
    public var kind: String
    public var pid: Int32?
    public var startSec: Int?
    public var pgid: Int32?
    public var signal: Int32?
    public var reason: String
    /// "sent" | "gone" | "mismatch" | "refused: …" | "dryRun" | "failed: …" | Outcome names
    public var result: String
    public var itemId: String?
    public var target: String?
    public var dryRun: Bool
    public var source: String
    public init(ts: Date = Date(), kind: String, pid: Int32? = nil, startSec: Int? = nil, pgid: Int32? = nil,
                signal: Int32? = nil, reason: String, result: String, itemId: String? = nil, target: String? = nil,
                dryRun: Bool, source: String = "app") {
        self.ts = ts; self.kind = kind; self.pid = pid; self.startSec = startSec; self.pgid = pgid
        self.signal = signal; self.reason = reason; self.result = result; self.itemId = itemId
        self.target = target; self.dryRun = dryRun; self.source = source
    }

    static func signal(target: SignalTarget, signal: Int32, itemId: ItemID?, reason: String, result: SignalResult,
                       dryRun: Bool, table: ProcessTable) -> ActionLogEntry {
        var e = ActionLogEntry(kind: "signal", signal: signal, reason: reason, result: result.logString,
                               itemId: itemId?.stringValue, target: target.description, dryRun: dryRun)
        switch target {
        case .session(let k), .automationBrowser(let k):
            e.pid = k.pid; e.startSec = k.startSec; e.pgid = table.byPid[k.pid]?.pgid
        case let .group(g, m, _):
            e.pgid = g; e.pid = m.first?.pid; e.startSec = m.first?.startSec
        }
        return e
    }
}

extension SignalResult {
    public var logString: String {
        switch self {
        case .sent: "sent"; case .gone: "gone"; case .mismatch: "mismatch"; case .dryRun: "dryRun"
        case .refused(let r): "refused: \(r)"; case .failed(let e): "failed: errno \(e)"
        }
    }
}

extension Outcome {
    public var name: String {
        switch self {
        case .done: "done"; case .alreadyGone: "alreadyGone"; case .changedSkipped: "changedSkipped"
        case .stayedOpen: "stayedOpen"; case .stillAlive: "stillAlive"; case .dryRun: "dryRun"
        case .failed(let s): "failed: \(s)"
        }
    }
    /// The item is (or, in dry run, would be) closed.
    public var isClosed: Bool { self == .done || self == .dryRun || self == .alreadyGone }
}

/// Append-only JSON-lines file with flock.
enum JSONLines {
    static func ensureDir(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    static func append(_ lines: [Data], to path: String) {
        guard !lines.isEmpty else { return }
        ensureDir((path as NSString).deletingLastPathComponent)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        flock(fd, LOCK_EX); defer { flock(fd, LOCK_UN) }
        var buf = Data()
        for l in lines { buf.append(l); buf.append(0x0A) }
        _ = buf.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    static func read(_ path: String) -> [Data] {
        guard let d = FileManager.default.contents(atPath: path) else { return [] }
        return d.split(separator: 0x0A).filter { !$0.isEmpty }.map { Data($0) }
    }

    /// Rewrites `path` keeping only lines for which `keep` returns true (under flock, atomic rename).
    static func rewrite(_ path: String, keep: (Data) -> Bool) {
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        flock(fd, LOCK_EX); defer { flock(fd, LOCK_UN) }
        let lines = read(path)
        let kept = lines.filter(keep)
        guard kept.count != lines.count else { return }
        var buf = Data()
        for l in kept { buf.append(l); buf.append(0x0A) }
        let tmp = path + ".tmp-\(getpid())"
        guard FileManager.default.createFile(atPath: tmp, contents: buf, attributes: [.posixPermissions: 0o600]) else { return }
        _ = rename(tmp, path)
    }
}

public final class Journal: @unchecked Sendable {
    public let path: String
    public let source: String
    private let encoder = HeadroomJSON.encoder(pretty: false)

    public init(env: HeadroomEnv, source: String = "app") {
        self.path = env.actionsLog; self.source = source
    }

    public func log(_ entries: ActionLogEntry...) { log(entries) }

    public func log(_ entries: [ActionLogEntry]) {
        let lines = entries.compactMap { e -> Data? in
            var e = e; e.source = source
            return try? encoder.encode(e)
        }
        JSONLines.append(lines, to: path)
    }

    /// All entries (for tests and `--selftest`).
    public func entries() -> [ActionLogEntry] {
        let d = HeadroomJSON.decoder()
        return JSONLines.read(path).compactMap { try? d.decode(ActionLogEntry.self, from: $0) }
    }
}

public final class RecentlyClosed: @unchecked Sendable {
    public static let maxAge: TimeInterval = 7 * 86_400
    public let closedPath: String
    public let restoredPath: String
    public let persist: Bool
    /// Also read closed.jsonl when not persisting (dry run, not mock), so a dry-run `undo --list` and the app's
    /// Recently Closed still show real closes. Nothing is ever written in that mode.
    public let readsDisk: Bool
    private let lock = NSLock()
    private var memory: [ClosedRecord] = []
    private var memoryRestored: Set<String> = []
    private let encoder = HeadroomJSON.encoder(pretty: false)

    /// `persist` = false (dry run, mock) keeps new records in memory only. In dry run (but not mock) the
    /// records already on disk are still read and merged, read-only.
    public init(env: HeadroomEnv, persist: Bool? = nil, readsDisk: Bool? = nil) {
        closedPath = env.closedLog
        restoredPath = env.supportDir + "/restored.jsonl"
        let p = persist ?? !env.dryRun
        self.persist = p
        self.readsDisk = p || (readsDisk ?? !env.mock)
    }

    public func add(_ records: [ClosedRecord]) {
        let clean = records.map { r -> ClosedRecord in
            var r = r
            if r.incognito == true { r.url = nil }     // incognito URLs are never written
            return r
        }
        if persist {
            JSONLines.append(clean.compactMap { try? encoder.encode($0) }, to: closedPath)
        } else {
            lock.lock(); memory.insert(contentsOf: clean, at: 0); lock.unlock()
        }
    }

    public func markRestored(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        if persist {
            struct R: Codable { let id: String; let ts: Date }
            JSONLines.append(ids.compactMap { try? encoder.encode(R(id: $0, ts: Date())) }, to: restoredPath)
        } else {
            lock.lock(); memoryRestored.formUnion(ids); lock.unlock()
        }
    }

    /// Newest first, last 7 days, restored records removed.
    public func list(now: Date = Date()) -> [ClosedRecord] {
        let cutoff = now.addingTimeInterval(-Self.maxAge)
        var all: [ClosedRecord] = []
        var restored: Set<String> = []
        if readsDisk {
            let d = HeadroomJSON.decoder()
            all = JSONLines.read(closedPath).compactMap { try? d.decode(ClosedRecord.self, from: $0) }
            struct R: Codable { let id: String }
            restored = Set(JSONLines.read(restoredPath).compactMap { try? d.decode(R.self, from: $0).id })
        }
        if !persist {
            lock.lock(); all = memory + all; restored.formUnion(memoryRestored); lock.unlock()
        }
        return all.filter { $0.closedAt >= cutoff && !restored.contains($0.id) }
            .sorted { ($0.closedAt, $0.id) > ($1.closedAt, $1.id) }
    }

    public func record(id: String) -> ClosedRecord? { list().first { $0.id == id } }

    /// Ids of records already restored (restored.jsonl plus this process's in-memory restores).
    public func restoredIds() -> Set<String> {
        var restored: Set<String> = []
        if readsDisk {
            let d = HeadroomJSON.decoder()
            struct R: Codable { let id: String }
            restored = Set(JSONLines.read(restoredPath).compactMap { try? d.decode(R.self, from: $0).id })
        }
        if !persist { lock.lock(); restored.formUnion(memoryRestored); lock.unlock() }
        return restored
    }

    /// The newest batch that still has something restorable.
    public func lastBatch(now: Date = Date()) -> [ClosedRecord] {
        let l = list(now: now)
        guard let b = l.first(where: \.restorable)?.batchId else { return [] }
        return l.filter { $0.batchId == b }
    }

    /// Drops closed.jsonl lines older than 7 days (and restored.jsonl lines older than 7 days).
    public func prune(now: Date = Date()) {
        guard persist else { return }
        let cutoff = now.addingTimeInterval(-Self.maxAge)
        let d = HeadroomJSON.decoder()
        struct Stamp: Codable { let closedAt: Date? ; let ts: Date? }
        let keep: (Data) -> Bool = { line in
            guard let s = try? d.decode(Stamp.self, from: line), let t = s.closedAt ?? s.ts else { return false }
            return t >= cutoff
        }
        JSONLines.rewrite(closedPath, keep: keep)
        JSONLines.rewrite(restoredPath, keep: keep)
    }
}
