// Parsers for the Docker Engine API replies Headroom reads (pure; unit tested on captured replies).
//
//   GET /info                                      VM memory, CPUs, container and image counts
//   GET /containers/json                           running containers
//   GET /containers/<id>/stats?stream=false&one-shot=true    one memory + CPU sample, no 1 s wait
//   GET /system/df?type=image|container|volume|build-cache   disk use (slow)

import Foundation
import HeadroomContracts

public enum DockerAPI {
    public static let infoPath = "/info"
    public static let containersPath = "/containers/json"
    public static func statsPath(_ id: String) -> String { "/containers/\(id)/stats?stream=false&one-shot=true" }

    public enum DiskType: String, Sendable, CaseIterable {
        case image, container, volume, buildCache = "build-cache"
        public var path: String { "/system/df?type=\(rawValue)" }
    }

    public struct Info: Sendable, Hashable {
        public var memTotal: Bytes?
        public var cpus: Int?
        public var running = 0, stopped = 0, paused = 0, images = 0
        public var name = ""
    }

    /// One stats sample. CPU% needs two of them (see cpuPercent).
    public struct Stats: Sendable, Hashable {
        public var memory: Bytes
        public var memoryLimit: Bytes?
        /// Container CPU time and host CPU time, in nanoseconds, at the moment of the sample.
        public var cpuTotalNs: UInt64
        public var systemNs: UInt64?
        public var onlineCPUs: Int?
        public var pids: Int?
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func u64(_ v: Any?) -> UInt64? {
        guard let n = v as? NSNumber else { return nil }
        return n.int64Value < 0 ? 0 : n.uint64Value
    }
    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    public static func info(_ data: Data) -> Info? {
        guard let o = object(data) else { return nil }
        var i = Info()
        i.memTotal = u64(o["MemTotal"]).flatMap { $0 > 0 ? $0 : nil }
        i.cpus = int(o["NCPU"])
        i.running = int(o["ContainersRunning"]) ?? 0
        i.stopped = int(o["ContainersStopped"]) ?? 0
        i.paused = int(o["ContainersPaused"]) ?? 0
        i.images = int(o["Images"]) ?? 0
        i.name = o["Name"] as? String ?? ""
        return i
    }

    /// The reply of `/containers/json`. nil when it is not a JSON array (an error body).
    public static func containers(_ data: Data) -> [DockerContainer]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return list.compactMap { o in
            guard let id = o["Id"] as? String, !id.isEmpty else { return nil }
            let names = (o["Names"] as? [String] ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
            let labels = o["Labels"] as? [String: String] ?? [:]
            func label(_ k: String) -> String? { labels[k].flatMap { $0.isEmpty ? nil : $0 } }
            return DockerContainer(
                id: id, name: names.first ?? String(id.prefix(12)), image: o["Image"] as? String ?? "",
                state: o["State"] as? String ?? "", status: o["Status"] as? String ?? "",
                project: label("com.docker.compose.project"), service: label("com.docker.compose.service"),
                createdAt: (o["Created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
    }

    /// Memory as `docker stats` shows it: usage minus inactive file cache (cgroup v2 `inactive_file`,
    /// cgroup v1 `total_inactive_file`).
    public static func stats(_ data: Data) -> Stats? {
        guard let o = object(data), let mem = o["memory_stats"] as? [String: Any],
              let usage = u64(mem["usage"]) else { return nil }
        let detail = mem["stats"] as? [String: Any] ?? [:]
        let inactive = u64(detail["inactive_file"]) ?? u64(detail["total_inactive_file"]) ?? 0
        let cpu = o["cpu_stats"] as? [String: Any] ?? [:]
        let usageCPU = cpu["cpu_usage"] as? [String: Any] ?? [:]
        return Stats(memory: usage > inactive ? usage - inactive : usage,
                     memoryLimit: u64(mem["limit"]).flatMap { $0 > 0 ? $0 : nil },
                     cpuTotalNs: u64(usageCPU["total_usage"]) ?? 0, systemNs: u64(cpu["system_cpu_usage"]),
                     onlineCPUs: int(cpu["online_cpus"]),
                     pids: int((o["pids_stats"] as? [String: Any])?["current"]))
    }

    /// Docker's own formula: the container's share of host CPU time between two samples × CPUs × 100.
    public static func cpuPercent(previous p: Stats, current c: Stats) -> Double? {
        guard let s0 = p.systemNs, let s1 = c.systemNs, s1 > s0, c.cpuTotalNs >= p.cpuTotalNs else { return nil }
        let cpus = Double(c.onlineCPUs ?? 1)
        return Double(c.cpuTotalNs - p.cpuTotalNs) / Double(s1 - s0) * cpus * 100
    }

    /// One part of `/system/df`. Engines with API 1.52+ send a summary (`ImageUsage` …); older ones only the
    /// item lists, which are summed here the way `docker system df` sums them.
    public static func diskStat(_ data: Data, _ type: DiskType) -> DockerDiskStat? {
        guard let o = object(data) else { return nil }
        let summaryKey: String, listKey: String
        switch type {
        case .image: (summaryKey, listKey) = ("ImageUsage", "Images")
        case .container: (summaryKey, listKey) = ("ContainerUsage", "Containers")
        case .volume: (summaryKey, listKey) = ("VolumeUsage", "Volumes")
        case .buildCache: (summaryKey, listKey) = ("BuildCacheUsage", "BuildCache")
        }
        if let s = o[summaryKey] as? [String: Any], let size = u64(s["TotalSize"]) {
            return DockerDiskStat(count: int(s["TotalCount"]) ?? 0, size: size,
                                  reclaimable: min(u64(s["Reclaimable"]) ?? 0, size))
        }
        guard let items = o[listKey] as? [[String: Any]] else { return nil }
        var size: UInt64 = 0, inUse: UInt64 = 0
        switch type {
        case .image:
            size = u64(o["LayersSize"]) ?? 0
            for i in items where (int(i["Containers"]) ?? 0) > 0 {
                let s = u64(i["Size"]) ?? 0, shared = u64(i["SharedSize"]) ?? 0
                inUse += s > shared ? s - shared : 0
            }
        case .container:
            for c in items {
                let s = u64(c["SizeRw"]) ?? 0
                size += s
                if ["running", "paused", "restarting"].contains(c["State"] as? String ?? "") { inUse += s }
            }
        case .volume:
            for v in items {
                let u = v["UsageData"] as? [String: Any] ?? [:]
                let s = u64(u["Size"]) ?? 0
                size += s
                if (int(u["RefCount"]) ?? 0) > 0 { inUse += s }
            }
        case .buildCache:
            for b in items where b["Shared"] as? Bool != true {
                let s = u64(b["Size"]) ?? 0
                size += s
                if b["InUse"] as? Bool == true { inUse += s }
            }
        }
        return DockerDiskStat(count: items.count, size: size, reclaimable: size > inUse ? size - inUse : 0)
    }
}
