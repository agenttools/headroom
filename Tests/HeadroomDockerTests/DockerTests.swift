// Docker: the Engine API parsers on hand-written replies, endpoint discovery in a scratch HOME, the VM process
// rules on a static process table, and DockerSource against a fake engine (a unix socket this test serves itself).
// Nothing here talks to a real Docker engine.
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomDocker

/// A short scratch directory (sun_path is limited to 104 bytes), removed by `cleanup()`.
struct ShortDir {
    let path: String
    init(_ tag: String = "hrd") {
        var t = Array("\(NSTemporaryDirectory())\(tag)-XXXXXX".utf8CString)
        let made = mkdtemp(&t).map { String(cString: $0) } ?? ""
        // /var/folders/… is long; prefer its /private/tmp twin when the result would not fit a socket path.
        if made.utf8.count > 60 {
            try? FileManager.default.removeItem(atPath: made)
            var s = Array("/private/tmp/\(tag)-XXXXXX".utf8CString)
            path = String(cString: mkdtemp(&s))
        } else {
            path = made
        }
    }
    func cleanup() { try? FileManager.default.removeItem(atPath: path) }
}

/// A fake Docker engine: answers GETs on a unix socket from a table of path → (status, body).
final class FakeEngine: @unchecked Sendable {
    let socketPath: String
    private let fd: Int32
    private let lock = NSLock()
    private var routes: [String: (Int, String)] = [:]
    private var seen: [String] = []
    private var stopped = false

    init(socketPath: String) {
        self.socketPath = socketPath
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path), "socket path too long: \(socketPath)")
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(rc == 0, "bind failed: \(errno)")
        listen(fd, 32)
        Thread.detachNewThread { [self] in serve() }
    }

    func respond(_ path: String, _ body: String, status: Int = 200) { lock.withLock { routes[path] = (status, body) } }
    var requests: [String] { lock.withLock { seen } }

    func stop() {
        lock.withLock { stopped = true }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(socketPath)
    }

    private func serve() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { if lock.withLock({ stopped }) { return } else { continue } }
            var buf = [UInt8](repeating: 0, count: 8192)
            var req = Data()
            while req.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                req.append(contentsOf: buf[..<n])
            }
            let line = String(data: req, encoding: .utf8)?.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : ""
            let (status, body) = lock.withLock { () -> (Int, String) in
                seen.append(path)
                return routes[path] ?? (404, "{\"message\":\"page not found\"}")
            }
            let reply = Array("HTTP/1.0 \(status) X\r\nContent-Type: application/json\r\n\r\n\(body)".utf8)
            _ = reply.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
            close(c)
        }
    }
}

enum Replies {
    static let info = """
    {"Name":"colima","MemTotal":12515225600,"NCPU":4,"Containers":7,"ContainersRunning":3,"ContainersStopped":4,
     "ContainersPaused":0,"Images":41,"ServerVersion":"29.5.2"}
    """
    static let idA = String(repeating: "a", count: 64)
    static let idB = String(repeating: "b", count: 64)
    static let idC = String(repeating: "c", count: 64)
    static let containers = """
    [{"Id":"\(idA)","Names":["/shop-backend-1"],"Image":"shop-backend:dev","State":"running","Status":"Up 3 hours",
      "Created":1790000000,"Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"backend"}},
     {"Id":"\(idB)","Names":["/shop-db-1"],"Image":"postgres:17","State":"running","Status":"Up 3 hours (healthy)",
      "Created":1790000000,"Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"db"}},
     {"Id":"\(idC)","Names":["/scratch"],"Image":"redis:8","State":"running","Status":"Up 2 days",
      "Created":1789800000,"Labels":{}}]
    """
    /// cgroup v2: usage 416 MB with 118 MB of inactive file cache.
    static func stats(usage: UInt64, inactive: UInt64, cpu: UInt64, system: UInt64, limit: UInt64 = 12_515_225_600) -> String {
        """
        {"memory_stats":{"usage":\(usage),"limit":\(limit),"stats":{"inactive_file":\(inactive),"anon":1}},
         "cpu_stats":{"cpu_usage":{"total_usage":\(cpu)},"system_cpu_usage":\(system),"online_cpus":4},
         "pids_stats":{"current":25}}
        """
    }
}

