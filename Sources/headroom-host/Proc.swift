// Minimal libproc helpers for the host (it depends on Foundation + Contracts only, not HeadroomCore).
// Used to describe the parent browser and, in --probe mode, to join processIds to renderers.

import Darwin
import Foundation

enum Proc {
    static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return Array(pids.prefix(Int(got))).filter { $0 > 0 }
    }

    static func ppid(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func uid(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)), as: UTF8.self)
    }

    /// Physical footprint (Activity Monitor's Memory column).
    static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    /// argv via KERN_PROCARGS2 (same uid only).
    static func args(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // exec path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var out: [String] = []
        while out.count < argc && i < size {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            out.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }

    /// All descendants of `root` (not including it), from one scan.
    static func descendants(of root: pid_t) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for p in allPids() { if let pp = ppid(p) { children[pp, default: []].append(p) } }
        var out: [pid_t] = []
        var stack = children[root] ?? []
        while let p = stack.popLast() {
            out.append(p)
            stack.append(contentsOf: children[p] ?? [])
        }
        return out
    }

    static func flag(_ argv: [String], _ name: String) -> String? {
        let prefix = name + "="
        return argv.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// A Chrome-family browser process: argv[0] names a Chrome/Chromium binary and there is no --type.
    static func looksLikeBrowser(_ pid: pid_t) -> Bool {
        let argv = args(pid)
        guard let exe = argv.first ?? path(pid) else { return false }
        let name = (exe as NSString).lastPathComponent
        let chromeish = name.hasPrefix("Google Chrome") || name.hasPrefix("Chromium") || name.contains("Chrome")
        return chromeish && flag(argv, "--type") == nil
    }
}
