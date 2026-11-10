// SPEC §5 "Transcript tail".
//
// Transcripts are many MB, so only the tail is read:
//   - path: <projectsDir>/<cwd with every non-alphanumeric → "-">/<sessionId>.jsonl, else the first
//     <projectsDir>/*/<sessionId>.jsonl, else hasTranscript = false;
//   - read from size − 64 KB, drop the first (partial) line, scan lines backwards; a line is parsed only if its first
//     320 bytes mention "type":"user", assistant, ai-title, last-prompt or away_summary;
//   - if the window holds no user/assistant entry (or none of title/prompt/answer), grow it ×4, up to 8 MB; the
//     first read of a file also grows until it finds an ai-title;
//   - re-read only when the file size (or inode) changes; values that a newer tail no longer contains (the ai-title,
//     say) are kept from the previous read.
// Activity comes only from each entry's own "timestamp" field. The file mtime and "the last line" are never used.

import Darwin
import Foundation
import HeadroomContracts

public struct TranscriptInfo: Sendable, Hashable, Codable {
    public var path: String?
    /// Timestamp of the last user or assistant entry.
    public var lastActivity: Date?
    public var aiTitle: String?
    /// Latest user-renamed title ("custom-title" entry), if any.
    public var customTitle: String?
    public var lastPrompt: String?
    /// Last assistant text, at most 300 characters.
    public var lastAssistant: String?
    /// Latest system/away_summary, only while it is newer than lastActivity (else the user has come back).
    public var awaySummary: String?
    public var awaySummaryAt: Date?
    public var size: Int64 = 0
    /// Bytes actually read for this result (64 KB unless the window had to grow).
    public var bytesRead: Int = 0
    public init(path: String? = nil) { self.path = path }
    public var exists: Bool { path != nil }
}

public final class TranscriptTail: @unchecked Sendable {
    public static let initialWindow = 64 << 10
    public static let maxWindow = 8 << 20
    public static let prefilterBytes = 320
    public static let assistantChars = 300

    public let projectsDir: String
    /// How long a "not found" (glob) result is trusted before searching again.
    public var negativeTTL: TimeInterval = 30

    private let lock = NSLock()
    private var byPath: [String: (stamp: TailStamp, info: TranscriptInfo)] = [:]
    private var located: [String: String] = [:]            // sessionId → path
    private var missing: [String: Date] = [:]              // sessionId → when the glob last failed

    public init(projectsDir: String) { self.projectsDir = projectsDir }

    /// "/Users/jappleseed/kb" → "-Users-jappleseed-kb" (every non-ASCII-alphanumeric character becomes "-").
    public static func projectDirName(cwd: String) -> String {
        String(cwd.unicodeScalars.map { s -> Character in
            s.isASCII && (CharacterSet.alphanumerics.contains(s)) ? Character(s) : "-"
        })
    }

    /// Locates `<sessionId>.jsonl`: the cwd-derived directory first, then any project directory.
    public func locate(sessionId: String, cwd: String?, now: Date = Date()) -> String? {
        guard Self.isSafeId(sessionId) else { return nil }
        let fm = FileManager.default
        if let cwd, !cwd.isEmpty {
            let p = projectsDir + "/" + Self.projectDirName(cwd: cwd) + "/" + sessionId + ".jsonl"
            if fm.fileExists(atPath: p) { return p }
        }
        lock.lock()
        if let p = located[sessionId] {
            lock.unlock()
            if fm.fileExists(atPath: p) { return p }
            lock.lock(); located[sessionId] = nil; lock.unlock()
        } else if let when = missing[sessionId], now.timeIntervalSince(when) < negativeTTL {
            lock.unlock(); return nil
        } else {
            lock.unlock()
        }
        let dirs = (try? fm.contentsOfDirectory(atPath: projectsDir)) ?? []
        var found: String?
        for d in dirs.sorted() where !d.hasPrefix(".") {
            let p = projectsDir + "/" + d + "/" + sessionId + ".jsonl"
            if access(p, F_OK) == 0 { found = p; break }
        }
        lock.lock()
        if let found { located[sessionId] = found; missing[sessionId] = nil } else { missing[sessionId] = now }
        lock.unlock()
        return found
    }

    /// The tail info for a session (cached by file size + inode).
    public func info(sessionId: String, cwd: String?, now: Date = Date()) -> TranscriptInfo {
        guard let path = locate(sessionId: sessionId, cwd: cwd, now: now) else { return TranscriptInfo() }
        return info(path: path)
    }

