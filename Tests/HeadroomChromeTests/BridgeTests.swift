// ChromeBridge (app.sock server) against in-process fake hosts over a real Unix socket.
import Darwin
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomChrome

/// A short scratch directory (sun_path is limited to 104 bytes), removed by `cleanup()`.
struct Scratch {
    let path: String
    init(_ tag: String = "hr") {
        var t = Array("\(NSTemporaryDirectory())\(tag)-XXXXXX".utf8CString)
        path = String(cString: mkdtemp(&t)!)
    }
    var socket: String { path + "/run/app.sock" }
    func cleanup() { try? FileManager.default.removeItem(atPath: path) }
}

func hostLine(hostPid: Int32 = getpid(), browserPid: Int32 = 4242) -> String {
    #"{"t":"host","v":1,"hostPid":\#(hostPid),"browserPid":\#(browserPid),"hostVersion":"test"}"#
}
let helloLine = #"{"t":"hello","v":1,"ext":"1.0.0","install":"abc","incognitoAllowed":false,"mode":"persistent"}"#

func until(_ timeout: TimeInterval = 2, _ f: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if f() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return f()
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ChromeBridge.Event] = []
    func add(_ e: ChromeBridge.Event) { lock.withLock { items.append(e) } }
    var all: [ChromeBridge.Event] { lock.withLock { items } }
    func count(_ f: (ChromeBridge.Event) -> Bool) -> Int { all.filter(f).count }
}

@Suite(.serialized) struct BridgeTests {
    func opts(timeout: TimeInterval = 3, hello: TimeInterval = 3) -> ChromeBridge.Options {
        var o = ChromeBridge.Options(); o.requestTimeout = timeout; o.helloTimeout = hello; return o
    }

    @Test func bindsWithPrivateModesAndRemovesSocketOnStop() throws {
        let s = Scratch(); defer { s.cleanup() }
        let b = ChromeBridge(socketPath: s.socket)
        try b.start()
        var st = stat()
        #expect(lstat(s.path + "/run", &st) == 0 && st.st_mode & 0o777 == 0o700)
        #expect(lstat(s.socket, &st) == 0 && st.st_mode & S_IFMT == S_IFSOCK && st.st_mode & 0o777 == 0o600)
        #expect(b.isRunning)
        b.stop()
        #expect(!FileManager.default.fileExists(atPath: s.socket))
        #expect(!b.isRunning)
    }

