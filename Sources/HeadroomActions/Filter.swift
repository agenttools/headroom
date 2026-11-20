// Filter (SPEC §7.5) — the token filter behind ⌘F. Pure and UI-independent (the CLI may reuse it).
//
//   plain words        match title, URL, name, cwd, branch, tmux session and Rex session / tab label
//                      (case-insensitive substring)
//   "quoted words"     one phrase
//   >500mb  <100mb     memory above / below (kb, mb, gb; a bare number means MB)
//   idle>2h  idle<10m  idle longer / shorter than (s, m, h, d)
//   busy               busy sessions
//   is:tab|session|leftover|container   (is:docker = is:container; Docker rows are read-only)
//   site:<host>        tabs on that host (suffix match, so site:google.com matches mail.google.com)
//   tmux:<session>     sessions in that tmux session
//   rex:<session>      sessions in that Rex session (label, prefix match)
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
    /// Lower-cased title, URL/host, cwd, branch, tmux session, Rex session and tab label, command…
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
    /// Lower-cased Rex session label ("" when Rex's session list could not be read); nil = not in Rex.
    public var rexSession: String?

    public init(kind: ItemKind, haystack: [String], bytes: Bytes? = nil, idle: TimeInterval? = nil, busy: Bool = false,
                host: String? = nil, tmuxSession: String? = nil, hasBackground: Bool = false, shared: Bool = false,
                sleeping: Bool = false, rexSession: String? = nil) {
        self.kind = kind; self.haystack = haystack.map { $0.lowercased() }; self.bytes = bytes; self.idle = idle
        self.busy = busy; self.host = host?.lowercased(); self.tmuxSession = tmuxSession?.lowercased()
        self.hasBackground = hasBackground; self.shared = shared; self.sleeping = sleeping
        self.rexSession = rexSession?.lowercased()
    }

    public init(tab t: ChromeTab, now: Date) {
        self.init(kind: .tab, haystack: [t.title, t.url, t.host], bytes: t.display,
                  idle: t.active ? 0 : t.lastAccessed.map { now.timeIntervalSince($0) }, host: t.host,
                  shared: t.sharedWith > 0, sleeping: t.discarded)
    }

    /// A Docker container: matched on its names, image, compose project and the runtime ("colima").
    public init(container c: DockerContainer, runtime: String) {
        self.init(kind: .container,
                  haystack: [c.name, c.image, c.id, c.project ?? "", c.service ?? "", runtime, "docker"],
                  bytes: c.memory)
    }

    public init(session s: ClaudeSession, now: Date) {
        var hay = [s.title, s.cwd, s.project, s.sessionId]
        if let b = s.branch { hay.append(b) }
        if let w = s.worktree { hay.append(w) }
        if let t = s.tmux { hay.append(t.session); hay.append(t.label); hay.append(t.windowName) }
        if let r = s.rex {
            hay.append(r.sessionName); hay.append(r.label)
            if let w = r.windowLabel { hay.append(w) }
        }
        self.init(kind: .session, haystack: hay, bytes: s.total,
                  idle: s.busy ? nil : s.idleSince.map { now.timeIntervalSince($0) }, busy: s.busy,
                  tmuxSession: s.tmux?.session, hasBackground: !s.background.isEmpty, rexSession: s.rex?.sessionLabel)
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
        case rex(String)
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
            case "container", "containers", "docker": return .kind(.container)
            default: break
            }
        }
        if let v = value(t, "site:") { return .site(v) }
        if let v = value(t, "tmux:") { return .tmux(v) }
        if let v = value(t, "rex:") { return .rex(v) }
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
        case .rex(let name):
            guard s.kind == .session, let r = s.rexSession else { return false }
            return r == name || r.hasPrefix(name)
        case .background: return s.kind == .session && s.hasBackground
        case .shared: return s.kind == .tab && s.shared
        case .sleeping: return s.kind == .tab && s.sleeping
        }
    }
}
