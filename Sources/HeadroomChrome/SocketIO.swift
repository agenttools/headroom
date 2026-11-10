// Low-level Unix-socket helpers for ChromeBridge (SPEC §2 "Socket security").

import Darwin
import Foundation

enum SocketIO {
    /// sizeof(sockaddr_un.sun_path) on Darwin.
    static let maxPathBytes = 104

    enum Failure: Error, Equatable, CustomStringConvertible {
        case pathTooLong(String)
        case unsafe(String)
        case inUse
        case sys(String, Int32)
        var description: String {
            switch self {
            case .pathTooLong(let p): "socket path is longer than \(SocketIO.maxPathBytes - 1) bytes: \(p)"
            case .unsafe(let s): s
            case .inUse: "another Headroom is already listening on app.sock"
            case .sys(let what, let e): "\(what): \(String(cString: strerror(e)))"
            }
        }
    }

    static func makeAddr(_ path: String) throws(Failure) -> (sockaddr_un, socklen_t) {
        let bytes = Array(path.utf8)
        guard bytes.count < maxPathBytes else { throw .pathTooLong(path) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
            p[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count + 1)
        addr.sun_len = UInt8(len)
        return (addr, len)
    }

    /// Creates `runDir` (and its parents) and makes sure it is ours, a real directory and mode 0700.
    static func prepareRunDir(_ runDir: String) throws(Failure) {
        let parent = (runDir as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw .unsafe("cannot create \(parent): \(error.localizedDescription)")
        }
        if mkdir(runDir, 0o700) != 0 && errno != EEXIST { throw .sys("mkdir \(runDir)", errno) }
        var st = stat()
        guard lstat(runDir, &st) == 0 else { throw .sys("lstat \(runDir)", errno) }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw .unsafe("\(runDir) is not a directory") }
        guard st.st_uid == getuid() else { throw .unsafe("\(runDir) is owned by uid \(st.st_uid)") }
        if st.st_mode & 0o777 != 0o700, chmod(runDir, 0o700) != 0 { throw .sys("chmod 0700 \(runDir)", errno) }
    }

    /// True if something accepts connections on `path` (a live server).
    static func isLive(_ path: String) -> Bool {
        guard let (addr, len) = try? makeAddr(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = addr
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) } }
        return rc == 0
    }

    /// Binds and listens on `path`. A stale socket file (nobody listening) is replaced; a live one is not.
    /// Returns the listening fd and the socket's inode (so stop() only unlinks its own file).
    static func listen(_ path: String, backlog: Int32 = 16) throws(Failure) -> (fd: Int32, inode: ino_t) {
        let (addr, len) = try makeAddr(path)
        var st = stat()
        if lstat(path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK else { throw .unsafe("\(path) exists and is not a socket") }
            if isLive(path) { throw .inUse }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .sys("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var a = addr
        // Bind with a restrictive umask so the socket is never briefly group/other accessible.
        let old = umask(0o077)
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        let e = errno
        umask(old)
        guard rc == 0 else { close(fd); throw e == EADDRINUSE ? .inUse : .sys("bind \(path)", e) }
        _ = chmod(path, 0o600)
        guard Darwin.listen(fd, backlog) == 0 else { let e = errno; close(fd); unlink(path); throw .sys("listen", e) }
        setNonBlocking(fd)
        var st2 = stat()
        _ = lstat(path, &st2)
        return (fd, st2.st_ino)
    }

    static func setNonBlocking(_ fd: Int32) {
        let fl = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
    }

    static func noSigpipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// (uid, pid) of the peer.
    static func peer(_ fd: Int32) -> (uid: uid_t, pid: pid_t)? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0 { pid = 0 }
        return (uid, pid)
    }

    /// Writes all of `data` to a non-blocking fd, waiting for writability up to `deadline`.
    static func writeAll(_ fd: Int32, _ data: Data, deadline: Date) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n > 0 { p += n; left -= n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    let ms = Int32(max(0, min(1000, deadline.timeIntervalSinceNow * 1000)))
                    if ms <= 0 { return false }
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, ms)
                    continue
                }
                return false
            }
            return true
        }
    }
}

/// Splits a byte stream into `\n`-terminated lines, with a cap on the size of one line.
struct LineBuffer {
    let maxLine: Int
    private var buf = Data()
    init(maxLine: Int) { self.maxLine = maxLine }

    enum Overflow: Error { case lineTooLong }

    mutating func push(_ chunk: Data) throws(Overflow) -> [Data] {
        buf.append(chunk)
        var out: [Data] = []
        var start = buf.startIndex
        while let nl = buf[start...].firstIndex(of: 0x0A) {
            let line = buf[start..<nl]
            if line.count > maxLine { throw .lineTooLong }
            if !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { out.append(Data(line)) }
            start = buf.index(after: nl)
        }
        buf = Data(buf[start...])
        if buf.count > maxLine { throw .lineTooLong }
        return out
    }
}
