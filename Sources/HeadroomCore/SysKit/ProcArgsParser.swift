// Pure parser for a KERN_PROCARGS2 buffer, and the environment filter (no secrets ever kept).
//
// Buffer layout (xnu bsd/kern/kern_sysctl.c, sysctl_procargsx):
//   [int32 argc][exec_path \0][\0 padding …][argv[0] \0] … [argv[argc-1] \0][env[0] \0] … [env[n] \0][\0 …]
// argv entries may be empty strings, so we count NULs rather than splitting on runs of them.

import Foundation
import HeadroomContracts

public enum ProcArgsParser {
    /// Parses a raw KERN_PROCARGS2 buffer. Returns nil when the buffer is malformed.
    public static func parse(_ buf: UnsafeRawBufferPointer) -> (execPath: String, argv: [String], env: [String])? {
        let n = buf.count
        guard n >= 4 else { return nil }
        let argc = Int(buf.loadUnaligned(fromByteOffset: 0, as: Int32.self))
        guard argc >= 0, argc < 1_000_000 else { return nil }
        var i = 4
        func readCString() -> String {
            let start = i
            while i < n && buf[i] != 0 { i += 1 }
            let s = String(decoding: UnsafeRawBufferPointer(rebasing: buf[start..<i]), as: UTF8.self)
            if i < n { i += 1 }   // skip the terminator
            return s
        }
        let execPath = readCString()
        // Skip alignment padding between exec_path and argv[0].
        while i < n && buf[i] == 0 { i += 1 }
        var argv: [String] = []
        argv.reserveCapacity(argc)
        while argv.count < argc && i < n { argv.append(readCString()) }
        var env: [String] = []
        while i < n {
            if buf[i] == 0 { break }   // an empty string ends the environment
            env.append(readCString())
        }
        return (execPath, argv, env)
    }

    public static func parse(_ data: Data) -> (execPath: String, argv: [String], env: [String])? {
        data.withUnsafeBytes { parse($0) }
    }

    /// Words that mark an environment key as a possible secret. Such keys are never kept, even under CLAUDE_*.
    static let secretMarkers = ["TOKEN", "KEY", "SECRET", "PASS", "AUTH", "CRED", "COOKIE", "SESSION_ACCESS"]

    /// Keys kept outside the CLAUDE_* prefix (none of them carry secrets).
    public static let extraKeptKeys: Set<String> = ["TMUX_PANE", "TMUX"]

    /// True if SysKit keeps `key`: CLAUDE_* (minus anything that looks like a credential) plus `extraKeptKeys`.
    public static func keeps(_ key: String) -> Bool {
        if extraKeptKeys.contains(key) { return true }
        guard key.hasPrefix("CLAUDE_") else { return false }
        let upper = key.uppercased()
        return !secretMarkers.contains { upper.contains($0) }
    }

    /// Filters `KEY=value` strings down to the kept keys.
    public static func filterEnv(_ env: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for e in env {
            guard let eq = e.firstIndex(of: "=") else { continue }
            let k = String(e[..<eq])
            guard keeps(k) else { continue }
            out[k] = String(e[e.index(after: eq)...])
        }
        return out
    }

    /// Builds a ProcArgs from a raw buffer (argv + filtered env).
    public static func procArgs(_ buf: UnsafeRawBufferPointer) -> ProcArgs? {
        guard let p = parse(buf) else { return nil }
        return ProcArgs(argv: p.argv, env: filterEnv(p.env))
    }
}
