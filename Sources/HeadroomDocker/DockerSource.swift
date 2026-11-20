// DockerSource — the Docker part of a WorldSnapshot (SPEC §5.2). Read-only.
//
// A snapshot never waits for Docker. `snapshot(_:)` returns what the last read found and, once the app has set
// a cadence, starts the next read in the background when the last one is older than that cadence. The CLI, which
// takes one snapshot and exits, calls `refresh()` first and waits for it (bounded).
//
// Per read: /info and /containers/json, then one one-shot /stats per running container (8 at a time). Disk use
// (/system/df, tens of seconds) has its own slow cadence and is kept in <support>/docker-disk.json, so a fresh
// launch can show the last known numbers with their age.
//
// The VM's cost on this Mac is the footprint of the VM's own processes in the process table (vmPids).

import Foundation
import HeadroomContracts
import HeadroomCore

public final class DockerSource: @unchecked Sendable {
    public let env: HeadroomEnv
    private let environment: [String: String]
    private let lock = NSLock()
    private var cached = DockerSnapshot.empty
    private var endpoint: DockerEndpoint?
    private var lastStats: [String: DockerAPI.Stats] = [:]
    private var lastRead = Date.distantPast
    private var reading = false
    private var readingDisk = false
    private var lastDiskTry = Date.distantPast
    /// nil = no background reads (the CLI, tests). The app sets it with setCadence.
    private var cadence: TimeInterval?
    private var disk: DockerDisk?
    private var diskSocket: String?

    /// Timeout of one engine call during a read.
    public static let callTimeout: TimeInterval = 4
    /// Disk use is read again when it is older than this.
    public static let diskMaxAge: TimeInterval = 15 * 60
    public static let diskTimeout: TimeInterval = 180

    /// Test seam: the process that is responsible for a pid (see Responsibility).
    var responsible: @Sendable (Int32) -> Int32? = { Responsibility.pid(for: $0) }

    public init(env: HeadroomEnv = .current, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = env
        self.environment = environment
        if let saved = Self.loadDisk(path: Self.diskCachePath(env)) {
            disk = saved.disk
            diskSocket = saved.socketPath
        }
    }

    /// Containers every 5 s while the window is key, every 15 s while it is only visible.
    public func setCadence(windowKey: Bool) { lock.withLock { cadence = windowKey ? 5 : 15 } }

    // MARK: Snapshot

    /// The last read, with the VM's footprint taken from `table`. Never waits for Docker.
    public func snapshot(_ table: ProcessTable) -> DockerSnapshot {
        startBackgroundReadsIfDue()
        let (snap, ep) = lock.withLock { (cached, endpoint) }
        return Self.withVM(snap, endpoint: ep, table: table, responsible: responsible)
    }

    private func startBackgroundReadsIfDue() {
        let now = Date()
        let (containersDue, diskDue): (Bool, Bool) = lock.withLock {
            guard let cadence else { return (false, false) }
            let c = !reading && now.timeIntervalSince(lastRead) >= cadence
            if c { reading = true }
            let stale = disk.map { now.timeIntervalSince($0.at) > Self.diskMaxAge } ?? true
            // A failed disk read is not repeated for a minute.
            let d = cached.status == .running && stale && !readingDisk && now.timeIntervalSince(lastDiskTry) > 60
            if d { readingDisk = true; lastDiskTry = now }
            return (c, d)
        }
        if containersDue { Task.detached(priority: .utility) { await self.read() } }
        if diskDue { Task.detached(priority: .utility) { _ = await self.readDisk() } }
    }