@Suite struct DockerAPITests {
    @Test func infoAndContainers() throws {
        let i = try #require(DockerAPI.info(Data(Replies.info.utf8)))
        #expect(i.memTotal == 12_515_225_600 && i.cpus == 4 && i.running == 3 && i.stopped == 4 && i.images == 41)
        let cs = try #require(DockerAPI.containers(Data(Replies.containers.utf8)))
        #expect(cs.map(\.name) == ["shop-backend-1", "shop-db-1", "scratch"])
        #expect(cs[0].project == "shop" && cs[0].service == "backend" && cs[0].displayName == "backend")
        #expect(cs[2].project == nil && cs[2].displayName == "scratch")
        #expect(cs[1].status == "Up 3 hours (healthy)" && cs[0].shortId == String(repeating: "a", count: 12))
        #expect(cs[0].createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        // An error body is not a container list.
        #expect(DockerAPI.containers(Data("{\"message\":\"nope\"}".utf8)) == nil)
    }

    @Test func statsSubtractInactiveFileCacheAndGiveCPUFromTwoSamples() throws {
        let a = try #require(DockerAPI.stats(Data(Replies.stats(usage: 416_000_000, inactive: 118_000_000,
                                                                cpu: 1_000_000_000, system: 100_000_000_000).utf8)))
        #expect(a.memory == 298_000_000 && a.memoryLimit == 12_515_225_600 && a.pids == 25)
        let b = try #require(DockerAPI.stats(Data(Replies.stats(usage: 420_000_000, inactive: 118_000_000,
                                                                cpu: 1_500_000_000, system: 104_000_000_000).utf8)))
        // 0.5 s of CPU while the host's 4 CPUs advanced 4 s in total = half of one CPU.
        #expect(abs((DockerAPI.cpuPercent(previous: a, current: b) ?? 0) - 50) < 0.001)
        #expect(DockerAPI.cpuPercent(previous: b, current: a) == nil)
        // cgroup v1 names the field total_inactive_file.
        let v1 = "{\"memory_stats\":{\"usage\":1000,\"stats\":{\"total_inactive_file\":400}},\"cpu_stats\":{}}"
        #expect(DockerAPI.stats(Data(v1.utf8))?.memory == 600)
        #expect(DockerAPI.stats(Data("{}".utf8)) == nil)
    }

    @Test func diskUsesTheSummaryWhenTheEngineSendsOne() {
        let image = "{\"LayersSize\":9,\"Images\":[],\"ImageUsage\":{\"TotalCount\":56,\"ActiveCount\":25,\"TotalSize\":66884848219,\"Reclaimable\":20959422232}}"
        #expect(DockerAPI.diskStat(Data(image.utf8), .image)
                == DockerDiskStat(count: 56, size: 66_884_848_219, reclaimable: 20_959_422_232))
        let cache = "{\"BuildCacheUsage\":{\"TotalCount\":307,\"TotalSize\":24881011473,\"Reclaimable\":18757869172}}"
        #expect(DockerAPI.diskStat(Data(cache.utf8), .buildCache)?.reclaimable == 18_757_869_172)
    }

    @Test func diskSumsTheItemsOnOlderEngines() {
        let image = """
        {"LayersSize":1000,"Images":[{"Size":600,"SharedSize":100,"Containers":1},{"Size":500,"SharedSize":100,"Containers":0}]}
        """
        #expect(DockerAPI.diskStat(Data(image.utf8), .image) == DockerDiskStat(count: 2, size: 1000, reclaimable: 500))
        let containers = "{\"Containers\":[{\"SizeRw\":70,\"State\":\"running\"},{\"SizeRw\":30,\"State\":\"exited\"}]}"
        #expect(DockerAPI.diskStat(Data(containers.utf8), .container) == DockerDiskStat(count: 2, size: 100, reclaimable: 30))
        let volumes = "{\"Volumes\":[{\"UsageData\":{\"Size\":50,\"RefCount\":1}},{\"UsageData\":{\"Size\":20,\"RefCount\":0}},{\"UsageData\":{\"Size\":-1,\"RefCount\":0}}]}"
        #expect(DockerAPI.diskStat(Data(volumes.utf8), .volume) == DockerDiskStat(count: 3, size: 70, reclaimable: 20))
        let cache = "{\"BuildCache\":[{\"Size\":40,\"InUse\":true,\"Shared\":false},{\"Size\":60,\"InUse\":false,\"Shared\":false},{\"Size\":99,\"InUse\":false,\"Shared\":true}]}"
        #expect(DockerAPI.diskStat(Data(cache.utf8), .buildCache) == DockerDiskStat(count: 3, size: 100, reclaimable: 60))
        #expect(DockerAPI.diskStat(Data("{}".utf8), .image) == nil)
    }

    @Test func httpReplyIsSplitAtTheBlankLine() {
        let r = UnixHTTP.parse(Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{\"a\":1}".utf8))
        #expect(r?.status == 200 && r?.ok == true && r.map { String(data: $0.body, encoding: .utf8) } == "{\"a\":1}")
        #expect(UnixHTTP.parse(Data("HTTP/1.0 500 Internal Server Error\r\n\r\nboom".utf8))?.ok == false)
        #expect(UnixHTTP.parse(Data("garbage".utf8)) == nil)
    }
}