    public func info(path: String) -> TranscriptInfo {
        guard let st = TailStamp(path: path) else { return TranscriptInfo() }
        lock.lock()
        let prev = byPath[path]
        lock.unlock()
        if let prev, prev.stamp == st { return prev.info }
        // The first read of a file also grows the window until it finds an ai-title (they recur through a
        // transcript, but a burst of tool output can push the last one out of 64 KB). Later reads reuse it.
        var fresh = Self.read(path: path, size: st.size, wantTitle: prev?.stamp.inode != st.inode)
        // Merge: keep what the new window no longer shows, if the file only grew (same inode).
        if let p = prev?.info, prev?.stamp.inode == st.inode, st.size >= (prev?.stamp.size ?? 0) {
            fresh.aiTitle = fresh.aiTitle ?? p.aiTitle
            fresh.customTitle = fresh.customTitle ?? p.customTitle
            fresh.lastPrompt = fresh.lastPrompt ?? p.lastPrompt
            fresh.lastAssistant = fresh.lastAssistant ?? p.lastAssistant
            if fresh.lastActivity == nil { fresh.lastActivity = p.lastActivity }
            if fresh.awaySummary == nil, let a = p.awaySummary, let at = p.awaySummaryAt,
               at >= (fresh.lastActivity ?? .distantPast) {
                fresh.awaySummary = a; fresh.awaySummaryAt = at
            }
        }
        lock.lock(); byPath[path] = (st, fresh); lock.unlock()
        return fresh
    }

    /// Drops cache entries for paths not in `keep` (call once per snapshot).
    public func prune(keeping keep: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        byPath = byPath.filter { keep.contains($0.key) }
    }

    // MARK: - Reading (pure apart from the file read)

    public static func read(path: String, size: Int64? = nil, wantTitle: Bool = false) -> TranscriptInfo {
        var out = TranscriptInfo(path: path)
        guard let fh = FileHandle(forReadingAtPath: path) else { return out }
        defer { try? fh.close() }
        let total = size ?? Int64((try? fh.seekToEnd()) ?? 0)
        out.size = total
        var window = initialWindow
        while true {
            let start = max(0, total - Int64(window))
            guard (try? fh.seek(toOffset: UInt64(start))) != nil,
                  let data = try? fh.read(upToCount: Int(total - start)) else { return out }
            out.bytesRead = data.count
            var r = scan(data, dropFirstLine: start > 0)
            r.path = path; r.size = total; r.bytesRead = data.count
            let enough = r.lastActivity != nil
                && (r.aiTitle != nil || r.lastPrompt != nil || r.lastAssistant != nil || r.customTitle != nil)
                && (!wantTitle || r.aiTitle != nil)
            if enough || start == 0 || window >= maxWindow { return r }
            window = min(window * 4, maxWindow)
        }
    }

