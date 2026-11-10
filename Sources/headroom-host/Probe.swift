// `headroom-host --probe`: the Spike S probe (SPEC §10, docs/spike-s.md).
//
// Chrome starts it exactly like the real host (through a native-messaging manifest that points at a
// small wrapper script). It then, for about 10 minutes:
//   - logs the browserPid (getppid) and what that process is;
//   - asks the extension for `snapshots` snapshots, one every `interval` seconds;
//   - joins every frame's processId to the `--renderer-client-id=N` renderers of that browser;
//   - pings the extension every 20 s and records every pong (is the MV3 worker still alive?);
//   - finds the helper's own extension process (it asks the worker to hold `mark-mb` MiB for a moment
//     and looks for the extension renderer that grew) and samples its footprint;
//   - writes a go/no-go summary.
//
// Read-only: it sends only `ping`, `snapshot` and `probeMark` (the worker allocating memory in
// itself). It never connects to app.sock, never closes, discards or activates a tab. It writes only to
// the log file (and `<log>.summary.json`). URLs and titles are never logged: only counts and ids.

import Darwin
import Foundation
import HeadroomContracts

struct ProbeOptions: Sendable, Equatable {
    var logPath: String = NSTemporaryDirectory() + "headroom-probe.log"
    var snapshots = 20
    var interval: TimeInterval = 30
    var pingInterval: TimeInterval = 20
    var markMB = 64
    /// Minimum run time before the summary: the worker must stay alive this long (SPEC §10: 10 min).
    var duration: TimeInterval = 600

    struct ParseError: Error { let message: String }

    static func parse(_ args: [String]) -> Result<ProbeOptions, ParseError> {
        var o = ProbeOptions()
        let env = ProcessInfo.processInfo.environment
        if let p = env["HEADROOM_PROBE_LOG"], !p.isEmpty { o.logPath = p }
        var i = 0
        func value(_ name: String) -> String? {
            guard i + 1 < args.count else { return nil }
            i += 1
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--probe": break
            case "--log":
                guard let v = value(a) else { return .failure(.init(message: "--log needs a file")) }
                o.logPath = v
            case "--snapshots":
                guard let v = value(a).flatMap(Int.init), v >= 1 else { return .failure(.init(message: "--snapshots needs N ≥ 1")) }
                o.snapshots = v
            case "--interval":
                guard let v = value(a).flatMap(Double.init), v >= 0.5 else { return .failure(.init(message: "--interval needs SEC ≥ 0.5")) }
                o.interval = v
            case "--ping":
                guard let v = value(a).flatMap(Double.init), v >= 0.5 else { return .failure(.init(message: "--ping needs SEC ≥ 0.5")) }
                o.pingInterval = v
            case "--duration":
                guard let v = value(a).flatMap(Double.init), v >= 1 else { return .failure(.init(message: "--duration needs SEC ≥ 1")) }
                o.duration = v
            case "--mark-mb":
                guard let v = value(a).flatMap(Int.init), (0...256).contains(v) else { return .failure(.init(message: "--mark-mb needs 0…256")) }
                o.markMB = v
            default:
                break // Chrome appends the extension origin; ignore anything else
            }
            i += 1
        }
        return .success(o)
    }
}

/// A Chrome child process as the probe sees it.
struct RendererInfo: Sendable, Equatable {
    var pid: Int32
    var type: String?          // --type value; nil for the browser itself
    var clientId: Int?         // --renderer-client-id
    var isExtension: Bool      // --extension-process
    var footprint: UInt64
}

/// The processId ↔ --renderer-client-id join for one snapshot. Pure, so it is unit tested.
struct JoinStats: Sendable, Equatable, Codable {
    var tabs = 0
    var discarded = 0
    var tabsWithFrames = 0
    var mainFrameJoined = 0      // tabs whose frame 0 processId matched a renderer
    var frames = 0               // frames with processId > 0
    var framesJoined = 0
    var renderers = 0            // --type=renderer, not extension
    var renderersWithClientId = 0
    var distinctProcessIds = 0
    var unmatchedProcessIds: [Int] = []
    var lifecycles: [String: Int] = [:]
    var tabsSharingRenderer = 0  // tabs whose main-frame renderer also hosts another tab's main frame

    /// Share of non-discarded tabs whose main frame joined. 1 when there are none.
    var tabJoinRate: Double { tabsWithFrames == 0 ? 1 : Double(mainFrameJoined) / Double(tabsWithFrames) }
    var frameJoinRate: Double { frames == 0 ? 1 : Double(framesJoined) / Double(frames) }

