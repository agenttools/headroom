// The live process/memory reader (SPEC §1 "Memory figure", §2 SysKit, §9 budget).
//
//  scan():         proc_listallpids + PROC_PIDTBSDINFO + proc_pid_rusage(RUSAGE_INFO_V6) + proc_pidpath
//                  (path cached per (ProcKey, comm), so exec is noticed). No subprocess, ever.
//  args(k):        KERN_PROCARGS2 → argv + filtered env (CLAUDE_* minus credentials, plus TMUX, TMUX_PANE,
//                  REX_SESSION, REX_BLOCK), cached per ProcKey (negative results too), dropped when scan() sees its
//                  comm change (exec); pruned to live keys on every scan().
//  cwd(pid):       PROC_PIDVNODEPATHINFO
//  parentPid(pid): PROC_PIDT_SHORTBSDINFO, which also answers for other users' processes that scan() leaves out
//                  (Rex's root-owned /usr/bin/login between the Rex server and a pane's shell). Not cached.
//  systemMemory(): host_statistics64(HOST_VM_INFO64) + hw.memsize + vm.swapusage
//                  + kern.memorystatus_vm_pressure_level (Activity Monitor's formulas).
//  isAlive(k):     PROC_PIDTBSDINFO start time == k.startSec and not a zombie. Never sends a signal.
//
// Thread safety: every cache sits behind one lock; the class is safe to share across tasks.

import Darwin
import Foundation
import HeadroomContracts

public final class LiveSysKit: SysKit, @unchecked Sendable {
    public let env: HeadroomEnv
    private let lock = NSLock()
    /// nil value = "tried, unreadable" (other uid, zombie, gone), so we do not retry every tick.
    private var argsCache: [ProcKey: ProcArgs?] = [:]
    private var pathCache: [ProcKey: (comm: String, path: String)] = [:]
    private var liveKeys: Set<ProcKey> = []
    private let argMax: Int
    /// Mach ticks → ns for rusage CPU times (Apple Silicon reports ticks, not ns).
    private let timebase: (numer: UInt64, denom: UInt64)

    public init(env: HeadroomEnv = .current) {
        self.env = env
        var am: Int32 = 0; var sz = MemoryLayout<Int32>.size
        argMax = sysctlbyname("kern.argmax", &am, &sz, nil, 0) == 0 && am > 0 ? Int(am) : 1 << 20
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = (UInt64(max(tb.numer, 1)), UInt64(max(tb.denom, 1)))
    }

    // MARK: - Low-level readers (public so selftests and other WPs can reuse them)

    /// All pids (proc_listallpids), unsorted.
    public static func allPids() -> [pid_t] {
        var cap = Int(proc_listallpids(nil, 0)) + 256
        while true {
            var buf = [pid_t](repeating: 0, count: cap)
            let n = buf.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            if n <= 0 { return [] }
            if Int(n) < cap { return Array(buf.prefix(Int(n))) }
            cap *= 2
        }
    }