    /// Scans complete JSONL lines backwards. `dropFirstLine`: the buffer starts mid-line.
    static func scan(_ data: Data, dropFirstLine: Bool) -> TranscriptInfo {
        var out = TranscriptInfo()
        var haveUserOrAssistant = false
        var haveAssistantText = false
        var haveTitle = false, haveCustom = false, havePrompt = false, haveAway = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var firstLineStart = 0
            if dropFirstLine {
                guard let nl = memchr(base, 0x0A, n) else { return }
                firstLineStart = base.distance(to: nl.assumingMemoryBound(to: UInt8.self)) + 1
            }
            var end = n
            // Walk lines from the end: [lineStart, end).
            while end > firstLineStart {
                var i = end - 1
                while i >= firstLineStart && base[i] != 0x0A { i -= 1 }
                let lineStart = i + 1
                let len = end - lineStart
                end = i   // next iteration ends at this newline
                if len < 2 { continue }
                let line = UnsafeBufferPointer(start: base + lineStart, count: len)
                let head = UnsafeBufferPointer(start: line.baseAddress, count: min(len, prefilterBytes))
                let kind = prefilter(head)
                if kind == .none { continue }
                // Skip kinds we no longer need before paying for JSON parsing.
                switch kind {
                case .aiTitle where haveTitle: continue
                case .customTitle where haveCustom: continue
                case .lastPrompt where havePrompt: continue
                case .away where haveAway || haveUserOrAssistant: continue   // an older recap is stale
                case .user where haveUserOrAssistant && havePrompt: continue
                case .assistant where haveUserOrAssistant && haveAssistantText: continue
                default: break
                }
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                let type = obj["type"] as? String
                switch type {
                case "ai-title":
                    if !haveTitle, let t = obj["aiTitle"] as? String, !t.isEmpty { out.aiTitle = t; haveTitle = true }
                case "custom-title":
                    if !haveCustom, let t = obj["customTitle"] as? String, !t.isEmpty { out.customTitle = t; haveCustom = true }
                case "last-prompt":
                    if !havePrompt, let t = obj["lastPrompt"] as? String, !t.isEmpty {
                        out.lastPrompt = clip(t, 300); havePrompt = true
                    }
                case "system":
                    if (obj["subtype"] as? String) == "away_summary", !haveAway, !haveUserOrAssistant,
                       let c = obj["content"] as? String {
                        out.awaySummary = clip(c, 600); out.awaySummaryAt = parseTimestamp(obj["timestamp"])
                        haveAway = true
                    }
                case "user", "assistant":
                    if !haveUserOrAssistant, let ts = parseTimestamp(obj["timestamp"]) {
                        out.lastActivity = ts; haveUserOrAssistant = true
                    }
                    if type == "assistant", !haveAssistantText, let t = assistantText(obj) {
                        out.lastAssistant = t; haveAssistantText = true
                    }
                    if type == "user", !havePrompt, let t = userPromptText(obj) {
                        out.lastPrompt = clip(t, 300); havePrompt = true
                    }
                default: break
                }
                if haveUserOrAssistant && haveAssistantText && haveTitle && havePrompt { break }
            }
        }
        // A recap older than the latest activity means the user came back since.
        if let at = out.awaySummaryAt, let la = out.lastActivity, at < la { out.awaySummary = nil; out.awaySummaryAt = nil }
        return out
    }

    enum LineKind { case none, user, assistant, aiTitle, customTitle, lastPrompt, away }

    /// Looks at the first bytes only (entries put "type" early, except assistant lines whose "role" is early).
    static func prefilter(_ head: UnsafeBufferPointer<UInt8>) -> LineKind {
        func has(_ needle: StaticString) -> Bool {
            let nlen = needle.utf8CodeUnitCount
            guard head.count >= nlen, let hb = head.baseAddress else { return false }
            return needle.withUTF8Buffer { nb in
                memmem(hb, head.count, nb.baseAddress!, nlen) != nil
            }
        }
        if has("\"type\":\"ai-title\"") { return .aiTitle }
        if has("\"type\":\"last-prompt\"") { return .lastPrompt }
        if has("\"type\":\"custom-title\"") { return .customTitle }
        if has("\"subtype\":\"away_summary\"") { return .away }
        if has("\"type\":\"user\"") { return .user }
        if has("\"role\":\"assistant\"") || has("\"type\":\"assistant\"") { return .assistant }
        return .none
    }

    /// The text blocks of an assistant message, joined, clipped to 300 characters. nil if it has none.
    static func assistantText(_ obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s.isEmpty ? nil : clip(s, assistantChars) }
        guard let blocks = msg["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { b -> String? in
            (b["type"] as? String) == "text" ? (b["text"] as? String) : nil
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return texts.isEmpty ? nil : clip(texts.joined(separator: "\n"), assistantChars)
    }

    /// A typed prompt (not a tool result, not meta, not a command wrapper), for transcripts without "last-prompt".
    static func userPromptText(_ obj: [String: Any]) -> String? {
        if (obj["isMeta"] as? Bool) == true { return nil }
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = msg["content"] as? String { text = s }
        else if let blocks = msg["content"] as? [[String: Any]] {
            if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return nil }
            text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !t.hasPrefix("<") else { return nil }       // <command-name>, <local-command-stdout>, reminders …
        return t
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\r", with: "")
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }

    /// "2026-09-30T17:36:39.480Z" (fractional seconds optional).
    static func parseTimestamp(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return ISOTimestamp.parse(s)
    }

    static func isSafeId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && s.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }
}

/// Fast ISO-8601 UTC parser for transcript timestamps ("YYYY-MM-DDTHH:MM:SS[.fff]Z"). Falls back to Foundation.
enum ISOTimestamp {
    static func parse(_ s: String) -> Date? {
        let u = Array(s.utf8)
        func num(_ a: Int, _ b: Int) -> Int? {
            guard b <= u.count else { return nil }
            var v = 0
            for i in a..<b { let c = Int(u[i]) - 48; guard c >= 0 && c <= 9 else { return nil }; v = v * 10 + c }
            return v
        }
        guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58,
              let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10),
              let h = num(11, 13), let mi = num(14, 16), let se = num(17, 19) else { return slow(s) }
        var frac = 0.0
        var i = 19
        if i < u.count, u[i] == 46 {
            i += 1; var scale = 0.1
            while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
        }
        guard i < u.count, u[i] == 90 else { return slow(s) }   // only "Z" on the fast path
        // Days from civil (Howard Hinnant).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let secs = Double(days * 86_400 + h * 3600 + mi * 60 + se) + frac
        return Date(timeIntervalSince1970: secs)
    }

    static func slow(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// size + inode: transcripts are append-only, so a size change is the re-read trigger (never mtime).
struct TailStamp: Hashable, Sendable {
    let size: Int64
    let inode: UInt64
    init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        size = Int64(st.st_size); inode = UInt64(st.st_ino)
    }
}
