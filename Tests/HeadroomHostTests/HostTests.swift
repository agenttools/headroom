// Unit tests for headroom-host (framing, relay rules, app.sock checks, probe maths).
// Test target in Package.swift:
//   .testTarget(name: "HeadroomHostTests", dependencies: ["headroom-host", "HeadroomContracts"])
import Darwin
import Foundation
import Testing
import HeadroomContracts
@testable import headroom_host

private func json(_ s: String) -> Data { Data(s.utf8) }
private func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

@Suite struct Framing {
    @Test func roundTripOneByteAtATime() throws {
        let msgs = [json(#"{"t":"ping"}"#), json(#"{"t":"hello","v":1,"mode":"persistent"}"#), Data(), json(String(repeating: "x", count: 70_000))]
        var stream = Data()
        for m in msgs { stream.append(NativeFraming.encode(m)) }
        var dec = NativeFraming.Decoder()
        var out: [Data] = []
        for b in stream {
            dec.push(Data([b]))
            while let m = try dec.next() { out.append(m) }
        }
        #expect(out == msgs)
        #expect(dec.pendingBytes == 0)
    }

    @Test func lengthIsNativeEndian() {
        let f = NativeFraming.encode(json("{}"))
        #expect(Array(f.prefix(4)) == [2, 0, 0, 0]) // arm64 and x86_64 are little-endian
        #expect(f.count == 6)
    }

    @Test func manyMessagesInOneChunk() throws {
        var stream = Data()
        for i in 0..<100 { stream.append(NativeFraming.encode(json(#"{"t":"x","i":\#(i)}"#))) }
        var dec = NativeFraming.Decoder()
        dec.push(stream)
        var n = 0
        while let m = try dec.next() { #expect(obj(m)["i"] as? Int == n); n += 1 }
        #expect(n == 100)
    }

    @Test func oversizeFrameThrows() {
        var dec = NativeFraming.Decoder(limit: 10)
        dec.push(NativeFraming.encode(Data(count: 11)))
        #expect(throws: NativeFraming.FramingError.tooLarge(11)) { try dec.next() }
    }

    @Test func wireTypesSurviveFraming() throws {
        let enc = JSONEncoder()
        let req = Wire.CloseRequest(req: 8, tabs: [.init(id: 123, url: "https://example.com/ü?a=1\nb")])
        var dec = NativeFraming.Decoder()
        dec.push(NativeFraming.encode(try enc.encode(req)))
        let back = try JSONDecoder().decode(Wire.CloseRequest.self, from: try #require(try dec.next()))
        #expect(back == req)
    }

    @Test func lineSplitter() throws {
        var s = LineSplitter()
        #expect(try s.push(json("{\"a\":1}\n{\"b\"")) == [json(#"{"a":1}"#)])
        #expect(try s.push(json(":2}\r\n\n")) == [json(#"{"b":2}"#)])
        #expect(s.pendingBytes == 0)
    }

    @Test func lineSplitterLimit() {
        var s = LineSplitter(limit: 8)
        #expect(throws: NativeFraming.FramingError.self) { try s.push(json("0123456789")) }
    }

    @Test func jsonLineEscapesRawNewlines() throws {
        // Chrome never sends raw newlines inside JSON, but a pretty-printed object must still be one line.
        let pretty = json("{\n  \"t\" : \"dirty\"\n}")
        let line = try #require(JSONLine.line(pretty))
        #expect(line.last == 0x0A)
        #expect(!line.dropLast().contains(0x0A))
        #expect(obj(line.dropLast())["t"] as? String == "dirty")
        #expect(JSONLine.line(json(#"{"t":"dirty"}"#)) == json("{\"t\":\"dirty\"}\n"))
    }
}

@Suite struct RelayRules {
    let hostLine = json("{\"t\":\"host\"}\n")

    @Test func pingIsAnsweredNotForwarded() {
        var r = Router()
        _ = r.appDidConnect(hostLine: hostLine)
        #expect(r.fromExt(Router.ping) == [.toExt(Router.pong)])
        #expect(r.fromExt(Router.pong) == [])
        #expect(r.fromApp(Router.ping) == [])
    }

    @Test func hostLineFirstThenCachedHello() {
        var r = Router()
        let hello = json(#"{"t":"hello","v":1,"mode":"persistent"}"#)
        #expect(r.fromExt(hello) == [.connectNow])        // no app yet: cached, not sent
        let acts = r.appDidConnect(hostLine: hostLine)
        #expect(acts == [.toApp(hostLine), .toApp(hello + json("\n"))])
    }

    @Test func relaysUnchangedBothWays() {
        var r = Router()
        _ = r.appDidConnect(hostLine: hostLine)
        let snap = json(#"{"t":"snapshot","req":7,"tabs":[],"windows":[],"at":1}"#)
        #expect(r.fromExt(snap) == [.toApp(snap + json("\n"))])
        let close = json(#"{"t":"close","req":8,"tabs":[{"id":1,"url":"u"}]}"#)
        #expect(r.fromApp(close) == [.toExt(close)])
    }

    @Test func dropsExtensionMessagesWithoutApp() {
        var r = Router()
        #expect(r.fromExt(json(#"{"t":"dirty"}"#)) == [])
        #expect(r.dropped == 1)
    }

    @Test func persistentStaysWhenAppAbsentOrGone() {
        var r = Router()
        _ = r.fromExt(json(#"{"t":"hello","mode":"persistent"}"#))
        #expect(r.appSocketAbsent() == [])
        _ = r.appDidConnect(hostLine: hostLine)
        #expect(r.appDidDisconnect().allSatisfy { if case .exit = $0 { false } else { true } })
    }

    @Test func onDemandExitsWhenAppAbsentOrGone() {
        var r = Router()
        #expect(r.appSocketAbsent() == [])            // mode unknown until hello: treated as persistent
        _ = r.fromExt(json(#"{"t":"hello","mode":"on-demand"}"#))
        #expect(r.isOnDemand)
        #expect(r.appSocketAbsent().contains { if case .exit = $0 { true } else { false } })
        _ = r.appDidConnect(hostLine: hostLine)
        #expect(r.appDidDisconnect().contains { if case .exit = $0 { true } else { false } })
    }

    @Test func setModeFromAppUpdatesHostAndIsForwarded() {
        var r = Router()
        _ = r.fromExt(json(#"{"t":"hello","mode":"persistent"}"#))
        _ = r.appDidConnect(hostLine: hostLine)
        let m = json(#"{"t":"setMode","mode":"on-demand"}"#)
        #expect(r.fromApp(m) == [.toExt(m)])
        #expect(r.isOnDemand)
    }

    @Test func refusesOversizeToChrome() {
        var r = Router()
        _ = r.appDidConnect(hostLine: hostLine)
        let big = json(#"{"t":"x","pad":""# + String(repeating: "a", count: NativeFraming.maxToChrome) + #""}"#)
        #expect(r.fromApp(big).allSatisfy { if case .toExt = $0 { false } else { true } })
    }

    @Test func hostLineDecodesAsWireHostHello() throws {
        let rt = HostRuntime(env: HeadroomEnv(environment: ["HOME": "/nonexistent"]), browserPid: 4242)
        let line = rt.hostLine()
        #expect(line.last == 0x0A)
        let h = try JSONDecoder().decode(Wire.HostHello.self, from: line.dropLast())
        #expect(h.t == "host" && h.v == Wire.version && h.browserPid == 4242 && h.hostPid == getpid())
    }
}

/// app.sock checks, against a real listening socket in a temporary directory (short path under /tmp's
/// realpath is not needed: the host connects relative to the run directory).
@Suite(.serialized) struct AppSocketChecks {
    func tempRun(mode: mode_t) throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hr-host-\(UUID().uuidString)/some/deliberately/long/path/that/goes/past/the/sun_path/limit/of/one/hundred/and/four/bytes")
        let run = base.appendingPathComponent("run").path
        try FileManager.default.createDirectory(atPath: run, withIntermediateDirectories: true)
        chmod(run, mode)
        return run
    }

    func listen(in dir: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in "app.sock".utf8.enumerated() { p[i] = b } }
        let len = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + 9)
        let cwd = FileManager.default.currentDirectoryPath
        chdir(dir)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        chdir(cwd)
        Darwin.listen(fd, 4)
        return fd
    }

    @Test func absentWhenNoDirectoryOrSocket() throws {
        if case .failure(.absent) = AppSocket.connect(runDir: "/nonexistent/headroom/run") {} else { Issue.record("expected absent") }
        let run = try tempRun(mode: 0o700)
        if case .failure(.absent) = AppSocket.connect(runDir: run) {} else { Issue.record("expected absent") }
    }

    @Test func connectsPastTheSunPathLimit() throws {
        let run = try tempRun(mode: 0o700)
        #expect((run + "/app.sock").utf8.count > 104)
        let lfd = listen(in: run)
        defer { close(lfd) }
        switch AppSocket.connect(runDir: run) {
        case .success(let fd):
            let c = accept(lfd, nil, nil)
            #expect(c >= 0)
            #expect(FD.writeAll(fd, json("{\"t\":\"host\"}\n")))
            #expect(FD.readSome(c) == json("{\"t\":\"host\"}\n"))
            close(c); close(fd)
        case .failure(let f):
            Issue.record("connect failed: \(f)")
        }
    }

    @Test func refusesGroupWritableRunDirectory() throws {
        let run = try tempRun(mode: 0o777)
        let lfd = listen(in: run)
        defer { close(lfd) }
        if case .failure(.unsafe) = AppSocket.connect(runDir: run) {} else { Issue.record("expected unsafe") }
    }

    @Test func refusesNonSocket() throws {
        let run = try tempRun(mode: 0o700)
        FileManager.default.createFile(atPath: run + "/app.sock", contents: Data())
        if case .failure(.unsafe) = AppSocket.connect(runDir: run) {} else { Issue.record("expected unsafe") }
    }

    @Test func refusesSymlinkedSocket() throws {
        let other = try tempRun(mode: 0o700)
        let lfd = listen(in: other)
        defer { close(lfd) }
        let run = try tempRun(mode: 0o700)
        try FileManager.default.createSymbolicLink(atPath: run + "/app.sock", withDestinationPath: other + "/app.sock")
        if case .failure(.unsafe) = AppSocket.connect(runDir: run) {} else { Issue.record("expected unsafe") }
    }

    @Test func staleSocketIsAbsent() throws {
        let run = try tempRun(mode: 0o700)
        let lfd = listen(in: run)
        close(lfd) // socket file stays, nobody listens
        if case .failure(.absent) = AppSocket.connect(runDir: run) {} else { Issue.record("expected absent (refused)") }
    }
}

@Suite struct ProbeMaths {
    func r(_ pid: Int32, _ type: String?, _ cid: Int? = nil, ext: Bool = false, fp: UInt64 = 0) -> RendererInfo {
        RendererInfo(pid: pid, type: type, clientId: cid, isExtension: ext, footprint: fp)
    }

    let renderers: [RendererInfo] = [
        RendererInfo(pid: 10, type: "gpu-process", clientId: nil, isExtension: false, footprint: 1),
        RendererInfo(pid: 11, type: "renderer", clientId: 5, isExtension: false, footprint: 1),
        RendererInfo(pid: 12, type: "renderer", clientId: 7, isExtension: false, footprint: 1),
        RendererInfo(pid: 13, type: "renderer", clientId: 9, isExtension: true, footprint: 1), // extension: not a tab renderer
    ]

    @Test func joinCountsSharedCrossSiteDiscardedAndUnmatched() throws {
        let snap: [String: Any] = ["tabs": [
            ["id": 1, "frames": [["frameId": 0, "processId": 5, "documentLifecycle": "active"],
                                 ["frameId": 3, "processId": 7, "documentLifecycle": "active"]]],   // cross-site iframe
            ["id": 2, "frames": [["frameId": 0, "processId": 5, "documentLifecycle": "active"]]],   // shares renderer 5
            ["id": 3, "discarded": true, "frames": [] as [Any]],
            ["id": 4, "frames": [["frameId": 0, "processId": 99, "documentLifecycle": "active"],     // unknown id
                                 ["frameId": 0, "processId": 7, "documentLifecycle": "cached"]]],   // bfcache
            ["id": 5, "frames": [["frameId": 0, "processId": 9, "documentLifecycle": "active"]]],   // extension id is not a tab renderer
        ]]
        let s = JoinStats.compute(snapshot: snap, renderers: renderers)
        #expect(s.tabs == 5 && s.discarded == 1 && s.tabsWithFrames == 4)
        #expect(s.mainFrameJoined == 2)           // tabs 1 and 2 (tab 4's first frame 0 is 99, tab 5 is 9)
        #expect(s.frames == 6 && s.framesJoined == 4)
        #expect(s.unmatchedProcessIds == [9, 99])
        #expect(s.renderers == 2 && s.renderersWithClientId == 2)
        #expect(s.tabsSharingRenderer == 2)
        #expect(s.lifecycles == ["active": 5, "cached": 1])
        #expect(abs(s.tabJoinRate - 0.5) < 1e-9)
    }

    @Test func noTabsMeansFullRate() {
        let s = JoinStats.compute(snapshot: ["tabs": [] as [Any]], renderers: [])
        #expect(s.tabJoinRate == 1 && s.frameJoinRate == 1)
    }

    @Test func helperFinderPicksTheGrownExtensionProcess() {
        let MB: UInt64 = 1_048_576
        let before: [Int32: UInt64] = [1: 30 * MB, 2: 90 * MB, 3: 20 * MB]
        let after: [Int32: UInt64] = [1: 95 * MB, 2: 100 * MB, 3: 20 * MB, 4: 200 * MB]
        let hit = HelperFinder.find(before: before, after: after, markMB: 64)
        #expect(hit?.pid == 1)
        #expect(HelperFinder.find(before: before, after: before, markMB: 64) == nil)
    }

    func stats(join: Int, of n: Int) -> JoinStats {
        var s = JoinStats(); s.tabs = n; s.tabsWithFrames = n; s.mainFrameJoined = join; s.renderersWithClientId = 1
        return s
    }

    @Test func verdictGoPersistent() {
        let v = ProbeVerdict.decide(snapshots: Array(repeating: stats(join: 30, of: 30), count: 20), elapsed: 610,
                                    pingsSent: 31, pongs: 31, maxPongGap: 20.5, pingInterval: 20, helperMB: 22)
        #expect(v.perTabMemory == "go" && v.defaultMode == "persistent" && v.workerStayedAlive)
    }

    @Test func verdictNoGoOnLowJoinAndOnDemandWhenHeavy() {
        let v = ProbeVerdict.decide(snapshots: [stats(join: 30, of: 30), stats(join: 20, of: 30)], elapsed: 610,
                                    pingsSent: 31, pongs: 31, maxPongGap: 20, pingInterval: 20, helperMB: 55)
        #expect(v.perTabMemory == "no-go" && v.defaultMode == "on-demand")
    }

    @Test func verdictWorkerDiedEarly() {
        let v = ProbeVerdict.decide(snapshots: [stats(join: 3, of: 3)], elapsed: 200,
                                    pingsSent: 10, pongs: 10, maxPongGap: 20, pingInterval: 20, helperMB: nil)
        #expect(!v.workerStayedAlive && v.defaultMode == "unknown")
    }

    @Test func noClientIdsIsNoGo() {
        var s = stats(join: 0, of: 3); s.renderersWithClientId = 0
        let v = ProbeVerdict.decide(snapshots: [s], elapsed: 610, pingsSent: 31, pongs: 31, maxPongGap: 20, pingInterval: 20, helperMB: 20)
        #expect(v.perTabMemory == "no-go")
    }

    @Test func optionsParse() throws {
        let o = try ProbeOptions.parse(["--probe", "--log", "/x/p.log", "--snapshots", "3", "--interval", "1",
                                        "--duration", "5", "--ping", "2", "--mark-mb", "32", "chrome-extension://abc/"]).get()
        #expect(o.logPath == "/x/p.log" && o.snapshots == 3 && o.interval == 1 && o.duration == 5 && o.pingInterval == 2 && o.markMB == 32)
        #expect((try? ProbeOptions.parse(["--snapshots", "0"]).get()) == nil)
        let d = try ProbeOptions.parse([]).get()
        #expect(d.snapshots == 20 && d.duration == 600 && d.pingInterval == 20)
    }
}
