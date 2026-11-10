// `--selftest chrome` (SPEC §8.8). Read-only against the live system:
//   - classifies the main Chrome's processes (no signals);
//   - binds a bridge on a scratch socket and runs a fake host through it (never the real app.sock);
//   - reads the host manifest (never writes it);
//   - checks Automation permission without prompting;
//   - runs the read-only JXA list, only if Chrome is running and permission is already granted;
//   - if the helper is installed and no other Headroom holds app.sock, listens on app.sock for a few seconds and
//     asks the helper for one snapshot (read-only), then stops.
// It never closes, discards, activates or reloads a tab, and never launches Chrome.
//
//     let r = await ChromeSelfTest.run(env: env, sessions: { await services.claude.sessionRecords() })
//     print(r.render()); exit(r.passed ? 0 : 1)

import Darwin
import Foundation
import HeadroomContracts
import HeadroomCore

public enum ChromeSelfTest {
    public static let group = "chrome"

    public static func run(env: HeadroomEnv = .current,
                           sessions: (@Sendable () async -> [SessionRecord])? = nil,
                           helperWait: TimeInterval = 4.5) async -> SelfTestReport {
        var r = SelfTestReport()
        let g = group
        let sys = LiveSysKit(env: env)

        // 1. Processes.
        let t0 = Date()
        let table = sys.scan()
        let recs = await sessions?() ?? []
        let own = Ownership.assign(table, sessions: recs, hosts: [], tmuxPanes: [], sys: sys, env: env)
        let mains = ChromeProcesses.mainBrowserPids(table, own, hostBrowserPids: [])
        let procs = ChromeProcesses.collect(table, own, mainBrowsers: mains, args: { sys.args($0) })
        let owned = own.owner.filter { if case .chrome = $0.value { true } else { false } }.map(\.key)
        let sumOwned = table.footprint(of: owned)
        let sumProcs = procs.reduce(Bytes(0)) { $0 + $1.footprint }
        let renderers = procs.filter { if case .renderer = $0.kind { true } else { false } }
        let withId = renderers.filter { $0.clientId != nil }
        if mains.isEmpty {
            r.add(g, "main browser", true, "Google Chrome is not running (nothing else to check in the process table)")
        } else {
            r.add(g, "main browser", true, "pid \(mains.map(String.init).joined(separator: ", ")); \(procs.count) processes, \(ByteFormat.short(sumProcs))")
            r.add(g, "every Chrome-owned pid is classified once", sumOwned == sumProcs && Set(procs.map(\.key.pid)).count == procs.count,
                  "owned \(ByteFormat.short(sumOwned)) vs classified \(ByteFormat.short(sumProcs))")
            r.add(g, "renderers report --renderer-client-id", !renderers.isEmpty && withId.count == renderers.count,
                  "\(withId.count) of \(renderers.count) renderers")
            var kinds: [String: Int] = [:]
            for p in procs { kinds[p.kind.overheadKind?.rawValue ?? "renderer", default: 0] += 1 }
            r.notes.append("chrome processes: " + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        if let o = ChromeProcesses.otherInstances(table, own) {
            r.notes.append("other Chrome instances (automation, unowned): \(o.count), \(ByteFormat.short(o.bytes))")
        }
        r.notes.append("process pass took \(Int(Date().timeIntervalSince(t0) * 1000)) ms")

        // 2. Socket round trip on a scratch socket.
        r.checks += await socketRoundTrip()

        // 3. Host manifest (read-only).
        let extId = HostManifest.bundleDefaults()?.extensionId
            ?? HostManifest.extensionId(manifestAt: env.extensionDir + "/manifest.json")
        let manifest = HostManifest(env: env)
        let st = manifest.status(hostPath: HostManifest.bundleDefaults()?.hostPath, extensionId: extId ?? "")
        switch st {
        case .missing:
            r.add(g, "host manifest", true, "not installed (\(tilde(manifest.path, env))); per-tab memory needs install.sh")
        case .ok:
            r.add(g, "host manifest", true, "installed and matches extension \(extId ?? "?")")
        case .invalid, .mismatch:
            r.add(g, "host manifest", extId == nil && st.isInstalledFile, extId == nil
                  ? "present; cannot check the id (no extension manifest at \(tilde(env.extensionDir, env)))" : st.description)
        }

        // 4. Automation permission (never prompts).
        let perm = JXAFallback.permission(ask: false)
        r.add(g, "automation permission (no prompt)", perm != .unknown || mains.isEmpty, perm.rawValue)

        // 5. JXA list (read-only), only with permission and a running Chrome.
        let googleMain = mains.filter { ChromeSource.isGoogleChrome(table.byPid[$0]?.path) }
        if googleMain.count == 1 && perm == .granted {
            let t1 = Date()
            let res = await JXAFallback().list()
            let ms = Int(Date().timeIntervalSince(t1) * 1000)
            switch res {
            case .success(let l):
                let ids = l.tabs.map(\.id)
                r.add(g, "JXA list", Set(ids).count == ids.count && ms < 3000,
                      "\(l.windows.count) windows, \(l.tabs.count) tabs in \(ms) ms; tab ids unique")
                // Attribution with the JXA list: per tab "—", overhead ≤ total.
                let tabs = l.tabs.map { ChromeTab(browserPid: googleMain[0], id: $0.id, windowId: $0.windowId, index: $0.index,
                                                  title: $0.title, url: $0.url, host: WireMapping.host(of: $0.url)) }
                let a = Attribution.attribute(procs: procs, tabs: tabs, perTabBrowsers: [],
                                              otherInstances: ChromeProcesses.otherInstances(table, own))
                r.add(g, "attribution (AppleScript mode)", a.tabs.allSatisfy { $0.display == nil } && a.overhead.values.reduce(0) { $0 + $1.bytes } <= a.total,
                      "section \(ByteFormat.short(a.total)), Chrome itself \(ByteFormat.short(a.overhead.values.reduce(0) { $0 + $1.bytes }))")
            case .failure(let f):
                r.add(g, "JXA list", false, f.description)
            }
        } else {
            r.notes.append("JXA list skipped: \(googleMain.count == 1 ? "Automation permission is \(perm.rawValue)" : "Google Chrome is not running")")
        }

        // 6. The helper, through the real app.sock, only if installed and nobody else is listening.
        if st.isInstalledFile, !mains.isEmpty {
            if SocketIO.isLive(env.socketPath) {
                r.notes.append("helper check skipped: another Headroom is listening on app.sock")
            } else {
                var opts = ChromeSource.Options()
                opts.initialHostWait = helperWait
                let src = ChromeSource(env: env, options: opts, jxa: nil)
                let hosts = await src.hosts()
                if hosts.isEmpty {
                    r.add(g, "helper connects", false, "no host connected within \(helperWait) s (is the extension loaded?)")
                } else {
                    let t2 = sys.scan()
                    let o2 = Ownership.assign(t2, sessions: recs, hosts: hosts, tmuxPanes: [], sys: sys, env: env)
                    let snap = await src.snapshot(t2, o2, sys)
                    let d = src.lastDiagnostics
                    let join = d.joinStats.values.reduce((0, 0)) { ($0.0 + $1.tabs, $0.1 + $1.unmatched) }
                    r.add(g, "helper snapshot", snap.source.name == "helper",
                          "\(hosts.count) host(s), \(snap.tabs.count) tabs; \(join.0 - join.1)/\(join.0) main frames joined a renderer")
                    let tabSum = snap.tabs.reduce(Bytes(0)) { $0 + ($1.display ?? 0) }
                    if snap.perTabUnavailable == nil {
                        r.add(g, "tabs + Chrome itself = section total", tabSum + snap.overheadTotal == snap.total,
                              "\(ByteFormat.short(tabSum)) + \(ByteFormat.short(snap.overheadTotal)) vs \(ByteFormat.short(snap.total))")
                    } else {
                        r.add(g, "per-tab memory", false, snap.perTabUnavailable ?? "")
                    }
                }
                src.stop()
            }
        } else if !st.isInstalledFile {
            r.notes.append("helper check skipped: the host manifest is not installed")
        }
        return r
    }

    static func tilde(_ p: String, _ env: HeadroomEnv) -> String {
        p.hasPrefix(env.home + "/") ? "~" + p.dropFirst(env.home.count) : p
    }

    /// Bridge + fake host on a scratch socket: 0700 run dir, 0600 socket, host line, hello, request/reply, stop.
    static func socketRoundTrip() async -> [SelfTestCheck] {
        let g = group
        var dir = Array("\(NSTemporaryDirectory())hr-selftest-XXXXXX".utf8CString)
        guard let p = mkdtemp(&dir) else { return [SelfTestCheck(group: g, name: "socket bind", passed: false, detail: "mkdtemp failed")] }
        let base = String(cString: p)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let sock = base + "/run/app.sock"
        let bridge = ChromeBridge(socketPath: sock)
        do { try bridge.start() } catch {
            return [SelfTestCheck(group: g, name: "socket bind", passed: false, detail: "\(error)")]
        }
        defer { bridge.stop() }
        var st = stat()
        _ = lstat(base + "/run", &st)
        let dirMode = st.st_mode & 0o777
        _ = lstat(sock, &st)
        let sockMode = st.st_mode & 0o777
        var out = [SelfTestCheck(group: g, name: "socket bind", passed: dirMode == 0o700 && sockMode == 0o600,
                                 detail: String(format: "run/ %o, app.sock %o", dirMode, sockMode))]
        guard let host = FakeHost.connect(sock) else {
            out.append(SelfTestCheck(group: g, name: "socket round trip", passed: false, detail: "cannot connect"))
            return out
        }
        defer { host.close() }
        host.sendLine(#"{"t":"host","v":1,"hostPid":\#(getpid()),"browserPid":\#(getppid()),"hostVersion":"selftest"}"#)
        host.sendLine(#"{"t":"hello","v":1,"ext":"selftest","install":"x","incognitoAllowed":false,"mode":"persistent"}"#)
        let conns = await bridge.waitForHosts(timeout: 2)
        guard let c = conns.first else {
            out.append(SelfTestCheck(group: g, name: "socket round trip", passed: false, detail: "host line not accepted"))
            return out
        }
        host.answerSnapshots()
        let res = await bridge.request(c.id) { Wire.SnapshotRequest(req: $0) }
        let ok: Bool
        if case .success(let d) = res, let rep = try? JSONDecoder().decode(Wire.SnapshotReply.self, from: d), rep.tabs.count == 1 { ok = true } else { ok = false }
        out.append(SelfTestCheck(group: g, name: "socket round trip", passed: ok, detail: ok ? "host line, hello, snapshot request/reply" : "\(res)"))
        return out
    }
}

/// A minimal in-process host for the selftest (and tests): connects, writes lines, answers snapshot requests.
final class FakeHost: @unchecked Sendable {
    let fd: Int32
    private var thread: Thread?
    init(fd: Int32) { self.fd = fd }

    static func connect(_ path: String) -> FakeHost? {
        guard let (addr, len) = try? SocketIO.makeAddr(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var a = addr
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) } }
        guard rc == 0 else { Darwin.close(fd); return nil }
        SocketIO.noSigpipe(fd)
        return FakeHost(fd: fd)
    }

    func sendLine(_ s: String) { _ = SocketIO.writeAll(fd, Data((s + "\n").utf8), deadline: Date().addingTimeInterval(2)) }

    /// Answers every `snapshot` request with one tab, on a background thread, until closed.
    func answerSnapshots() {
        serve { t, req, _ in
            guard t == "snapshot", let req else { return nil }
            return #"{"t":"snapshot","req":\#(req),"at":0,"windows":[{"id":1,"focused":true,"incognito":false}],"tabs":[{"id":7,"windowId":1,"index":0,"title":"t","url":"https://example.com/","active":true,"pinned":false,"incognito":false,"frames":[{"frameId":0,"parentFrameId":-1,"processId":3}]}]}"#
        }
    }

    /// Reads lines on a background thread until the socket closes; `respond(t, req, object)` returns the reply
    /// line to send (nil = no reply).
    func serve(_ respond: @escaping @Sendable (String, Int?, [String: Any]) -> String?) {
        let fd = self.fd
        let t = Thread { [weak self] in
            var lb = LineBuffer(maxLine: 32 << 20)
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { return }
                guard let lines = try? lb.push(Data(buf[0..<n])) else { return }
                for l in lines {
                    guard let o = (try? JSONSerialization.jsonObject(with: l)) as? [String: Any], let t = o["t"] as? String else { continue }
                    if let reply = respond(t, o["req"] as? Int, o) { self?.sendLine(reply) }
                }
            }
        }
        thread = t
        t.start()
    }

    func close() { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
}
