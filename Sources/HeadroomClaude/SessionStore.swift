// SPEC §5 "Session registry": ~/.claude/sessions/*.json.
//
// - Decoded leniently: every field is optional, numbers may arrive as strings, unknown keys are ignored,
//   a file that is not a JSON object (half-written, empty) is skipped this round and retried next round.
// - Cheap to call every tick: a DispatchSource on the directory marks the listing dirty when files are added,
//   removed or renamed; every call re-stats the known files (size + mtime + inode) and re-parses only the ones that
//   changed; a full re-list happens at least every `rescanInterval` (10 s) as a safety net.
//   (mtime is used here only as a cache key for the small JSON files. Transcript activity never uses mtime.)
// - Liveness is NOT decided here: that is Ownership.assign step 2 (procStart ±2 s, startedAt ±60 s), which gives
//   OwnershipMap.liveSessions and .staleSessionFiles. Nothing here ever writes or deletes a session file.

import Darwin
import Foundation
import HeadroomContracts

public final class SessionStore: @unchecked Sendable {
    public let dir: String
    public var rescanInterval: TimeInterval = 10

    private let lock = NSLock()
    private var cache: [String: (stamp: FileStamp, record: SessionRecord?)] = [:]
    private var names: [String] = []
    private var listedAt: Date = .distantPast
    private var dirty = true
    private var source: DispatchSourceFileSystemObject?
    private let watchEnabled: Bool

    public init(dir: String, watch: Bool = true) {
        self.dir = dir
        self.watchEnabled = watch
        if watch { startWatching() }
    }

    deinit {
        source?.cancel()
    }

    /// Parsed records, sorted by pid. `filePath` is set on each record.
    public func records(now: Date = Date()) -> [SessionRecord] {
        lock.lock(); defer { lock.unlock() }
        if dirty || source == nil || now.timeIntervalSince(listedAt) >= rescanInterval {
            relist(now: now)
        }
        var out: [SessionRecord] = []
        var keep: [String: (stamp: FileStamp, record: SessionRecord?)] = [:]
        for n in names {
            let path = dir + "/" + n
            guard let st = FileStamp(path: path) else { continue }       // vanished since the listing
            if let c = cache[path], c.stamp == st, c.record != nil {
                keep[path] = c
            } else {
                let rec = Self.parse(path: path)
                // A half-written file parses as nil; keep the stamp out of the cache so the next call retries it.
                keep[path] = (rec == nil ? FileStamp.zero : st, rec)
            }
            if let r = keep[path]?.record { out.append(r) }
        }
        cache = keep
        return out.sorted { ($0.pid ?? 0, $0.filePath ?? "") < ($1.pid ?? 0, $1.filePath ?? "") }
    }

    private func relist(now: Date) {
        let fm = FileManager.default
        names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        listedAt = now
        dirty = false
        if source == nil && watchEnabled { startWatchingLocked() }
    }

    // MARK: - Watching

    private func startWatching() {
        lock.lock(); defer { lock.unlock() }
        startWatchingLocked()
    }

    /// Watches the directory vnode (write/rename/delete). Silently does nothing when the directory is missing;
    /// the next relist retries.
    private func startWatchingLocked() {
        guard source == nil else { return }
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                            queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.dirty = true
            let gone = src.data.contains(.delete) || src.data.contains(.rename)
            if gone { self.source?.cancel(); self.source = nil }
            self.lock.unlock()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    // MARK: - Lenient decoding

    /// Parses one sessions JSON file. nil when it is not a JSON object.
    public static func parse(path: String) -> SessionRecord? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        var r = parse(data: d)
        r?.filePath = path
        if r != nil, r?.pid == nil {
            // "<pid>.json": the file name is the pid when the field is missing.
            let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            r?.pid = Int32(base)
        }
        return r
    }

    public static func parse(data: Data) -> SessionRecord? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func str(_ k: String) -> String? {
            if let s = j[k] as? String { return s.isEmpty ? nil : s }
            if let n = j[k] as? NSNumber, !(j[k] is Bool) { return n.stringValue }
            return nil
        }
        func num(_ k: String) -> Double? {
            if let n = j[k] as? NSNumber, !(j[k] is Bool) { return n.doubleValue }
            if let s = j[k] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        return SessionRecord(
            pid: num("pid").flatMap { Int32(exactly: $0.rounded()) },
            sessionId: str("sessionId"), cwd: str("cwd"), startedAt: num("startedAt"),
            procStart: str("procStart"), version: str("version"), kind: str("kind"), entrypoint: str("entrypoint"),
            tmux: str("tmux"), name: str("name"), nameSource: str("nameSource"), status: str("status"),
            statusUpdatedAt: num("statusUpdatedAt"), updatedAt: num("updatedAt"),
            bridgeSessionId: str("bridgeSessionId"))
    }
}

/// size + mtime(ns) + inode: a cache key for small files that are rewritten in place or replaced by rename.
struct FileStamp: Hashable, Sendable {
    let size: Int64
    let mtimeNs: Int64
    let inode: UInt64
    static let zero = FileStamp(size: -1, mtimeNs: -1, inode: 0)
    init(size: Int64, mtimeNs: Int64, inode: UInt64) { self.size = size; self.mtimeNs = mtimeNs; self.inode = inode }
    init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        size = Int64(st.st_size)
        mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        inode = UInt64(st.st_ino)
    }
}
