// ChromeBridge: the app side of the helper protocol (SPEC §2, §4.2; docs/protocol.md).
//
// The app is the Unix-socket SERVER on `HeadroomEnv.socketPath` (run/ is mode 0700). Every Chrome profile
// with the helper extension starts one headroom-host, which connects here. For each accepted connection:
//   - getpeereid() must return our uid (else the connection is closed at once);
//   - the first line must be the host line `{"t":"host",…}` within `helloTimeout`, and its hostPid must be
//     the peer's pid (LOCAL_PEERPID) when `verifyPeerPid` is on;
//   - then the extension's `hello` (replayed by the host), `dirty`, and replies to our requests arrive.
// Requests carry a bridge-wide increasing `req`; a reply is matched by (connection, req). A request that
// gets no reply in `requestTimeout` (3 s) fails with .timeout; a disconnect fails its pending requests.
//
// Threading: all state is behind `lock`. Reads run on DispatchSources on `ioQueue`; writes run on one
// serial queue per connection, so a slow host never blocks another. Events are delivered on `eventQueue`.

import Darwin
import Foundation
import HeadroomContracts

public final class ChromeBridge: @unchecked Sendable {
    public struct Options: Sendable {
        public var requestTimeout: TimeInterval = 3
        public var helloTimeout: TimeInterval = 3
        /// Largest accepted line from a host (a snapshot with many data: favicons can be a few MB).
        public var maxLine: Int = 32 << 20
        /// Require hello.hostPid == the socket peer's pid.
        public var verifyPeerPid: Bool = true
        public init() {}
    }

    /// One connected host (after its host line).
    public struct Connection: Sendable, Hashable {
        public let id: Int
        public let host: Wire.HostHello
        public var ext: Wire.ExtHello?
        public let connectedAt: Date
        public var lastMessageAt: Date
        public var browserPid: Int32 { host.browserPid }
    }

    public enum Event: Sendable {
        case connected(Connection)
        case hello(Connection)
        case dirty(connection: Int, browserPid: Int32)
        case disconnected(connection: Int, browserPid: Int32)
        /// A connection was refused (wrong uid, no/invalid host line, pid mismatch). For logs only.
        case refused(String)
    }

    public enum RequestError: Error, Equatable, Sendable {
        case notConnected, timeout, disconnected, writeFailed, encodeFailed
    }