    static func compute(snapshot: [String: Any], renderers: [RendererInfo]) -> JoinStats {
        var s = JoinStats()
        let web = renderers.filter { $0.type == "renderer" && !$0.isExtension }
        s.renderers = web.count
        s.renderersWithClientId = web.filter { $0.clientId != nil }.count
        let clientIds = Set(web.compactMap(\.clientId))
        let tabs = snapshot["tabs"] as? [[String: Any]] ?? []
        s.tabs = tabs.count
        var all = Set<Int>(), unmatched = Set<Int>()
        var mainProcUsers: [Int: Int] = [:]
        for t in tabs {
            if (t["discarded"] as? Bool) == true { s.discarded += 1 }
            let frames = t["frames"] as? [[String: Any]] ?? []
            let live = frames.filter { (($0["processId"] as? NSNumber)?.intValue ?? 0) > 0 }
            if !live.isEmpty { s.tabsWithFrames += 1 }
            for f in live {
                let pid = (f["processId"] as? NSNumber)?.intValue ?? 0
                s.frames += 1
                all.insert(pid)
                let lc = f["documentLifecycle"] as? String ?? "unknown"
                s.lifecycles[lc, default: 0] += 1
                if clientIds.contains(pid) { s.framesJoined += 1 } else { unmatched.insert(pid) }
            }
            if let main = live.first(where: { (($0["frameId"] as? NSNumber)?.intValue ?? -1) == 0 }),
               let pid = (main["processId"] as? NSNumber)?.intValue {
                if clientIds.contains(pid) { s.mainFrameJoined += 1 }
                mainProcUsers[pid, default: 0] += 1
            }
        }
        s.distinctProcessIds = all.count
        s.unmatchedProcessIds = unmatched.sorted()
        s.tabsSharingRenderer = mainProcUsers.values.filter { $0 > 1 }.reduce(0, +)
        return s
    }
}

/// Which extension renderer grew by about `markMB` while the worker held its ballast. Pure.
enum HelperFinder {
    static func find(before: [Int32: UInt64], after: [Int32: UInt64], markMB: Int) -> (pid: Int32, grewBy: UInt64)? {
        let need = UInt64(markMB) * 1024 * 1024 * 3 / 4
        var best: (Int32, UInt64)?
        for (pid, a) in after {
            guard let b = before[pid], a > b else { continue }
            let d = a - b
            if d >= need, d > (best?.1 ?? 0) { best = (pid, d) }
        }
        return best.map { (pid: $0.0, grewBy: $0.1) }
    }
}

struct ProbeVerdict: Codable, Sendable, Equatable {
    var perTabMemory: String       // "go" | "no-go"
    var defaultMode: String        // "persistent" | "on-demand" | "unknown"
    var workerStayedAlive: Bool
    var reasons: [String]

    static let joinThreshold = 0.8          // SPEC §4.4: degraded when > 20% of processIds find no match
    static let helperLimitMB: Double = 40   // SPEC §2: above 40 MB, on-demand becomes the default
    static let aliveSeconds: TimeInterval = 600

    static func decide(snapshots: [JoinStats], elapsed: TimeInterval, pingsSent: Int, pongs: Int,
                       maxPongGap: TimeInterval, pingInterval: TimeInterval, helperMB: Double?,
                       requiredAlive: TimeInterval = aliveSeconds) -> ProbeVerdict {
        var reasons: [String] = []
        let withTabs = snapshots.filter { $0.tabsWithFrames > 0 }
        let anyClientIds = snapshots.contains { $0.renderersWithClientId > 0 }
        let meanJoin = withTabs.isEmpty ? 0 : withTabs.map(\.tabJoinRate).reduce(0, +) / Double(withTabs.count)
        let minJoin = withTabs.map(\.tabJoinRate).min() ?? 0
        var perTab = "go"
        if snapshots.isEmpty { perTab = "no-go"; reasons.append("no snapshot arrived from the extension") }
        else if withTabs.isEmpty { perTab = "no-go"; reasons.append("no snapshot had a tab with frames") }
        else if !anyClientIds { perTab = "no-go"; reasons.append("no renderer has --renderer-client-id") }
        else if minJoin < joinThreshold {
            perTab = "no-go"
            reasons.append(String(format: "tab join rate fell to %.0f%% (need ≥ %.0f%% in every snapshot)", minJoin * 100, joinThreshold * 100))
        } else {
            reasons.append(String(format: "tab join rate: mean %.1f%%, min %.1f%% over %d snapshots", meanJoin * 100, minJoin * 100, withTabs.count))
        }
        let alive = elapsed >= requiredAlive && pongs >= pingsSent - 1 && maxPongGap <= pingInterval * 2 + 5
        reasons.append(String(format: "worker: %.0f s connected, %d/%d pongs, longest gap %.0f s", elapsed, pongs, pingsSent, maxPongGap))
        var mode = "unknown"
        if let mb = helperMB {
            mode = mb > helperLimitMB ? "on-demand" : "persistent"
            reasons.append(String(format: "helper extension process: %.1f MB (limit %.0f MB)", mb, helperLimitMB))
        } else {
            reasons.append("helper extension process not identified; mode stays persistent until measured")
        }
        if !alive { reasons.append("worker keepalive not proven for \(Int(requiredAlive)) s") }
        return ProbeVerdict(perTabMemory: perTab, defaultMode: mode, workerStayedAlive: alive, reasons: reasons)
    }
}

