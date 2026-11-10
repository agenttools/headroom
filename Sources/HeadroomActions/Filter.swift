// Filter (SPEC §7.5) — the token filter behind ⌘F. Pure and UI-independent (the CLI may reuse it).
//
//   plain words        match title, URL, name, cwd, branch and tmux session (case-insensitive substring)
//   "quoted words"     one phrase
//   >500mb  <100mb     memory above / below (kb, mb, gb; a bare number means MB)
//   idle>2h  idle<10m  idle longer / shorter than (s, m, h, d)
//   busy               busy sessions
//   is:tab|session|leftover
//   site:<host>        tabs on that host (suffix match, so site:google.com matches mail.google.com)
//   tmux:<session>     sessions in that tmux session
//   bg                 sessions with background processes
//   shared             tabs sharing a renderer
//   sleeping           discarded tabs
//
// Tokens are ANDed; a leading `!` negates any token. A token that does not apply to a row's kind is false
// (so `site:x` only ever matches tabs, and `!site:x` keeps every session).

import Foundation
import HeadroomContracts

/// The facts a filter token can test, built from one tab, session or leftover.
public struct FilterSubject: Sendable, Hashable {
    public var kind: ItemKind
    /// Lower-cased title, URL/host, cwd, branch, tmux session, command…
    public var haystack: [String]
    public var bytes: Bytes?
    /// Seconds since last activity; nil = unknown or busy.
    public var idle: TimeInterval?
    public var busy: Bool
    public var host: String?
    public var tmuxSession: String?
    public var hasBackground: Bool
    public var shared: Bool
    public var sleeping: Bool

    public init(kind: ItemKind, haystack: [String], bytes: Bytes? = nil, idle: TimeInterval? = nil, busy: Bool = false,
                host: String? = nil, tmuxSession: String? = nil, hasBackground: Bool = false, shared: Bool = false,
                sleeping: Bool = false) {
        self.kind = kind; self.haystack = haystack.map { $0.lowercased() }; self.bytes = bytes; self.idle = idle
        self.busy = busy; self.host = host?.lowercased(); self.tmuxSession = tmuxSession?.lowercased()
        self.hasBackground = hasBackground; self.shared = shared; self.sleeping = sleeping
    }

    public init(tab t: ChromeTab, now: Date) {
        self.init(kind: .tab, haystack: [t.title, t.url, t.host], bytes: t.display,
                  idle: t.active ? 0 : t.lastAccessed.map { now.timeIntervalSince($0) }, host: t.host,
                  shared: t.sharedWith > 0, sleeping: t.discarded)
    }

    public init(session s: ClaudeSession, now: Date) {
        var hay = [s.title, s.cwd, s.project, s.sessionId]
        if let b = s.branch { hay.append(b) }
        if let w = s.worktree { hay.append(w) }
        if let t = s.tmux { hay.append(t.session); hay.append(t.label); hay.append(t.windowName) }
        self.init(kind: .session, haystack: hay, bytes: s.total,
                  idle: s.busy ? nil : s.idleSince.map { now.timeIntervalSince($0) }, busy: s.busy,
                  tmuxSession: s.tmux?.session, hasBackground: !s.background.isEmpty)
    }

    public init(leftover l: LeftoverGroup, now: Date) {
        var hay = [l.unit.command] + l.unit.argv
        if let c = l.cwd ?? l.unit.cwd { hay.append(c) }
        if let t = l.sessionTitle { hay.append(t) }
        self.init(kind: .leftover, haystack: hay, bytes: l.unit.footprint, idle: now.timeIntervalSince(l.startedAt))
    }
}

public struct FilterQuery: Sendable, Hashable {
    public enum Cmp: String, Sendable, Hashable { case gt = ">", lt = "<" }

    public indirect enum Token: Sendable, Hashable {
        case word(String)
        case bytes(Cmp, Bytes)
        case idle(Cmp, TimeInterval)
        case busy
        case kind(ItemKind)
        case site(String)
        case tmux(String)
        case background
        case shared
        case sleeping
        case not(Token)
    }

    public let tokens: [Token]
    public let source: String

    public init(_ text: String) {
        source = text
        tokens = Self.split(text).map(Self.parseToken)
    }

