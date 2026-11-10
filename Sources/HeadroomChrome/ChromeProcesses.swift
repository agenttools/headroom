// Chrome process classification (SPEC §4.1) and collection of the main browsers' processes from one
// ProcessTable + OwnershipMap.
//
// Which pids belong to the Chrome section:
//   - every pid Ownership assigned to `.chrome(browserPid: b)` for a main browser b (this includes the
//     crashpad handler that Chrome reparents to launchd);
//   - for a browser that a connected host names but Ownership does not know as a Chrome browser (Chrome for
//     Testing in the e2e tests, Chrome Beta, …): that browser and its ppid subtree, but only pids Ownership
//     left unowned, so a pid is never counted in two sections.
// Automation browsers no session owns (`.otherChrome`) are summed separately ("Other Chrome instances").

import Foundation
import HeadroomContracts

/// §4.1 process classes.
public enum ChromeProcKind: Hashable, Sendable, Codable {
    case browser
    case gpu
    case utility
    case crashpad
    /// `--type=renderer --extension-process`
    case extensionRenderer
    /// `--type=renderer`; clientId from `--renderer-client-id=N` (nil if Chrome did not pass it).
    case renderer(clientId: Int?)
    /// Any other `--type=…` value, or argv we could not read. Counted as utility overhead.
    case other(String)

    /// Classifies one Chrome process by its argv (nil = unreadable).
    public static func classify(_ args: ProcArgs?) -> ChromeProcKind {
        guard let a = args, !a.argv.isEmpty else { return .other("unreadable") }
        // The crashpad handler Chrome 154 starts has no --type, only its own binary name and an annotation.
        if (a.argv0 as NSString).lastPathComponent == "chrome_crashpad_handler"
            || a.argv.contains("--monitor-self-annotation=ptype=crashpad-handler") { return .crashpad }
        guard let type = a.flag("type") else { return .browser }
        switch type {
        case "gpu-process": return .gpu
        case "utility": return .utility
        case "crashpad-handler": return .crashpad
        case "renderer":
            if a.hasFlag("extension-process") { return .extensionRenderer }
            return .renderer(clientId: a.flag("renderer-client-id").flatMap { Int($0) })
        default: return .other(type)
        }
    }

    public var overheadKind: ChromeOverheadKind? {
        switch self {
        case .browser: .browser
        case .gpu: .gpu
        case .utility, .other: .utility
        case .crashpad: .crashpad
        case .extensionRenderer: .extensions
        case .renderer: nil
        }
    }
}

/// One process of a main browser, classified.
public struct ChromeProc: Hashable, Sendable, Codable {
    public let key: ProcKey
    public let browserPid: Int32
    public let kind: ChromeProcKind
    public let footprint: Bytes
    /// `--renderer-client-id` of an extension renderer (tabs showing chrome-extension:// pages have frames there).
    public let extensionClientId: Int?
    public init(key: ProcKey, browserPid: Int32, kind: ChromeProcKind, footprint: Bytes, extensionClientId: Int? = nil) {
        self.key = key; self.browserPid = browserPid; self.kind = kind; self.footprint = footprint
        self.extensionClientId = extensionClientId
    }
    public var clientId: Int? { if case .renderer(let c) = kind { c } else { nil } }
}

public enum ChromeProcesses {
    /// The main browser pids for this refresh: Ownership's main browsers plus browsers named by a connected
    /// host (see the file header). Only pids present in `t`.
    public static func mainBrowserPids(_ t: ProcessTable, _ o: OwnershipMap, hostBrowserPids: Set<Int32>) -> [Int32] {
        var out = Set(o.mainBrowsers.map(\.key.pid).filter { t.byPid[$0] != nil })
        for b in hostBrowserPids where t.byPid[b] != nil && !out.contains(b) {
            switch o.owner[b] {
            case nil, .unowned?: out.insert(b)
            case .chrome(let owner)? where owner == b: out.insert(b)
            default: break  // Ownership put it elsewhere (e.g. a session's automation browser): never count twice
            }
        }
        return out.sorted()
    }

    /// All processes of the given main browsers, classified via `args` (cached per ProcKey by SysKit).
    /// `excluding`: pids never counted (the headroom-host processes, which are the browser's children).
    public static func collect(_ t: ProcessTable, _ o: OwnershipMap, mainBrowsers: [Int32],
                               excluding: Set<Int32> = [], args: (ProcKey) -> ProcArgs?) -> [ChromeProc] {
        var out: [ChromeProc] = []
        var seen = excluding
        let mains = Set(mainBrowsers)
        func kind(_ pid: Int32, _ b: Int32, _ k: ProcKey) -> ChromeProcKind {
            if pid == b { return .browser }
            let c = ChromeProcKind.classify(args(k))
            return c == .browser ? .other("no --type") : c  // only the browser itself has no --type
        }
        func proc(_ s: ProcSample, _ b: Int32) -> ChromeProc {
            let k = kind(s.pid, b, s.key)
            let ext = k == .extensionRenderer ? args(s.key)?.flag("renderer-client-id").flatMap { Int($0) } : nil
            return ChromeProc(key: s.key, browserPid: b, kind: k, footprint: s.footprint, extensionClientId: ext)
        }
        // 1. Ownership-assigned pids.
        for (pid, owner) in o.owner {
            guard case .chrome(let b) = owner, mains.contains(b), !seen.contains(pid), let s = t.byPid[pid] else { continue }
            seen.insert(pid)
            out.append(proc(s, b))
        }
        // 2. Host-named browsers Ownership did not claim: the subtree's unowned pids that run from the same app
        //    bundle as the browser (so the host and anything else Chrome spawned are not counted).
        for b in mains where o.owner[b] != .chrome(browserPid: b) {
            guard let bs = t.byPid[b] else { continue }
            let bundle = appBundle(bs.path)
            for pid in [b] + t.descendants(of: b) where !seen.contains(pid) {
                switch o.owner[pid] { case nil, .unowned?: break; default: continue }
                guard let s = t.byPid[pid], pid == b || bundle == nil || appBundle(s.path) == bundle else { continue }
                seen.insert(pid)
                out.append(proc(s, b))
            }
        }
        return out.sorted { $0.key < $1.key }
    }

    /// "/Applications/Google Chrome.app" for any path inside it (the outermost .app), nil if none.
    static func appBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.upperBound])
    }

    /// "Other Chrome instances": automation browsers Ownership marked `.otherChrome` (whole units).
    public static func otherInstances(_ t: ProcessTable, _ o: OwnershipMap) -> OverheadStat? {
        var browsers = Set<Int32>()
        var bytes: Bytes = 0
        for (pid, owner) in o.owner {
            guard case .otherChrome(let b) = owner else { continue }
            browsers.insert(b)
            bytes += t.byPid[pid]?.footprint ?? 0
        }
        return browsers.isEmpty ? nil : OverheadStat(count: browsers.count, bytes: bytes)
    }
}