    @Test func tightensAnExistingRunDirTo0700() throws {
        let s = Scratch(); defer { s.cleanup() }
        try FileManager.default.createDirectory(atPath: s.path + "/run", withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let b = ChromeBridge(socketPath: s.socket)
        try b.start(); defer { b.stop() }
        var st = stat()
        #expect(lstat(s.path + "/run", &st) == 0 && st.st_mode & 0o777 == 0o700)
    }

    @Test func refusesASymlinkedRunDir() throws {
        let s = Scratch(); defer { s.cleanup() }
        try FileManager.default.createDirectory(atPath: s.path + "/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: s.path + "/run", withDestinationPath: s.path + "/elsewhere")
        let b = ChromeBridge(socketPath: s.socket)
        #expect(throws: ChromeBridge.BridgeError.self) { try b.start() }
    }

    @Test func replacesStaleSocketButNotALiveOne() throws {
        let s = Scratch(); defer { s.cleanup() }
        let a = ChromeBridge(socketPath: s.socket)
        try a.start()
        let b = ChromeBridge(socketPath: s.socket)
        do { try b.start(); Issue.record("second start should fail") } catch let e as ChromeBridge.BridgeError {
            #expect(e.inUse)
        }
        // Simulate a crash: close the listener without unlinking → a stale file nobody listens on.
        a.stop()
        let (fd, _) = try SocketIO.listen(s.socket)
        close(fd)  // file remains, nobody listening
        #expect(FileManager.default.fileExists(atPath: s.socket))
        try b.start(); defer { b.stop() }
        #expect(b.isRunning)
        // A regular file at the socket path is never deleted.
        b.stop()
        FileManager.default.createFile(atPath: s.socket, contents: Data("x".utf8))
        #expect(throws: ChromeBridge.BridgeError.self) { try b.start() }
        #expect(FileManager.default.fileExists(atPath: s.socket))
    }

    @Test func pathTooLongIsAnError() {
        let b = ChromeBridge(socketPath: "/tmp/" + String(repeating: "x", count: 120) + "/app.sock")
        #expect(throws: ChromeBridge.BridgeError.self) { try b.start() }
    }

    @Test func hostLineThenHelloThenRequestReply() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let b = ChromeBridge(socketPath: s.socket, options: opts())
        let log = EventLog()
        b.setEventHandler { log.add($0) }
        try b.start(); defer { b.stop() }
        let h = try #require(FakeHost.connect(s.socket)); defer { h.close() }
        h.sendLine(hostLine())
        h.sendLine(helloLine)
        #expect(await until { b.connections().first?.ext != nil })
        let c = b.connections()[0]
        #expect(c.host.hostPid == getpid() && c.browserPid == 4242 && c.ext?.mode == "persistent")
        h.answerSnapshots()
        let res = await b.request(c.id) { Wire.SnapshotRequest(req: $0) }
        let d = try res.get()
        let rep = try JSONDecoder().decode(Wire.SnapshotReply.self, from: d)
        #expect(rep.tabs.first?.id == 7)
        #expect(await until { log.count { if case .connected = $0 { true } else { false } } == 1 })
        #expect(log.count { if case .hello = $0 { true } else { false } } == 1)
        h.sendLine(#"{"t":"dirty"}"#)
        #expect(await until { log.count { if case .dirty(_, 4242) = $0 { true } else { false } } == 1 })
    }

    @Test func requestsMatchByReqEvenOutOfOrder() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let b = ChromeBridge(socketPath: s.socket, options: opts())
        try b.start(); defer { b.stop() }
        let h = try #require(FakeHost.connect(s.socket)); defer { h.close() }
        h.sendLine(hostLine())
        #expect(await until { !b.connections().isEmpty })
        // The host holds the first request and answers it after the second.
        let held = LockedBox<Int?>(nil)
        h.serve { t, req, o in
            guard t == "discard", let req else { return nil }
            let ids = o["tabIds"] as? [Int] ?? []
            if ids == [1] { held.set(req); return nil }
            var out = #"{"t":"result","req":\#(req),"results":{"2":"done"}}"#
            if let first = held.get() { out += "\n" + #"{"t":"result","req":\#(first),"results":{"1":"gone"}}"# }
            return out
        }
        let cid = b.connections()[0].id
        async let r1 = b.request(cid) { Wire.DiscardRequest(req: $0, tabIds: [1]) }
        try await Task.sleep(for: .milliseconds(100))
        async let r2 = b.request(cid) { Wire.DiscardRequest(req: $0, tabIds: [2]) }
        let (a, c) = await (r1, r2)
        let ra = try JSONDecoder().decode(Wire.ResultReply.self, from: try a.get())
        let rc = try JSONDecoder().decode(Wire.ResultReply.self, from: try c.get())
        #expect(ra.results == ["1": "gone"])
        #expect(rc.results == ["2": "done"])
    }

    @Test func requestTimesOutAndLateReplyIsIgnored() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let b = ChromeBridge(socketPath: s.socket, options: opts(timeout: 0.3))
        try b.start(); defer { b.stop() }
        let h = try #require(FakeHost.connect(s.socket)); defer { h.close() }
        h.sendLine(hostLine())
        #expect(await until { !b.connections().isEmpty })
        let t0 = Date()
        let r = await b.request(b.connections()[0].id) { Wire.SnapshotRequest(req: $0) }
        #expect(r == .failure(.timeout))
        #expect(Date().timeIntervalSince(t0) < 1.5)
        h.sendLine(#"{"t":"snapshot","req":1,"at":0,"windows":[],"tabs":[]}"#)  // late: must not crash
        try await Task.sleep(for: .milliseconds(100))
        #expect(b.connections().count == 1)
    }

    @Test func defaultTimeoutIsThreeSeconds() {
        #expect(ChromeBridge.Options().requestTimeout == 3)
    }

    @Test func disconnectFailsPendingRequests() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let b = ChromeBridge(socketPath: s.socket, options: opts(timeout: 5))
        let log = EventLog()
        b.setEventHandler { log.add($0) }
        try b.start(); defer { b.stop() }
        let h = try #require(FakeHost.connect(s.socket))
        h.sendLine(hostLine())
        #expect(await until { !b.connections().isEmpty })
        let cid = b.connections()[0].id
        async let r = b.request(cid) { Wire.SnapshotRequest(req: $0) }
        try await Task.sleep(for: .milliseconds(100))
        h.close()
        #expect(await r == .failure(.disconnected))
        #expect(await until { b.connections().isEmpty })
        #expect(await until { log.count { if case .disconnected(_, 4242) = $0 { true } else { false } } == 1 })
        #expect(await b.request(cid) { Wire.SnapshotRequest(req: $0) } == .failure(.notConnected))
    }

    @Test func manyHostsAreIndependent() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let b = ChromeBridge(socketPath: s.socket, options: opts())
        try b.start(); defer { b.stop() }
        var hosts: [FakeHost] = []
        for i in 0..<3 {
            let h = try #require(FakeHost.connect(s.socket))
            h.sendLine(hostLine(browserPid: 1000 + Int32(i % 2)))
            let n = i
            h.serve { t, req, _ in
                guard t == "snapshot", let req else { return nil }
                return #"{"t":"snapshot","req":\#(req),"at":0,"windows":[],"tabs":[{"id":\#(n),"windowId":1,"index":0,"active":false,"pinned":false,"incognito":false}]}"#
            }
            hosts.append(h)
        }
        defer { hosts.forEach { $0.close() } }
        #expect(await until { b.connections().count == 3 })
        #expect(b.connections(browserPid: 1000).count == 2 && b.connections(browserPid: 1001).count == 1)
        var got: [Int] = []
        for c in b.connections() {
            let d = try await b.request(c.id) { Wire.SnapshotRequest(req: $0) }.get()
            got += try JSONDecoder().decode(Wire.SnapshotReply.self, from: d).tabs.map(\.id)
        }
        #expect(got.sorted() == [0, 1, 2])
    }