    /// One read now (the CLI). Returns when it is done; a read already under way is waited for instead.
    public func refresh() async {
        let mine = lock.withLock { () -> Bool in
            if reading { return false }
            reading = true
            return true
        }
        if mine { await read(); return }
        let deadline = Date().addingTimeInterval(Self.callTimeout * 2)
        while lock.withLock({ reading }), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// Reads disk use now and waits for it (the CLI's `--disk`). nil = the engine did not answer in time.
    public func refreshDisk() async -> DockerDisk? {
        let mine = lock.withLock { () -> Bool in
            if readingDisk { return false }
            readingDisk = true
            lastDiskTry = Date()
            return true
        }
        guard mine else { return lock.withLock { disk } }
        return await readDisk()
    }

    // MARK: Reads

    /// Caller has set `reading`.
    private func read() async {
        let ep = DockerEndpoint.resolve(environment: environment, home: env.home)
        let previous = lock.withLock { lastStats }
        let (snap, stats) = await Self.load(endpoint: ep, previous: previous, timeout: Self.callTimeout)
        lock.withLock {
            var s = snap
            if let d = disk, diskSocket == ep?.socketPath { s.disk = d }
            cached = s
            endpoint = ep
            lastStats = stats
            lastRead = Date()
            reading = false
        }
    }

    /// Pure but for the socket: what one endpoint says right now.
    static func load(endpoint ep: DockerEndpoint?, previous: [String: DockerAPI.Stats],
                     timeout: TimeInterval) async -> (DockerSnapshot, [String: DockerAPI.Stats]) {
        guard let ep else { return (.empty, [:]) }
        var s = DockerSnapshot(status: .notRunning, runtime: ep.runtime.rawValue, socketPath: ep.socketPath)
        let sock = ep.socketPath
        guard DockerEndpoint.isSocket(sock) else { return (s, [:]) }
        async let infoReply = UnixHTTP.get(socket: sock, path: DockerAPI.infoPath, timeout: timeout)
        async let listReply = UnixHTTP.get(socket: sock, path: DockerAPI.containersPath, timeout: timeout)
        guard let l = await listReply, l.ok, var containers = DockerAPI.containers(l.body) else {
            _ = await infoReply
            return (s, [:])
        }
        s.status = .running
        s.at = Date()
        if let i = await infoReply, i.ok, let info = DockerAPI.info(i.body) {
            s.vmMemoryLimit = info.memTotal
            s.cpus = info.cpus
            s.stoppedCount = info.stopped
            s.imageCount = info.images
        }
        var stats: [String: DockerAPI.Stats] = [:]
        let ids = containers.filter { $0.state == "running" || $0.state == "paused" }.map(\.id)
        var next = 0
        await withTaskGroup(of: (String, DockerAPI.Stats?).self) { group in
            func add() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask {
                    let r = await UnixHTTP.get(socket: sock, path: DockerAPI.statsPath(id), timeout: timeout)
                    return (id, r.flatMap { $0.ok ? DockerAPI.stats($0.body) : nil })
                }
            }
            for _ in 0..<8 { add() }
            for await (id, st) in group {
                if let st { stats[id] = st }
                add()
            }
        }
        for i in containers.indices {
            guard let st = stats[containers[i].id] else { continue }
            containers[i].memory = st.memory
            // A container without its own limit reports the VM's memory; that is not a limit worth showing.
            containers[i].memoryLimit = st.memoryLimit.flatMap { $0 == s.vmMemoryLimit ? nil : $0 }
            containers[i].pids = st.pids
            if let p = previous[containers[i].id] {
                containers[i].cpuPercent = DockerAPI.cpuPercent(previous: p, current: st)
            }
        }
        s.containers = containers
        return (s, stats)
    }

    /// Caller has set `readingDisk`. The four parts are read at the same time; a part that fails fails the read.
    private func readDisk() async -> DockerDisk? {
        let ep = DockerEndpoint.resolve(environment: environment, home: env.home)
        var result: DockerDisk?
        if let sock = ep?.socketPath, DockerEndpoint.isSocket(sock) {
            var parts: [DockerAPI.DiskType: DockerDiskStat] = [:]
            await withTaskGroup(of: (DockerAPI.DiskType, DockerDiskStat?).self) { group in
                for t in DockerAPI.DiskType.allCases {
                    group.addTask {
                        let r = await UnixHTTP.get(socket: sock, path: t.path, timeout: Self.diskTimeout)
                        return (t, r.flatMap { $0.ok ? DockerAPI.diskStat($0.body, t) : nil })
                    }
                }
                for await (t, stat) in group { parts[t] = stat }
            }
            if let i = parts[.image], let c = parts[.container], let v = parts[.volume], let b = parts[.buildCache] {
                let d = DockerDisk(images: i, containers: c, volumes: v, buildCache: b, at: Date())
                result = d
                Self.saveDisk(SavedDisk(socketPath: sock, disk: d), path: Self.diskCachePath(env))
            }
        }
        lock.withLock {
            if let result {
                disk = result
                diskSocket = ep?.socketPath
                if cached.socketPath == ep?.socketPath { cached.disk = result }
            }
            readingDisk = false
        }
        return result
    }