    public var isEmpty: Bool { tokens.isEmpty }

    public func matches(_ s: FilterSubject) -> Bool { tokens.allSatisfy { Self.eval($0, s) } }

    // MARK: parsing

    /// Splits on whitespace, keeping "quoted phrases" (and !"quoted") together.
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        for ch in text {
            if ch == "\"" { quoted.toggle(); cur.append(ch); continue }
            if ch.isWhitespace && !quoted {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func parseToken(_ raw: String) -> Token {
        if raw.hasPrefix("!"), raw.count > 1 { return .not(parseToken(String(raw.dropFirst()))) }
        let t = raw.lowercased()
        if t.hasPrefix("\"") {
            return .word(String(t.dropFirst().prefix { $0 != "\"" }))
        }
        switch t {
        case "busy": return .busy
        case "bg": return .background
        case "shared": return .shared
        case "sleeping": return .sleeping
        default: break
        }
        if let c = t.first.flatMap({ Cmp(rawValue: String($0)) }), let b = parseBytes(String(t.dropFirst())) {
            return .bytes(c, b)
        }
        if t.hasPrefix("idle"), t.count > 5, let c = Cmp(rawValue: String(t.dropFirst(4).prefix(1))),
           let d = parseDuration(String(t.dropFirst(5))) {
            return .idle(c, d)
        }
        if let v = value(t, "is:") {
            switch v {
            case "tab", "tabs": return .kind(.tab)
            case "session", "sessions": return .kind(.session)
            case "leftover", "leftovers": return .kind(.leftover)
            default: break
            }
        }
        if let v = value(t, "site:") { return .site(v) }
        if let v = value(t, "tmux:") { return .tmux(v) }
        return .word(t)
    }

    private static func value(_ t: String, _ prefix: String) -> String? {
        guard t.hasPrefix(prefix), t.count > prefix.count else { return nil }
        return String(t.dropFirst(prefix.count))
    }

    /// "500mb", "1.5gb", "300" (MB), "800k"/"800kb".
    public static func parseBytes(_ s: String) -> Bytes? {
        let units: [(String, Double)] = [("gb", 1_073_741_824), ("g", 1_073_741_824), ("mb", 1_048_576),
                                         ("m", 1_048_576), ("kb", 1024), ("k", 1024)]
        for (u, mult) in units where s.hasSuffix(u) {
            guard let v = Double(s.dropLast(u.count)), v >= 0 else { return nil }
            return Bytes(v * mult)
        }
        guard let v = Double(s), v >= 0 else { return nil }
        return Bytes(v * 1_048_576)
    }

    /// "2h", "30m", "1d", "45s", "1.5h". A bare number means minutes.
    public static func parseDuration(_ s: String) -> TimeInterval? {
        let units: [(String, Double)] = [("d", 86_400), ("h", 3600), ("m", 60), ("s", 1)]
        for (u, mult) in units where s.hasSuffix(u) {
            guard let v = Double(s.dropLast(u.count)), v >= 0 else { return nil }
            return v * mult
        }
        guard let v = Double(s), v >= 0 else { return nil }
        return v * 60
    }

    // MARK: evaluation

    static func eval(_ t: Token, _ s: FilterSubject) -> Bool {
        switch t {
        case .not(let inner): return !eval(inner, s)
        case .word(let w): return w.isEmpty || s.haystack.contains { $0.contains(w) }
        case let .bytes(c, b):
            guard let v = s.bytes else { return false }
            return c == .gt ? v > b : v < b
        case let .idle(c, d):
            guard let v = s.idle, !s.busy else { return false }
            return c == .gt ? v > d : v < d
        case .busy: return s.busy
        case .kind(let k): return s.kind == k
        case .site(let h):
            guard s.kind == .tab, let host = s.host else { return false }
            return host == h || host.hasSuffix("." + h) || host.contains(h)
        case .tmux(let name):
            guard s.kind == .session, let t = s.tmuxSession else { return false }
            return t == name || t.hasPrefix(name)
        case .background: return s.kind == .session && s.hasBackground
        case .shared: return s.kind == .tab && s.shared
        case .sleeping: return s.kind == .tab && s.sleeping
        }
    }
}