final class ProbeRuntime: @unchecked Sendable {
    let o: ProbeOptions
    let browserPid: pid_t = getppid()
    private let q = DispatchQueue(label: "dev.adder.headroom.probe")
    private var log: FileHandle?
    private let started = Date()
    private var req = 1000
    private var pending: [Int: String] = [:]
    private var stats: [JoinStats] = []
    private var pingsSent = 0, pongs = 0
    private var lastPong: Date?
    private var maxPongGap: TimeInterval = 0
    private var outstandingPing: Date?
    private var helperPid: Int32?
    private var helperBaseline: UInt64?
    private var helperSamples: [UInt64] = []
    private var markBefore: [Int32: UInt64] = [:]
    private var extHello: [String: Any]?
    private var finished = false
    private var timers: [DispatchSourceTimer] = []

    init(options: ProbeOptions) { o = options }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        Log.enabled = false // stderr goes to Chrome's stderr; the probe logs to its file only
        openLog()
        header()
        startStdin()
        q.async { self.ping() }
        timers.append(repeating(o.pingInterval, first: o.pingInterval) { self.ping() })
        timers.append(repeating(o.interval, first: min(2, o.interval)) { self.requestSnapshot() })
        dispatchMain()
    }

    // MARK: logging

    private func openLog() {
        let dir = (o.logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: o.logPath) {
            FileManager.default.createFile(atPath: o.logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        log = FileHandle(forWritingAtPath: o.logPath)
        _ = try? log?.seekToEnd()
    }

    private func w(_ s: String) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let line = String(format: "%@ +%6.1fs %@\n", ts, Date().timeIntervalSince(started), s)
        log?.write(Data(line.utf8))
    }

    private func header() {
        let argv = Proc.args(browserPid)
        let path = Proc.path(browserPid) ?? "?"
        let type = Proc.flag(argv, "--type")
        let udd = Proc.flag(argv, "--user-data-dir") ?? "(default)"
        w("==== headroom-host --probe \(HeadroomIDs.version) (wire v\(Wire.version)) pid \(getpid())")
        w("options: snapshots=\(o.snapshots) interval=\(o.interval)s ping=\(o.pingInterval)s duration=\(o.duration)s mark=\(o.markMB)MiB log=\(o.logPath)")
        w("origin arg: \(CommandLine.arguments.dropFirst().first { $0.hasPrefix("chrome-extension://") } ?? "(none)")")
        w("browserPid (getppid): \(browserPid)")
        w("  path: \(path)")
        w("  chrome version: \(chromeVersion(path) ?? "?")")
        w("  is a browser process (no --type): \(type == nil ? "yes" : "NO, --type=\(type!)")")
        w("  user-data-dir: \(udd)")
        w("  footprint: \(mb(Proc.footprint(browserPid)))")
    }

    private func chromeVersion(_ exe: String) -> String? {
        // …/Foo.app/Contents/MacOS/Foo → …/Foo.app/Contents/Info.plist
        let contents = ((exe as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        guard let d = NSDictionary(contentsOfFile: contents + "/Info.plist") else { return nil }
        return d["CFBundleShortVersionString"] as? String
    }

    private func mb(_ b: UInt64?) -> String { b.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "?" }

    // MARK: stdio

    private func send(_ o: [String: Any]) {
        let d = JSONLine.encode(o)
        if !FD.writeAll(STDOUT_FILENO, NativeFraming.encode(d)) { q.async { self.end("stdout closed") } }
    }

    private func startStdin() {
        let t = Thread { [self] in
            var dec = NativeFraming.Decoder()
            while true {
                let chunk = FD.readSome(STDIN_FILENO)
                if chunk.isEmpty { q.sync { self.end("stdin closed (Chrome closed the port or quit)") } }
                dec.push(chunk)
                do {
                    while let msg = try dec.next() { q.async { self.onMessage(msg) } }
                } catch {
                    q.sync { self.end("bad frame from Chrome: \(error)") }
                }
            }
        }
        t.name = "stdin"
        t.start()
    }

    private func repeating(_ every: TimeInterval, first: TimeInterval, _ body: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + first, repeating: every, leeway: .milliseconds(200))
        t.setEventHandler(handler: body)
        t.resume()
        return t
    }

    // MARK: protocol (q only)

    private func ping() {
        if let out = outstandingPing, !finished {
            w(String(format: "ping unanswered after %.1f s", Date().timeIntervalSince(out)))
        }
        pingsSent += 1
        outstandingPing = Date()
        send(["t": "ping"])
    }

    private func nextReq(_ kind: String) -> Int {
        req += 1
        pending[req] = kind
        return req
    }

    private func requestSnapshot() {
        guard !finished else { return }
        if stats.count >= o.snapshots { return }
        send(["t": "snapshot", "req": nextReq("snapshot")])
    }

    private func onMessage(_ d: Data) {
        guard let m = JSONLine.object(d), let t = m["t"] as? String else { w("non-object message (\(d.count) bytes)"); return }
        switch t {
        case "ping":
            send(["t": "pong"])
        case "pong":
            let now = Date()
            maxPongGap = max(maxPongGap, now.timeIntervalSince(lastPong ?? started))
            lastPong = now
            pongs += 1
            if let out = outstandingPing {
                if !finished { w(String(format: "pong %d (%.0f ms)", pongs, now.timeIntervalSince(out) * 1000)) }
                outstandingPing = nil
            }
        case "hello":
            extHello = m
            w("hello: ext \(m["ext"] ?? "?") mode \(m["mode"] ?? "?") incognitoAllowed \(m["incognitoAllowed"] ?? "?") swStart \(m["swStart"] ?? "?")")
        case "snapshot":
            pending[(m["req"] as? NSNumber)?.intValue ?? -1] = nil
            onSnapshot(m, bytes: d.count)
        case "result":
            let r = (m["req"] as? NSNumber)?.intValue ?? -1
            let kind = pending.removeValue(forKey: r)
            if kind == "mark" { markHeld() }
            else if kind == "unmark" { w("probeMark released") }
            else { w("result for req \(r) (\(kind ?? "unknown"))") }
        case "dirty":
            break
        default:
            w("message t=\(t)")
        }
    }

    private func chromeChildren() -> [RendererInfo] {
        Proc.descendants(of: browserPid).map { pid in
            let argv = Proc.args(pid)
            return RendererInfo(pid: pid, type: Proc.flag(argv, "--type"),
                                clientId: Proc.flag(argv, "--renderer-client-id").flatMap(Int.init),
                                isExtension: argv.contains("--extension-process"),
                                footprint: Proc.footprint(pid) ?? 0)
        }
    }

    private func onSnapshot(_ m: [String: Any], bytes: Int) {
        let kids = chromeChildren()
        let s = JoinStats.compute(snapshot: m, renderers: kids)
        stats.append(s)
        let wins = (m["windows"] as? [Any])?.count ?? 0
        let lc = s.lifecycles.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        w(String(format: "snapshot %d/%d: %d bytes, %d windows, %d tabs (%d discarded), tab join %d/%d (%.0f%%), frame join %d/%d, renderers %d (with client id %d), shared main renderers %d, lifecycles [%@]%@",
                 stats.count, o.snapshots, bytes, wins, s.tabs, s.discarded, s.mainFrameJoined, s.tabsWithFrames,
                 s.tabJoinRate * 100, s.framesJoined, s.frames, s.renderers, s.renderersWithClientId,
                 s.tabsSharingRenderer, lc,
                 s.unmatchedProcessIds.isEmpty ? "" : ", unmatched processIds \(s.unmatchedProcessIds.prefix(20).map(String.init).joined(separator: ","))"))
        let ext = kids.filter(\.isExtension)
        if let h = helperPid {
            if let f = kids.first(where: { $0.pid == h })?.footprint {
                helperSamples.append(f)
                w("helper extension process \(h): \(mb(f)); all extension processes: \(ext.count), \(mb(ext.map(\.footprint).reduce(0, +)))")
            } else {
                w("helper extension process \(h) is gone (the worker's process was replaced)")
                helperPid = nil
            }
        }
        if stats.count == 1 && o.markMB > 0 {
            markBefore = Dictionary(ext.map { ($0.pid, $0.footprint) }, uniquingKeysWith: { a, _ in a })
            w("marking: asking the worker to hold \(o.markMB) MiB; \(ext.count) extension processes before")
            send(["t": "probeMark", "req": nextReq("mark"), "mb": o.markMB])
        }
        if stats.count == o.snapshots {
            let wait = o.duration - Date().timeIntervalSince(started)
            if wait <= 0 { summary(complete: true) }
            else {
                w(String(format: "all snapshots taken; summary in %.0f s (after %.0f s of keepalive)", wait, o.duration))
                q.asyncAfter(deadline: .now() + wait) { self.summary(complete: true) }
            }
        }
    }

    private func markHeld() {
        q.asyncAfter(deadline: .now() + 1.5) {
            let after = Dictionary(self.chromeChildren().filter(\.isExtension).map { ($0.pid, $0.footprint) },
                                   uniquingKeysWith: { a, _ in a })
            if let hit = HelperFinder.find(before: self.markBefore, after: after, markMB: self.o.markMB) {
                self.helperPid = hit.pid
                self.helperBaseline = self.markBefore[hit.pid]
                self.w("helper extension process is pid \(hit.pid): \(self.mb(self.helperBaseline)) before the mark, grew by \(self.mb(hit.grewBy))")
            } else {
                self.w("could not identify the helper's extension process (no extension renderer grew by ~\(self.o.markMB) MiB)")
            }
            self.send(["t": "probeMark", "req": self.nextReq("unmark"), "mb": 0])
        }
    }

    private func summary(complete: Bool) {
        guard !finished else { return }
        finished = true
        let elapsed = Date().timeIntervalSince(started)
        // Median of the samples taken after the mark was released, else the pre-mark baseline.
        let later = helperSamples.dropFirst().sorted()
        let helperBytes: UInt64? = later.isEmpty ? helperBaseline : later[later.count / 2]
        let helperMB = helperBytes.map { Double($0) / 1_048_576 }
        let v = ProbeVerdict.decide(snapshots: stats, elapsed: elapsed, pingsSent: pingsSent, pongs: pongs,
                                    maxPongGap: maxPongGap, pingInterval: o.pingInterval, helperMB: helperMB,
                                    requiredAlive: o.duration)
        w("==== SUMMARY (\(complete ? "complete" : "INCOMPLETE"))")
        w("per-tab memory in v1: \(v.perTabMemory.uppercased())")
        w("default helper mode: \(v.defaultMode)")
        w("worker stayed alive: \(v.workerStayedAlive ? "yes" : "NO")")
        for r in v.reasons { w("  - \(r)") }
        w("host footprint: \(mb(Proc.footprint(getpid())))")
        let json: [String: Any] = [
            "complete": complete, "elapsedSec": Int(elapsed), "browserPid": Int(browserPid),
            "chromeVersion": chromeVersion(Proc.path(browserPid) ?? "") ?? "?",
            "snapshots": stats.count, "pingsSent": pingsSent, "pongs": pongs, "maxPongGapSec": Int(maxPongGap),
            "meanTabJoinRate": stats.isEmpty ? 0 : stats.map(\.tabJoinRate).reduce(0, +) / Double(stats.count),
            "minTabJoinRate": stats.map(\.tabJoinRate).min() ?? 0,
            "helperPid": helperPid.map(Int.init) as Any, "helperMB": helperMB as Any,
            "helperBaselineMB": helperBaseline.map { Double($0) / 1_048_576 } as Any,
            "hostMB": Double(Proc.footprint(getpid()) ?? 0) / 1_048_576,
            "verdict": ["perTabMemory": v.perTabMemory, "defaultMode": v.defaultMode,
                        "workerStayedAlive": v.workerStayedAlive, "reasons": v.reasons],
            "extHello": (extHello ?? [:]).filter { $0.key != "install" },
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: o.logPath + ".summary.json", contents: d, attributes: [.posixPermissions: 0o600])
        }
        w("summary written to \(o.logPath).summary.json; the probe now idles (answers pings, logs nothing more)")
    }

    private func end(_ why: String) -> Never {
        w("exiting: \(why)")
        if !finished { summary(complete: false) }
        exit(0)
    }
}