    @Test func refusesConnectionsWithoutAHostLine() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let b = ChromeBridge(socketPath: s.socket, options: opts(hello: 0.3))
        let log = EventLog()
        b.setEventHandler { log.add($0) }
        try b.start(); defer { b.stop() }
        // 1. Silent client: dropped after helloTimeout.
        let silent = try #require(FakeHost.connect(s.socket)); defer { silent.close() }
        // 2. Wrong first line.
        let wrong = try #require(FakeHost.connect(s.socket)); defer { wrong.close() }
        wrong.sendLine(helloLine)
        // 3. hostPid does not match the peer's pid.
        let liar = try #require(FakeHost.connect(s.socket)); defer { liar.close() }
        liar.sendLine(hostLine(hostPid: 1))
        #expect(await until { log.count { if case .refused = $0 { true } else { false } } == 3 })
        #expect(b.connections().isEmpty)
        let reasons = log.all.compactMap { if case .refused(let r) = $0 { r } else { nil } }
        #expect(reasons.contains { $0.contains("no host line") })
        #expect(reasons.contains { $0.contains("not a host line") })
        #expect(reasons.contains { $0.contains("claims pid 1") })
    }

    @Test func junkAndOversizeLines() async throws {
        let s = Scratch(); defer { s.cleanup() }
        var o = opts(); o.maxLine = 4096
        let b = ChromeBridge(socketPath: s.socket, options: o)
        try b.start(); defer { b.stop() }
        let h = try #require(FakeHost.connect(s.socket)); defer { h.close() }
        h.sendLine(hostLine())
        h.sendLine("not json")
        h.sendLine(#"{"t":"unknownType","x":1}"#)
        h.sendLine("")
        #expect(await until { b.connections().count == 1 })
        h.sendLine(#"{"t":"hello","pad":""# + String(repeating: "x", count: 5000) + #""}"#)
        #expect(await until { b.connections().isEmpty })
    }

    @Test func sendWithoutReply() async throws {
        let s = Scratch(); defer { s.cleanup() }
        let b = ChromeBridge(socketPath: s.socket, options: opts())
        try b.start(); defer { b.stop() }
        let h = try #require(FakeHost.connect(s.socket)); defer { h.close() }
        h.sendLine(hostLine())
        let seen = LockedBox<[String]>([])
        h.serve { t, _, o in seen.set(seen.get() + [t + ":" + ((o["mode"] as? String) ?? "")]); return nil }
        #expect(await until { !b.connections().isEmpty })
        #expect(b.send(b.connections()[0].id, Wire.SetMode(mode: "on-demand")))
        #expect(b.send(b.connections()[0].id, Wire.Bare.reload))
        #expect(await until { seen.get() == ["setMode:on-demand", "reload:"] })
        #expect(!b.send(999, Wire.Bare.reload))
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func get() -> T { lock.withLock { v } }
    func set(_ n: T) { lock.withLock { v = n } }
}