    /// PROC_PIDTBSDINFO; nil if the pid is gone.
    public static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return r == size ? info : nil
    }

    /// RUSAGE_INFO_V6; nil when not permitted (other uid) or gone.
    public static func rusage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return r == 0 ? info : nil
    }

    /// ri_phys_footprint (Activity Monitor "Memory").
    public static func footprint(_ pid: pid_t) -> Bytes? { rusage(pid)?.ri_phys_footprint }

    public static func pidPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Raw KERN_PROCARGS2 for `pid`, parsed; nil when unreadable.
    public func readArgs(pid: pid_t) -> ProcArgs? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        // Uninitialised scratch buffer: zero-filling 1 MB per process would dominate the cost.
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buf.deallocate() }
        let r = sysctl(&mib, 3, buf, &size, nil, 0)
        guard r == 0, size > 0 else { return nil }
        return ProcArgsParser.procArgs(UnsafeRawBufferPointer(start: buf, count: size))
    }

    private static func tupleString<T>(_ t: T) -> String {
        withUnsafeBytes(of: t) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    // MARK: - SysKit

    public func scan() -> ProcessTable {
        let now = Date()
        let pids = Self.allPids()
        var samples: [ProcSample] = []
        samples.reserveCapacity(pids.count)
        var seen: Set<ProcKey> = []
        seen.reserveCapacity(pids.count)
        var newPaths: [ProcKey: (comm: String, path: String)] = [:]
        var execed: [ProcKey] = []

        lock.lock()
        let cachedPaths = pathCache
        lock.unlock()

        for pid in pids where pid > 0 {
            guard let bi = Self.bsdInfo(pid) else { continue }
            if bi.pbi_status == UInt32(SZOMB) { continue }
            let key = ProcKey(pid: pid, startSec: Int(bi.pbi_start_tvsec))
            let comm = Self.tupleString(bi.pbi_comm)
            let path: String
            if let c = cachedPaths[key], c.comm == comm {
                path = c.path
            } else {
                if cachedPaths[key] != nil { execed.append(key) }   // same pid + start time, new image: exec
                path = Self.pidPath(pid) ?? ""
            }
            newPaths[key] = (comm, path)
            var fp: Bytes = 0, rss: Bytes = 0, cpu: UInt64 = 0
            if let ru = Self.rusage(pid) {
                fp = ru.ri_phys_footprint
                rss = ru.ri_resident_size
                cpu = (ru.ri_user_time &+ ru.ri_system_time) &* timebase.numer / timebase.denom
            }
            samples.append(ProcSample(key: key, ppid: Int32(bi.pbi_ppid), pgid: Int32(bi.pbi_pgid),
                                      uid: bi.pbi_uid, path: path, footprint: fp, rss: rss, cpuNs: cpu))
            seen.insert(key)
        }

        lock.lock()
        pathCache = newPaths
        liveKeys = seen
        // An exec replaced argv and env (e.g. `exec claude` in a pane shell): read them again on the next args(k).
        for k in execed { argsCache.removeValue(forKey: k) }
        // Prune args of processes that are gone (bounded memory for a long-running app).
        if argsCache.count > seen.count + 64 {
            argsCache = argsCache.filter { seen.contains($0.key) }
        }
        lock.unlock()
        return ProcessTable(samples: samples, takenAt: now)
    }

    public func args(_ k: ProcKey) -> ProcArgs? {
        lock.lock()
        if let hit = argsCache[k] { lock.unlock(); return hit }
        lock.unlock()
        // Read, then confirm the pid was not reused while we read (start time unchanged).
        var result = readArgs(pid: k.pid)
        if let bi = Self.bsdInfo(k.pid), Int(bi.pbi_start_tvsec) == k.startSec {
            // keep
        } else {
            result = nil
        }
        lock.lock()
        argsCache[k] = .some(result)
        lock.unlock()
        return result
    }

    public func cwd(_ pid: Int32) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size)
        guard r == size else { return nil }
        let s = Self.tupleString(vpi.pvi_cdir.vip_path)
        return s.isEmpty ? nil : s
    }

    public func systemMemory() -> SystemMemory {
        var total: UInt64 = 0
        var sz = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &sz, nil, 0)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize == 0 ? 16384 : pageSize)
        var app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, free: UInt64 = 0
        if kr == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            wired = UInt64(stats.wire_count) * page
            compressed = UInt64(stats.compressor_page_count) * page
            let fc = UInt64(stats.free_count), spec = UInt64(stats.speculative_count)
            free = (fc > spec ? fc - spec : 0) * page
        }
        let swap = Self.swapUsage()
        return SystemMemory(total: total, used: app + wired + compressed, appMemory: app, wired: wired,
                            compressed: compressed, free: free, swapUsed: swap.used, swapTotal: swap.total,
                            pressure: Self.pressure())
    }

    public func isAlive(_ k: ProcKey) -> Bool {
        guard let bi = Self.bsdInfo(k.pid) else { return false }
        return Int(bi.pbi_start_tvsec) == k.startSec && bi.pbi_status != UInt32(SZOMB)
    }

    public func parentPid(_ pid: Int32) -> Int32? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        let r = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        guard r == size, let ppid = Int32(exactly: info.pbsi_ppid), ppid > 0 else { return nil }
        return ppid
    }

    // MARK: - System helpers

    public static func swapUsage() -> (used: Bytes, total: Bytes) {
        var xsw = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &xsw, &sz, nil, 0) == 0 else { return (0, 0) }
        return (xsw.xsu_used, xsw.xsu_total)
    }

    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    public static func pressure() -> Pressure {
        var lvl: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &sz, nil, 0) == 0 else { return .normal }
        return Pressure(rawValue: Int(lvl)) ?? .normal
    }

    /// Memory-pressure transitions (DispatchSource), for refreshing the system strip on events (SPEC §9).
    /// Each element is the level read right after the event. The source is cancelled when the stream ends.
    public static func pressureEvents() -> AsyncStream<Pressure> {
        AsyncStream { cont in
            let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                              queue: .global(qos: .utility))
            src.setEventHandler { cont.yield(pressure()) }
            cont.onTermination = { _ in src.cancel() }
            src.resume()
        }
    }

    /// This process's own footprint (for the footer).
    public static func selfFootprint() -> Bytes { footprint(getpid()) ?? 0 }

    /// Number of argument entries currently cached (tests/selftest).
    public var cachedArgsCount: Int { lock.lock(); defer { lock.unlock() }; return argsCache.count }
}
