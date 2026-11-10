// Framing for both links (SPEC §4.2, docs/protocol.md):
//   extension ↔ host: Chrome native messaging, 4-byte native-endian length + UTF-8 JSON.
//   host ↔ app:       one JSON object per line.
// Pure value types, so they are unit tested without any I/O.

import Foundation

enum NativeFraming {
    /// Chrome refuses messages larger than 1 MB from a native host.
    static let maxToChrome = 1024 * 1024
    /// Chrome sends at most 64 MiB to a native host.
    static let maxFromChrome = 64 * 1024 * 1024

    enum FramingError: Error, Equatable {
        case tooLarge(Int)
    }

    /// 4-byte native-endian length, then the bytes.
    static func encode(_ payload: Data) -> Data {
        var n = UInt32(payload.count)
        var out = Data(bytes: &n, count: 4)
        out.append(payload)
        return out
    }

    /// Incremental decoder: push bytes as they arrive, pop whole messages.
    struct Decoder {
        private var buf: [UInt8] = []
        private var start = 0
        let limit: Int

        init(limit: Int = NativeFraming.maxFromChrome) { self.limit = limit }

        var pendingBytes: Int { buf.count - start }

        mutating func push(_ d: Data) { buf.append(contentsOf: d) }
        mutating func push(_ d: [UInt8]) { buf.append(contentsOf: d) }

        /// The next whole message, nil when more bytes are needed.
        mutating func next() throws -> Data? {
            guard buf.count - start >= 4 else { compact(); return nil }
            let n = buf.withUnsafeBytes { raw in raw.loadUnaligned(fromByteOffset: start, as: UInt32.self) }
            let len = Int(n)
            guard len <= limit else { throw FramingError.tooLarge(len) }
            guard buf.count - start - 4 >= len else { compact(); return nil }
            let msg = Data(buf[(start + 4)..<(start + 4 + len)])
            start += 4 + len
            if start == buf.count { buf.removeAll(keepingCapacity: true); start = 0 }
            return msg
        }

        private mutating func compact() {
            if start > 0 { buf.removeFirst(start); start = 0 }
        }
    }
}

/// Splits a byte stream into lines. Empty lines are dropped; a trailing "\r" is removed.
struct LineSplitter {
    private var buf: [UInt8] = []
    let limit: Int

    init(limit: Int = 64 * 1024 * 1024) { self.limit = limit }

    var pendingBytes: Int { buf.count }

    /// Returns the complete lines. Throws when one line grows past `limit`.
    mutating func push(_ d: Data) throws -> [Data] {
        buf.append(contentsOf: d)
        var lines: [Data] = []
        var lineStart = 0
        var i = 0
        while i < buf.count {
            if buf[i] == 0x0A {
                var end = i
                if end > lineStart && buf[end - 1] == 0x0D { end -= 1 }
                if end > lineStart { lines.append(Data(buf[lineStart..<end])) }
                lineStart = i + 1
            }
            i += 1
        }
        if lineStart > 0 { buf.removeFirst(lineStart) }
        if buf.count > limit { buf.removeAll(); throw NativeFraming.FramingError.tooLarge(limit) }
        return lines
    }
}

/// Small JSON helpers shared by the relay and the probe.
enum JSONLine {
    /// The top-level object, or nil when `d` is not a JSON object.
    static func object(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// `t` of a JSON object message.
    static func type(_ d: Data) -> String? { object(d)?["t"] as? String }

    /// One line for the app socket: `d` unchanged when it has no raw newline (Chrome's JSON never
    /// does), otherwise re-serialised compactly. Always ends with "\n".
    static func line(_ d: Data) -> Data? {
        var out: Data
        if d.contains(0x0A) || d.contains(0x0D) {
            guard let o = object(d), let re = try? JSONSerialization.data(withJSONObject: o) else { return nil }
            out = re
        } else {
            out = d
        }
        out.append(0x0A)
        return out
    }

    static func encode(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