    public let socketPath: String
    public let options: Options

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "dev.adder.headroom.bridge.io")
    private let eventQueue = DispatchQueue(label: "dev.adder.headroom.bridge.events")
    private var listenFD: Int32 = -1
    private var listenInode: ino_t = 0
    private var acceptSource: DispatchSourceRead?
    private var conns: [Int: Conn] = [:]
    private var nextConnId = 1
    private var nextReq = 1
    private var pending: [Int: Pending] = [:]
    private var handler: (@Sendable (Event) -> Void)?
    private var startedAt: Date?

    private final class Conn: @unchecked Sendable {
        let id: Int
        let fd: Int32
        let peerPid: pid_t
        let writeQueue: DispatchQueue
        var source: DispatchSourceRead?
        var lines: LineBuffer
        var info: Connection?
        var closed = false
        init(id: Int, fd: Int32, peerPid: pid_t, maxLine: Int) {
            self.id = id; self.fd = fd; self.peerPid = peerPid
            self.writeQueue = DispatchQueue(label: "dev.adder.headroom.bridge.conn\(id)")
            self.lines = LineBuffer(maxLine: maxLine)
        }
    }

    private struct Pending {
        let conn: Int
        let cont: CheckedContinuation<Result<Data, RequestError>, Never>
    }

    public init(socketPath: String, options: Options = Options()) {
        self.socketPath = socketPath
        self.options = options
    }

    public convenience init(env: HeadroomEnv, options: Options = Options()) {
        self.init(socketPath: env.socketPath, options: options)
    }

    deinit { stop() }

    // MARK: - Lifecycle

    public var isRunning: Bool { lock.withLock { listenFD >= 0 } }
    public var runningSince: Date? { lock.withLock { startedAt } }

    /// Events (connected, hello, dirty, disconnected) on a private serial queue. Replaces any earlier handler.
    public func setEventHandler(_ h: (@Sendable (Event) -> Void)?) { lock.withLock { handler = h } }

    /// Creates run/ (0700), replaces a stale app.sock, binds and listens. Throws `.inUse` when another
    /// Headroom (the app, or a CLI run) is already serving.
    public func start() throws {
        if isRunning { return }
        let runDir = (socketPath as NSString).deletingLastPathComponent
        do {
            try SocketIO.prepareRunDir(runDir)
            let (fd, ino) = try SocketIO.listen(socketPath)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
            src.setEventHandler { [weak self] in self?.acceptAll() }
            src.setCancelHandler { close(fd) }
            lock.withLock {
                listenFD = fd; listenInode = ino; acceptSource = src; startedAt = Date()
            }
            src.resume()
        } catch {
            throw BridgeError(error)
        }
    }

    public struct BridgeError: Error, CustomStringConvertible, Equatable {
        public let description: String
        public let inUse: Bool
        init(_ f: SocketIO.Failure) { description = f.description; inUse = f == .inUse }
    }

    /// Stops listening, closes every connection (failing their pending requests) and removes app.sock if it
    /// is still the file this bridge created.
    public func stop() {
        let (src, fd, ino, all): (DispatchSourceRead?, Int32, ino_t, [Conn]) = lock.withLock {
            let r = (acceptSource, listenFD, listenInode, Array(conns.values))
            acceptSource = nil; listenFD = -1; startedAt = nil
            return r
        }
        if let src { src.cancel() }  // its cancel handler closes the listening fd
        if fd >= 0 {
            var st = stat()
            if lstat(socketPath, &st) == 0, st.st_ino == ino, st.st_mode & S_IFMT == S_IFSOCK { unlink(socketPath) }
        }
        for c in all { drop(c.id, why: nil) }
    }

    // MARK: - Queries

    /// Connections that sent their host line, oldest first.
    public func connections() -> [Connection] {
        lock.withLock { conns.values.compactMap { $0.closed ? nil : $0.info }.sorted { $0.id < $1.id } }
    }

    public func connections(browserPid: Int32) -> [Connection] { connections().filter { $0.browserPid == browserPid } }

    /// Waits until at least one host is connected, or `timeout` passes. Returns the connections.
    public func waitForHosts(timeout: TimeInterval) async -> [Connection] {
        let end = Date().addingTimeInterval(timeout)
        while true {
            let c = connections()
            if !c.isEmpty || Date() >= end { return c }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Requests

    /// Sends a request built with a fresh `req` and waits for the reply line with the same `req` from the same
    /// connection (raw JSON), or fails after `timeout` (default `options.requestTimeout`).
    public func request<M: Encodable>(_ connection: Int, timeout: TimeInterval? = nil,
                                      _ make: (Int) -> M) async -> Result<Data, RequestError> {
        let req: Int = lock.withLock { defer { nextReq += 1 }; return nextReq }
        guard var encoded = try? JSONEncoder().encode(make(req)) else { return .failure(.encodeFailed) }
        encoded.append(0x0A)
        let line = encoded
        let limit = timeout ?? options.requestTimeout
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<Data, RequestError>, Never>) in
            let conn: Conn? = lock.withLock {
                guard let c = conns[connection], !c.closed, c.info != nil else { return nil }
                pending[req] = Pending(conn: connection, cont: cont)
                return c
            }
            guard let conn else { cont.resume(returning: .failure(.notConnected)); return }
            ioQueue.asyncAfter(deadline: .now() + limit) { [weak self] in self?.finish(req, .failure(.timeout)) }
            conn.writeQueue.async { [weak self] in
                guard let self else { return }
                if !SocketIO.writeAll(conn.fd, line, deadline: Date().addingTimeInterval(limit)) {
                    self.finish(req, .failure(.writeFailed))
                    self.drop(conn.id, why: "write failed")
                }
            }
        }
    }

    /// Sends a message that has no reply (setMode, reload). False if the connection is gone.
    @discardableResult
    public func send<M: Encodable>(_ connection: Int, _ msg: M) -> Bool {
        guard var encoded = try? JSONEncoder().encode(msg) else { return false }
        encoded.append(0x0A)
        let line = encoded
        guard let conn: Conn = lock.withLock({ conns[connection].flatMap { $0.closed || $0.info == nil ? nil : $0 } }) else {
            return false
        }
        conn.writeQueue.async { [weak self] in
            if !SocketIO.writeAll(conn.fd, line, deadline: Date().addingTimeInterval(self?.options.requestTimeout ?? 3)) {
                self?.drop(conn.id, why: "write failed")
            }
        }
        return true
    }

    private func finish(_ req: Int, _ r: Result<Data, RequestError>) {
        let p: Pending? = lock.withLock { pending.removeValue(forKey: req) }
        p?.cont.resume(returning: r)
    }

    // MARK: - Accept / read (ioQueue)

    private func acceptAll() {
        let lfd = lock.withLock { listenFD }
        guard lfd >= 0 else { return }
        while true {
            let fd = accept(lfd, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            guard let peer = SocketIO.peer(fd), peer.uid == getuid() else {
                close(fd)
                emit(.refused("peer uid is not ours"))
                continue
            }
            SocketIO.setNonBlocking(fd)
            SocketIO.noSigpipe(fd)
            let conn: Conn = lock.withLock {
                let c = Conn(id: nextConnId, fd: fd, peerPid: peer.pid, maxLine: options.maxLine)
                nextConnId += 1
                conns[c.id] = c
                return c
            }
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
            src.setEventHandler { [weak self] in self?.readable(conn) }
            // Close only after the source is cancelled, and on the write queue, so no write races the close.
            src.setCancelHandler { conn.writeQueue.async { close(fd) } }
            let dropped: Bool = lock.withLock { conn.source = src; return conn.closed }
            src.resume()
            if dropped { src.cancel() }
            ioQueue.asyncAfter(deadline: .now() + options.helloTimeout) { [weak self] in
                guard let self else { return }
                let noHello = self.lock.withLock { !conn.closed && conn.info == nil }
                if noHello { self.drop(conn.id, why: "no host line within \(self.options.helloTimeout) s") }
            }
        }
    }

    private func readable(_ c: Conn) {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(c.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let lines: [Data]
                do { lines = try c.lines.push(Data(buf[0..<n])) } catch {
                    drop(c.id, why: "line longer than \(options.maxLine) bytes"); return
                }
                for l in lines { handle(l, from: c); if c.closed { return } }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            drop(c.id, why: nil)  // EOF or error
            return
        }
    }

    private func handle(_ line: Data, from c: Conn) {
        guard let env = try? JSONDecoder().decode(Wire.Envelope.self, from: line) else { return } // ignore junk
        let now = Date()
        // The first line must be the host line.
        if lock.withLock({ c.info == nil }) {
            guard env.t == "host", let h = try? JSONDecoder().decode(Wire.HostHello.self, from: line) else {
                drop(c.id, why: "first line was not a host line"); return
            }
            if options.verifyPeerPid, c.peerPid != 0, h.hostPid != c.peerPid {
                drop(c.id, why: "host line claims pid \(h.hostPid) but the peer is pid \(c.peerPid)"); return
            }
            let info = Connection(id: c.id, host: h, ext: nil, connectedAt: now, lastMessageAt: now)
            lock.withLock { c.info = info }
            emit(.connected(info))
            return
        }
        let bpid: Int32 = lock.withLock { c.info?.lastMessageAt = now; return c.info?.browserPid ?? 0 }
        switch env.t {
        case "hello":
            guard let e = try? JSONDecoder().decode(Wire.ExtHello.self, from: line) else { return }
            let info: Connection? = lock.withLock { c.info?.ext = e; return c.info }
            if let info { emit(.hello(info)) }
        case "dirty":
            emit(.dirty(connection: c.id, browserPid: bpid))
        case "ping", "pong", "host":
            break
        default:
            guard let req = env.req else { return }
            let p: Pending? = lock.withLock {
                guard let p = pending[req], p.conn == c.id else { return nil }
                pending[req] = nil
                return p
            }
            p?.cont.resume(returning: .success(line))
        }
    }

    private func drop(_ id: Int, why: String?) {
        let (conn, failed): (Conn?, [Pending]) = lock.withLock {
            guard let c = conns.removeValue(forKey: id), !c.closed else { return (nil, []) }
            c.closed = true
            let mine = pending.filter { $0.value.conn == id }
            for k in mine.keys { pending[k] = nil }
            return (c, Array(mine.values))
        }
        guard let conn else { return }
        // The read source's cancel handler closes the fd (see acceptAll); without a source yet, acceptAll
        // cancels it right after creating it.
        lock.withLock { conn.source }?.cancel()
        for p in failed { p.cont.resume(returning: .failure(.disconnected)) }
        if let info = conn.info {
            emit(.disconnected(connection: id, browserPid: info.browserPid))
        } else if let why {
            emit(.refused(why))
        }
    }

    private func emit(_ e: Event) {
        guard let h = lock.withLock({ handler }) else { return }
        eventQueue.async { h(e) }
    }
}
