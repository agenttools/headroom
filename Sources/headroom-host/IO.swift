// Low-level I/O: blocking fd reads/writes and the app.sock client (SPEC §2 "Socket security").

import Darwin
import Foundation

enum FD {
    /// Writes every byte; retries EINTR. False on any error (EPIPE, timeout, closed).
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                p += n
                left -= n
            }
            return true
        }
    }

    /// Reads up to `max` bytes; retries EINTR. Empty Data means EOF or error.
    static func readSome(_ fd: Int32, max: Int = 64 * 1024) -> Data {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, max) }
            if n < 0 && errno == EINTR { continue }
            return n > 0 ? Data(buf[0..<n]) : Data()
        }
    }
}

/// Connects to app.sock with the checks from SPEC §2:
///   - the run directory is owned by us and not writable by group or others (the app makes it 0700);
///   - app.sock is a socket owned by us (checked without following symlinks);
///   - the peer's uid (getpeereid) is ours.
/// Connects by a path relative to the run directory, so a long HEADROOM_SUPPORT_DIR (tests) does not
/// hit the 104-byte sun_path limit.
enum AppSocket {
    enum Failure: Error, Equatable {
        case absent(String)   // no socket, or a stale one (connection refused)
        case unsafe(String)   // exists but fails a check; treated as absent, logged
    }

    static let name = "app.sock"

    static func connect(runDir: String, sendTimeout: TimeInterval = 3) -> Result<Int32, Failure> {
        let uid = getuid()
        let dfd = open(runDir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if dfd < 0 {
            let e = errno
            return .failure(e == ENOENT ? .absent("no run directory") : .unsafe("cannot open run directory: \(String(cString: strerror(e)))"))
        }
        defer { close(dfd) }

        var dst = stat()
        guard fstat(dfd, &dst) == 0 else { return .failure(.unsafe("cannot stat run directory")) }
        guard dst.st_uid == uid else { return .failure(.unsafe("run directory is owned by uid \(dst.st_uid)")) }
        guard dst.st_mode & 0o022 == 0 else {
            return .failure(.unsafe(String(format: "run directory mode is %o; must not be group/other writable", dst.st_mode & 0o777)))
        }

        var sst = stat()
        guard fstatat(dfd, name, &sst, AT_SYMLINK_NOFOLLOW) == 0 else { return .failure(.absent("no app.sock")) }
        guard sst.st_mode & S_IFMT == S_IFSOCK else { return .failure(.unsafe("app.sock is not a socket")) }
        guard sst.st_uid == uid else { return .failure(.unsafe("app.sock is owned by uid \(sst.st_uid)")) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.absent("socket() failed")) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(name.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + bytes.count + 1)
        addr.sun_len = UInt8(len)
        // connect() relative to the run directory (the SDK has no connectat()): fchdir to the directory
        // we just checked, connect to "app.sock", then go back to "/". Nothing else in the host uses
        // relative paths, and every call to connect() happens on the host's one serial queue.
        guard fchdir(dfd) == 0 else { close(fd); return .failure(.unsafe("cannot enter run directory")) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        let e = errno
        _ = chdir("/")
        if rc != 0 {
            close(fd)
            return .failure(.absent("connect: \(String(cString: strerror(e)))"))
        }

        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0, euid == uid else {
            close(fd)
            return .failure(.unsafe("peer uid \(euid) is not ours"))
        }

        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(sendTimeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return .success(fd)
    }
}

/// stderr logging. Chrome passes the host's stderr to its own stderr, which is normally unseen.
/// Never log URLs or titles.
enum Log {
    nonisolated(unsafe) static var enabled = true
    static func line(_ s: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("headroom-host[\(getpid())]: \(s)\n".utf8))
    }
}
