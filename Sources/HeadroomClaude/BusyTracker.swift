// SPEC §5 "Busy (combined evidence, because the JSON status alone is unreliable)".
//
// A session is busy if ANY of these hold:
//   1. status: the JSON `status` is not "idle" (a missing or unknown status counts as busy for registered sessions);
//   2. caffeinate: a `caffeinate` process is among its children (Claude Code holds one while it works);
//   3. cpu: claude plus its children averaged more than 5% CPU (of one core) over the last 3 samples;
//   4. transcript: a user/assistant entry was written after the status last changed, within the last 30 s
//      (per-line "timestamp", never the file mtime) — the JSON says idle but the transcript is still moving;
//   5. child: a child process started within the last 15 s (a tool is running right now).
// Busy age: now − statusUpdatedAt when the JSON itself says busy, else now − the first busy observation.

import Foundation
import HeadroomContracts

public struct BusyEvidence: Sendable, Hashable, Codable {
    public var status = false
    public var caffeinate = false
    public var cpu = false
    public var transcript = false
    public var child = false
    public init() {}
    public var busy: Bool { status || caffeinate || cpu || transcript || child }
    /// "status,cpu" — for the selftest and debugging.
    public var summary: String {
        var p: [String] = []
        if status { p.append("status") }; if caffeinate { p.append("caffeinate") }; if cpu { p.append("cpu") }
        if transcript { p.append("transcript") }; if child { p.append("child") }
        return p.isEmpty ? "-" : p.joined(separator: ",")
    }
}

public final class BusyTracker: @unchecked Sendable {
    public static let cpuThreshold = 5.0
    public static let samples = 3
    public static let transcriptWindow: TimeInterval = 30
    public static let childWindow: TimeInterval = 15
    /// Transcript entries this long after statusUpdatedAt show the JSON status is behind.
    public static let statusSlack: TimeInterval = 3

    private let lock = NSLock()
    /// The previous `samples − 1` CPU samples (oldest first): time + cpuNs per tracked process.
    private var history: [(at: Date, cpu: [ProcKey: UInt64])] = []
    private var firstBusy: [ProcKey: Date] = [:]

    public init() {}

    public var hasHistory: Bool { lock.lock(); defer { lock.unlock() }; return !history.isEmpty }

    /// Adds a sample of the tracked processes (call once per snapshot, after evaluating).
    public func record(_ t: ProcessTable, keys: some Sequence<ProcKey>) {
        var m: [ProcKey: UInt64] = [:]
        for k in keys { if let s = t.byPid[k.pid], s.key == k { m[k] = s.cpuNs } }
        lock.lock(); defer { lock.unlock() }
        if let last = history.last, last.at >= t.takenAt { return }
        history.append((t.takenAt, m))
        if history.count > Self.samples - 1 { history.removeFirst(history.count - (Self.samples - 1)) }
    }

    /// Average CPU% (100 = one core) of `members` from the oldest kept sample to `t`. nil without history.
    public func cpuPercent(members: [ProcKey], in t: ProcessTable) -> Double? {
        lock.lock()
        let base = history.first
        lock.unlock()
        guard let base else { return nil }
        let dt = t.takenAt.timeIntervalSince(base.at)
        guard dt > 0.05 else { return nil }
        let baseSec = Int(base.at.timeIntervalSince1970)
        var delta: UInt64 = 0
        for k in members {
            guard let s = t.byPid[k.pid], s.key == k else { continue }
            if let b = base.cpu[k] {
                delta &+= s.cpuNs >= b ? s.cpuNs - b : 0
            } else if k.startSec >= baseSec {
                delta &+= s.cpuNs              // started inside the window: all its CPU is recent
            }
        }
        return Double(delta) / (dt * 1e9) * 100
    }

    /// Combines the evidence. `status` nil = no JSON status (unregistered claude: judged on the other evidence only).
    public func evaluate(key: ProcKey, status: String?, registered: Bool, statusUpdatedAt: Date?,
                         lastActivity: Date?, cpuPercent: Double?, childPaths: [String], childStarts: [Int],
                         now: Date) -> (evidence: BusyEvidence, since: Date?) {
        var e = BusyEvidence()
        if registered {
            let s = (status ?? "").lowercased()
            e.status = s != "idle"
        }
        e.caffeinate = childPaths.contains { ($0 as NSString).lastPathComponent == "caffeinate" }
        e.cpu = (cpuPercent ?? 0) > Self.cpuThreshold
        if let la = lastActivity, now.timeIntervalSince(la) < Self.transcriptWindow {
            if let su = statusUpdatedAt { e.transcript = la.timeIntervalSince(su) > Self.statusSlack }
            else { e.transcript = true }
        }
        let nowSec = Int(now.timeIntervalSince1970)
        e.child = childStarts.contains { nowSec - $0 < Int(Self.childWindow) && nowSec >= $0 }

        lock.lock(); defer { lock.unlock() }
        guard e.busy else { firstBusy[key] = nil; return (e, statusUpdatedAt) }
        if e.status, let su = statusUpdatedAt { firstBusy[key] = nil; return (e, su) }
        let first = firstBusy[key] ?? now
        firstBusy[key] = first
        return (e, first)
    }

    /// Forgets sessions that are gone.
    public func prune(keeping keys: Set<ProcKey>) {
        lock.lock(); defer { lock.unlock() }
        firstBusy = firstBusy.filter { keys.contains($0.key) }
    }
}
