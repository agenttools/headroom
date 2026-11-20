// Docker (SPEC §5.2): read-only insight. Running containers and their memory inside the Docker VM, what the VM
// itself holds on this Mac, and disk use (images, volumes, build cache, container layers).
//
// Headroom never stops, starts or removes anything in Docker. These rows have no ItemID: they cannot be selected,
// closed or undone.

import Foundation

/// One running container (`GET /containers/json` + one-shot `GET /containers/<id>/stats`).
public struct DockerContainer: Sendable, Hashable, Codable, Identifiable {
    /// The full 64-hex container id.
    public let id: String
    public let name: String
    public let image: String
    /// "running", "paused", "restarting"…
    public let state: String
    /// Docker's own text: "Up 3 hours (healthy)".
    public let status: String
    /// Compose project and service (labels `com.docker.compose.project` / `.service`), if any.
    public let project: String?
    public let service: String?
    public let createdAt: Date?
    /// Memory in use inside the VM: cgroup usage minus inactive file cache (the number `docker stats` shows).
    /// nil until the first stats read.
    public var memory: Bytes?
    public var memoryLimit: Bytes?
    /// Percent of one CPU (400 = four cores busy). nil until two samples exist.
    public var cpuPercent: Double?
    public var pids: Int?

    public init(id: String, name: String, image: String, state: String = "running", status: String = "",
                project: String? = nil, service: String? = nil, createdAt: Date? = nil, memory: Bytes? = nil,
                memoryLimit: Bytes? = nil, cpuPercent: Double? = nil, pids: Int? = nil) {
        self.id = id; self.name = name; self.image = image; self.state = state; self.status = status
        self.project = project; self.service = service; self.createdAt = createdAt; self.memory = memory
        self.memoryLimit = memoryLimit; self.cpuPercent = cpuPercent; self.pids = pids
    }

    public var shortId: String { String(id.prefix(12)) }
    /// The service name when the container belongs to a compose project, else the container name.
    public var displayName: String { project != nil ? (service ?? name) : name }
}

/// One line of `docker system df`.
public struct DockerDiskStat: Sendable, Hashable, Codable {
    public let count: Int
    public let size: Bytes
    /// What `docker … prune` could free.
    public let reclaimable: Bytes
    public init(count: Int = 0, size: Bytes = 0, reclaimable: Bytes = 0) {
        self.count = count; self.size = size; self.reclaimable = reclaimable
    }
}

/// `GET /system/df`. Slow (tens of seconds on a big store), so it is read in the background, kept on disk
/// (`<support>/docker-disk.json`) and shown with its age.
public struct DockerDisk: Sendable, Hashable, Codable {
    public let images, containers, volumes, buildCache: DockerDiskStat
    public let at: Date
    public init(images: DockerDiskStat, containers: DockerDiskStat, volumes: DockerDiskStat,
                buildCache: DockerDiskStat, at: Date) {
        self.images = images; self.containers = containers; self.volumes = volumes
        self.buildCache = buildCache; self.at = at
    }
    public var total: Bytes { images.size + containers.size + volumes.size + buildCache.size }
    public var reclaimable: Bytes {
        images.reclaimable + containers.reclaimable + volumes.reclaimable + buildCache.reclaimable
    }
}

public enum DockerStatus: String, Sendable, Codable {
    /// No Docker socket on this Mac (Docker is not installed, or its runtime never ran).
    case notFound
    /// A socket path is known but the engine does not answer (the VM is stopped).
    case notRunning
    case running
}

public struct DockerSnapshot: Sendable, Hashable, Codable {
    public var status: DockerStatus
    /// "colima", "Docker Desktop", "OrbStack"… ("" when notFound).
    public var runtime: String
    public var socketPath: String?
    /// Running containers only. Stopped ones use no memory; they are counted in `stoppedCount`.
    public var containers: [DockerContainer]
    public var stoppedCount: Int
    public var imageCount: Int
    /// The VM's processes on this Mac and their footprint (Activity Monitor "Memory"). nil = not identified.
    public var vmPids: [Int32]
    public var vmFootprint: Bytes?
    /// Memory the VM may use (`docker info` MemTotal), and its CPUs.
    public var vmMemoryLimit: Bytes?
    public var cpus: Int?
    public var disk: DockerDisk?
    /// When the container list was read. nil = never.
    public var at: Date?

    public init(status: DockerStatus = .notFound, runtime: String = "", socketPath: String? = nil,
                containers: [DockerContainer] = [], stoppedCount: Int = 0, imageCount: Int = 0,
                vmPids: [Int32] = [], vmFootprint: Bytes? = nil, vmMemoryLimit: Bytes? = nil, cpus: Int? = nil,
                disk: DockerDisk? = nil, at: Date? = nil) {
        self.status = status; self.runtime = runtime; self.socketPath = socketPath; self.containers = containers
        self.stoppedCount = stoppedCount; self.imageCount = imageCount; self.vmPids = vmPids
        self.vmFootprint = vmFootprint; self.vmMemoryLimit = vmMemoryLimit; self.cpus = cpus
        self.disk = disk; self.at = at
    }

    public static let empty = DockerSnapshot()

    /// Σ container memory (inside the VM). The VM's footprint on the Mac is `vmFootprint`; the two differ: the
    /// VM also holds its kernel and file cache, and it does not always give memory back when containers stop.
    public var containersMemory: Bytes { containers.reduce(0) { $0 + ($1.memory ?? 0) } }

    /// What Docker costs on this Mac right now: the VM when it is known, else the containers' sum.
    public var macBytes: Bytes? {
        guard status == .running else { return nil }
        return vmFootprint ?? (containers.isEmpty ? nil : containersMemory)
    }

    public struct Project: Sendable, Hashable {
        /// nil = containers started without compose.
        public let name: String?
        public let containers: [DockerContainer]
        public var memory: Bytes { containers.reduce(0) { $0 + ($1.memory ?? 0) } }
    }

    /// Containers grouped by compose project, largest first; containers without a project come last as one group.
    public var projects: [Project] {
        var by: [String: [DockerContainer]] = [:]
        var loose: [DockerContainer] = []
        for c in containers {
            if let p = c.project, !p.isEmpty { by[p, default: []].append(c) } else { loose.append(c) }
        }
        var out = by.map { Project(name: $0.key, containers: $0.value) }
            .sorted { ($0.memory, $1.name ?? "") > ($1.memory, $0.name ?? "") }
        if !loose.isEmpty { out.append(Project(name: nil, containers: loose)) }
        return out
    }
}