@Suite struct DockerEndpointTests {
    @Test func overrideOffAndDockerHost() {
        let home = "/nonexistent"
        #expect(DockerEndpoint.resolve(environment: ["HEADROOM_DOCKER_SOCKET": "/x/docker.sock"], home: home)?.socketPath == "/x/docker.sock")
        #expect(DockerEndpoint.resolve(environment: ["HEADROOM_DOCKER_SOCKET": "off", "DOCKER_HOST": "unix:///y.sock"], home: home) == nil)
        #expect(DockerEndpoint.resolve(environment: ["DOCKER_HOST": "unix:///y/d.sock"], home: home)?.socketPath == "/y/d.sock")
        // A remote engine is not on this Mac.
        #expect(DockerEndpoint.resolve(environment: ["DOCKER_HOST": "tcp://10.0.0.5:2375"], home: home) == nil)
    }

    @Test func currentContextIsResolvedThroughItsMetaFile() throws {
        let d = ShortDir()
        defer { d.cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(atPath: d.path + "/.docker/contexts/meta/abc123", withIntermediateDirectories: true)
        try Data("{\"currentContext\":\"colima-work\"}".utf8).write(to: URL(fileURLWithPath: d.path + "/.docker/config.json"))
        let meta = "{\"Name\":\"colima-work\",\"Endpoints\":{\"docker\":{\"Host\":\"unix://\(d.path)/.colima/work/docker.sock\"}}}"
        try Data(meta.utf8).write(to: URL(fileURLWithPath: d.path + "/.docker/contexts/meta/abc123/meta.json"))
        let ep = try #require(DockerEndpoint.resolve(environment: [:], home: d.path))
        #expect(ep.socketPath == d.path + "/.colima/work/docker.sock" && ep.context == "colima-work")
        #expect(ep.runtime == .colima)
        #expect(ep.limaInstanceDir == d.path + "/.colima/_lima/colima-work")
        // DOCKER_CONTEXT=default skips the context and falls through to the sockets that exist (none here but
        // possibly /var/run/docker.sock on the machine that runs the test).
        let fallback = DockerEndpoint.resolve(environment: ["DOCKER_CONTEXT": "default"], home: d.path)
        #expect(fallback == nil || fallback?.socketPath == "/var/run/docker.sock")
    }

    @Test func firstExistingSocketWinsAndNamesTheRuntime() throws {
        let d = ShortDir()
        defer { d.cleanup() }
        try FileManager.default.createDirectory(atPath: d.path + "/.orbstack/run", withIntermediateDirectories: true)
        let engine = FakeEngine(socketPath: d.path + "/.orbstack/run/docker.sock")
        defer { engine.stop() }
        let ep = try #require(DockerEndpoint.resolve(environment: [:], home: d.path))
        #expect(ep.socketPath == engine.socketPath && ep.runtime == .orbstack && ep.limaInstanceDir == nil)
    }

    @Test func runtimeAndLimaDirFromTheSocketPath() {
        #expect(DockerEndpoint(socketPath: "/Users/a/.colima/default/docker.sock").runtime == .colima)
        #expect(DockerEndpoint(socketPath: "/Users/a/.colima/default/docker.sock").limaInstanceDir == "/Users/a/.colima/_lima/colima")
        #expect(DockerEndpoint(socketPath: "/Users/a/.docker/run/docker.sock").runtime == .dockerDesktop)
        #expect(DockerEndpoint(socketPath: "/Users/a/.rd/docker.sock").runtime == .rancher)
        #expect(DockerEndpoint(socketPath: "/Users/a/.lima/docker/sock/docker.sock").limaInstanceDir == "/Users/a/.lima/docker")
        #expect(DockerEndpoint(socketPath: "/somewhere/else.sock").runtime == .docker)
    }
}

@Suite struct DockerVMTests {
    static let vz = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
        + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    static func p(_ pid: Int32, _ path: String, start: Int, ppid: Int32 = 1, mb: Double = 10) -> ProcSample {
        ProcSample(key: ProcKey(pid: pid, startSec: start), ppid: ppid, pgid: pid, path: path, footprint: .mb(mb), rss: .mb(mb))
    }

