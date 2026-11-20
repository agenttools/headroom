// A minimal HTTP GET over a unix socket, for the Docker Engine API.
//
// The request is HTTP/1.0 on purpose: the engine then answers without chunked encoding and closes the
// connection, so the body is simply everything after the headers until EOF. GET only: Headroom never changes
// anything in Docker.

import Foundation

public enum UnixHTTP {
    public struct Response: Sendable, Hashable {
        public let status: Int
        public let body: Data
        public var ok: Bool { status == 200 }
    }

    /// Largest body accepted (`/system/df` on a big store is a few hundred KB; this is a runaway guard).
    static let maxBody = 64 * 1024 * 1024

    /// Off the caller's thread. nil = no socket, refused, timed out, or not HTTP.
    public static func get(socket path: String, path request: String, timeout: TimeInterval) async -> Response? {
        await withCheckedContinuation { (c: CheckedContinuation<Response?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                c.resume(returning: getSync(socket: path, path: request, timeout: timeout))
            }
        }
    }

    /// Blocking. The whole exchange (connect, write, read to EOF) must finish before `timeout`.
    public static func getSync(socket path: String, path request: String, timeout: TimeInterval) -> Response? {
        let deadline = Date().addingTimeInterval(timeout)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        // Non-blocking, so a full listen queue or a hung engine cannot hold the thread past the deadline.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS, wait(fd, POLLOUT, deadline) else { return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
        }

        let head = Array("GET \(request) HTTP/1.0\r\nHost: docker\r\nAccept: application/json\r\n\r\n".utf8)
        var sent = 0
        while sent < head.count {
            let n = head[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { sent += n; continue }
            guard n < 0, errno == EAGAIN || errno == EINTR, wait(fd, POLLOUT, deadline) else { return nil }
        }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                data.append(contentsOf: buf[..<n])
                if data.count > maxBody { return nil }
            } else if n == 0 {
                break
            } else {
                guard errno == EAGAIN || errno == EINTR, wait(fd, POLLIN, deadline) else { return nil }
            }
        }
        return parse(data)
    }

    /// Waits until `fd` is ready for `events` or the deadline passes.
    private static func wait(_ fd: Int32, _ events: Int32, _ deadline: Date) -> Bool {
        while true {
            let ms = Int32(max(0, min(deadline.timeIntervalSinceNow * 1000, 60_000)))
            guard ms > 0 else { return false }
            var p = pollfd(fd: fd, events: Int16(events), revents: 0)
            let r = poll(&p, 1, ms)
            if r > 0 { return true }
            if r == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    /// Splits "HTTP/1.x <status> …\r\n<headers>\r\n\r\n<body>". Pure; unit tested.
    static func parse(_ data: Data) -> Response? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headText = String(data: data[data.startIndex..<split.lowerBound], encoding: .utf8),
              let statusLine = headText.split(separator: "\r\n").first else { return nil }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return nil }
        return Response(status: status, body: Data(data[split.upperBound...]))
    }
}