    // MARK: Disk cache file

    struct SavedDisk: Codable { let socketPath: String; let disk: DockerDisk }

    static func diskCachePath(_ env: HeadroomEnv) -> String { env.supportDir + "/docker-disk.json" }

    static func loadDisk(path: String) -> SavedDisk? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? HeadroomJSON.decoder().decode(SavedDisk.self, from: d)
    }

    static func saveDisk(_ s: SavedDisk, path: String) {
        guard let d = try? HeadroomJSON.encoder().encode(s) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    // MARK: The VM on this Mac

    static let vzBasename = "com.apple.Virtualization.VirtualMachine"

    /// Fills vmPids and vmFootprint from the process table.
    static func withVM(_ snap: DockerSnapshot, endpoint: DockerEndpoint?, table: ProcessTable,
                       responsible: (Int32) -> Int32?) -> DockerSnapshot {
        guard snap.status == .running, let endpoint else { return snap }
        var s = snap
        let hostAgent = endpoint.limaInstanceDir.flatMap { readPid($0 + "/ha.pid") }
        let pids = vmPids(table, runtime: endpoint.runtime, hostAgentPid: hostAgent, responsible: responsible)
        s.vmPids = pids
        s.vmFootprint = pids.isEmpty ? nil : pids.reduce(Bytes(0)) { $0 + (table.byPid[$1]?.footprint ?? 0) }
        return s
    }

    static func readPid(_ path: String) -> Int32? {
        guard let d = FileManager.default.contents(atPath: path), let s = String(data: d, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The processes that hold the Docker VM's memory. [] when they cannot be told apart from other VMs.
    ///
    /// - colima / lima: the VM is a Virtualization.framework XPC service (or a qemu child of the host agent). The
    ///   XPC service is a child of launchd, so it is tied to the host agent by the process responsible for both and
    ///   by its start time (it starts just after the host agent). Without that, a lone VM process is taken.
    /// - Docker Desktop, OrbStack: their own VM processes inside the app bundle, plus XPC VMs they are responsible for.
    public static func vmPids(_ table: ProcessTable, runtime: DockerEndpoint.Runtime, hostAgentPid: Int32?,
                              responsible: (Int32) -> Int32?) -> [Int32] {
        func base(_ p: ProcSample) -> String { (p.path as NSString).lastPathComponent }
        let vz = table.byPid.values.filter { base($0) == vzBasename }
        func ownedBy(_ marker: String) -> [ProcSample] {
            vz.filter { v in
                guard let r = responsible(v.pid), let owner = table.byPid[r] else { return false }
                return owner.path.contains(marker)
            }
        }
        var out: [ProcSample] = []
        switch runtime {
        case .colima, .lima, .rancher:
            if let ha = hostAgentPid.flatMap({ table.byPid[$0] }) {
                out += (table.children[ha.pid] ?? []).compactMap { table.byPid[$0] }
                    .filter { base($0).hasPrefix("qemu-system") }
                if let owner = responsible(ha.pid) {
                    let mine = vz.filter { responsible($0.pid) == owner && $0.key.startSec >= ha.key.startSec - 2 }
                    if let v = mine.min(by: { $0.key.startSec < $1.key.startSec }) { out.append(v) }
                }
            }
            if out.isEmpty, runtime != .rancher, vz.count == 1 { out = vz }
        case .dockerDesktop:
            out = table.byPid.values.filter {
                $0.path.contains("/Docker.app/")
                    && ["com.docker.virtualization", "com.docker.hyperkit", "qemu-system-aarch64"].contains(base($0))
            } + ownedBy("/Docker.app/")
        case .orbstack:
            out = table.byPid.values.filter { $0.path.contains("/OrbStack.app/") && base($0) == "OrbStack Helper" }
                + ownedBy("/OrbStack.app/")
        case .podman, .docker:
            out = []
        }
        return Array(Set(out.map(\.pid))).sorted()
    }
}

/// The process macOS holds responsible for another (the app or terminal that started it, even through launchd).
/// `responsibility_get_pid_responsible_for_pid` is not in the SDK headers, so it is looked up at run time; when it
/// is missing the answer is nil and callers fall back.
enum Responsibility {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func pid(for p: Int32) -> Int32? {
        guard let fn else { return nil }
        let r = fn(p)
        return r > 0 ? r : nil
    }
}