    @Test func colimaVMIsTheOneThatSharesTheHostAgentsResponsibleProcess() {
        let table = ProcessTable(samples: [
            Self.p(100, "/opt/homebrew/bin/limactl", start: 1000),
            Self.p(110, Self.vz, start: 1003, mb: 2800),          // colima's VM
            Self.p(210, Self.vz, start: 5000, mb: 900),           // another app's VM
            Self.p(300, "/Applications/Ghostty.app/Contents/MacOS/ghostty", start: 10),
            Self.p(400, "/Applications/UTM.app/Contents/MacOS/UTM", start: 20),
        ])
        let responsible: (Int32) -> Int32? = { [100: 300, 110: 300, 210: 400][$0] }
        #expect(DockerSource.vmPids(table, runtime: .colima, hostAgentPid: 100, responsible: responsible) == [110])
        // Responsibility unknown and two VMs: Headroom does not guess.
        #expect(DockerSource.vmPids(table, runtime: .colima, hostAgentPid: 100, responsible: { _ in nil }) == [])
        // Responsibility unknown and one VM: it is the one.
        let one = ProcessTable(samples: [Self.p(100, "/opt/homebrew/bin/limactl", start: 1000), Self.p(110, Self.vz, start: 1003)])
        #expect(DockerSource.vmPids(one, runtime: .colima, hostAgentPid: nil, responsible: { _ in nil }) == [110])
        // A qemu VM is a child of the host agent.
        let qemu = ProcessTable(samples: [Self.p(100, "/opt/homebrew/bin/limactl", start: 1000),
                                          Self.p(120, "/opt/homebrew/bin/qemu-system-aarch64", start: 1001, ppid: 100)])
        #expect(DockerSource.vmPids(qemu, runtime: .colima, hostAgentPid: 100, responsible: { _ in nil }) == [120])
    }

    @Test func dockerDesktopAndOrbStackUseTheirOwnProcesses() {
        let table = ProcessTable(samples: [
            Self.p(500, "/Applications/Docker.app/Contents/MacOS/com.docker.backend", start: 10),
            Self.p(510, "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization", start: 11, mb: 4000),
            Self.p(520, Self.vz, start: 12, mb: 100),
            Self.p(600, "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper", start: 13),
        ])
        let responsible: (Int32) -> Int32? = { $0 == 520 ? 500 : nil }
        #expect(DockerSource.vmPids(table, runtime: .dockerDesktop, hostAgentPid: nil, responsible: responsible) == [510, 520])
        #expect(DockerSource.vmPids(table, runtime: .orbstack, hostAgentPid: nil, responsible: responsible) == [600])
        #expect(DockerSource.vmPids(table, runtime: .docker, hostAgentPid: nil, responsible: responsible) == [])
    }

    @Test func snapshotGetsTheVMsFootprint() {
        let table = ProcessTable(samples: [Self.p(110, Self.vz, start: 1003, mb: 2800)])
        let ep = DockerEndpoint(socketPath: "/nonexistent/.colima/default/docker.sock")
        let s = DockerSource.withVM(DockerSnapshot(status: .running, runtime: "colima"), endpoint: ep, table: table,
                                    responsible: { _ in nil })
        #expect(s.vmPids == [110] && s.vmFootprint == .mb(2800) && s.macBytes == .mb(2800))
        // Not running: nothing is attributed.
        let off = DockerSource.withVM(DockerSnapshot(status: .notRunning, runtime: "colima"), endpoint: ep, table: table,
                                      responsible: { _ in nil })
        #expect(off.vmPids.isEmpty && off.vmFootprint == nil && off.macBytes == nil)
    }
}

@Suite struct DockerSourceTests {
    func engine(_ d: ShortDir) -> FakeEngine {
        let e = FakeEngine(socketPath: d.path + "/docker.sock")
        e.respond(DockerAPI.infoPath, Replies.info)
        e.respond(DockerAPI.containersPath, Replies.containers)
        e.respond(DockerAPI.statsPath(Replies.idA), Replies.stats(usage: 700_000_000, inactive: 100_000_000, cpu: 1_000_000_000, system: 100_000_000_000))
        e.respond(DockerAPI.statsPath(Replies.idB), Replies.stats(usage: 300_000_000, inactive: 0, cpu: 0, system: 100_000_000_000, limit: 536_870_912))
        // idC has no stats route: the engine answers 404 and the container keeps an unknown memory.
        return e
    }

    @Test func readsContainersStatsAndCountsThenCPUOnTheSecondRead() async throws {
        let d = ShortDir()
        defer { d.cleanup() }
        let e = engine(d)
        defer { e.stop() }
        let ep = DockerEndpoint(socketPath: e.socketPath, runtime: .colima)
        let (s, stats) = await DockerSource.load(endpoint: ep, previous: [:], timeout: 5)
        #expect(s.status == .running && s.runtime == "colima" && s.stoppedCount == 4 && s.imageCount == 41)
        #expect(s.vmMemoryLimit == 12_515_225_600 && s.cpus == 4 && s.at != nil)
        let by = Dictionary(uniqueKeysWithValues: s.containers.map { ($0.name, $0) })
        #expect(by["shop-backend-1"]?.memory == 600_000_000)
        // The VM's own memory is not a container limit; a real limit is kept.
        #expect(by["shop-backend-1"]?.memoryLimit == nil && by["shop-db-1"]?.memoryLimit == 536_870_912)
        #expect(by["scratch"]?.memory == nil && by["shop-backend-1"]?.cpuPercent == nil)
        #expect(s.containersMemory == 900_000_000)
        #expect(s.projects.map(\.name) == ["shop", nil] && s.projects[0].memory == 900_000_000)
        // Only GETs for info, the list and one stats call per container.
        #expect(Set(e.requests) == [DockerAPI.infoPath, DockerAPI.containersPath, DockerAPI.statsPath(Replies.idA),
                                    DockerAPI.statsPath(Replies.idB), DockerAPI.statsPath(Replies.idC)])

        e.respond(DockerAPI.statsPath(Replies.idA), Replies.stats(usage: 700_000_000, inactive: 100_000_000, cpu: 3_000_000_000, system: 104_000_000_000))
        let (s2, _) = await DockerSource.load(endpoint: ep, previous: stats, timeout: 5)
        let cpu = s2.containers.first { $0.name == "shop-backend-1" }?.cpuPercent
        #expect(abs((cpu ?? 0) - 200) < 0.001)
    }

    @Test func noSocketOrNoAnswerIsNotRunning() async {
        let d = ShortDir()
        defer { d.cleanup() }
        let missing = DockerEndpoint(socketPath: d.path + "/gone.sock", runtime: .colima)
        #expect(await DockerSource.load(endpoint: missing, previous: [:], timeout: 1).0.status == .notRunning)
        #expect(await DockerSource.load(endpoint: nil, previous: [:], timeout: 1).0 == .empty)
        // The engine answers, but with an error.
        let e = FakeEngine(socketPath: d.path + "/docker.sock")
        defer { e.stop() }
        e.respond(DockerAPI.containersPath, "{\"message\":\"starting\"}", status: 503)
        let s = await DockerSource.load(endpoint: DockerEndpoint(socketPath: e.socketPath, runtime: .colima), previous: [:], timeout: 2).0
        #expect(s.status == .notRunning && s.containers.isEmpty)
    }

    @Test func sourceRefreshesOnRequestAndKeepsDiskUseOnDisk() async throws {
        let d = ShortDir()
        defer { d.cleanup() }
        let e = engine(d)
        defer { e.stop() }
        e.respond(DockerAPI.DiskType.image.path, "{\"ImageUsage\":{\"TotalCount\":2,\"TotalSize\":1000,\"Reclaimable\":400}}")
        e.respond(DockerAPI.DiskType.container.path, "{\"ContainerUsage\":{\"TotalCount\":3,\"TotalSize\":100,\"Reclaimable\":30}}")
        e.respond(DockerAPI.DiskType.volume.path, "{\"VolumeUsage\":{\"TotalCount\":1,\"TotalSize\":70,\"Reclaimable\":20}}")
        e.respond(DockerAPI.DiskType.buildCache.path, "{\"BuildCacheUsage\":{\"TotalCount\":9,\"TotalSize\":100,\"Reclaimable\":60}}")
        var env = HeadroomEnv(environment: ["HOME": d.path, "HEADROOM_SUPPORT_DIR": d.path + "/support"])
        env.mock = false
        let environment = ["HEADROOM_DOCKER_SOCKET": e.socketPath]
        let source = DockerSource(env: env, environment: environment)
        // Without a cadence (the CLI, tests) a snapshot starts nothing in the background.
        #expect(source.snapshot(.empty).status == .notFound)
        #expect(e.requests.isEmpty)
        await source.refresh()
        let s = source.snapshot(.empty)
        #expect(s.status == .running && s.containers.count == 3 && s.disk == nil)

        let disk = try #require(await source.refreshDisk())
        #expect(disk.total == 1270 && disk.reclaimable == 510 && disk.images.count == 2)
        #expect(source.snapshot(.empty).disk == disk)
        // A new source (the next launch) starts with the saved numbers.
        let again = DockerSource(env: env, environment: environment)
        await again.refresh()
        #expect(again.snapshot(.empty).disk?.total == 1270)
        // Saved numbers belong to one engine: another socket does not get them.
        let other = FakeEngine(socketPath: d.path + "/other.sock")
        defer { other.stop() }
        other.respond(DockerAPI.containersPath, "[]")
        let elsewhere = DockerSource(env: env, environment: ["HEADROOM_DOCKER_SOCKET": other.socketPath])
        await elsewhere.refresh()
        #expect(elsewhere.snapshot(.empty).status == .running && elsewhere.snapshot(.empty).disk == nil)
    }
}
