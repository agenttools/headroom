// ListModel — turns a WorldSnapshot into the rows of the main list (SPEC §6.1): sections, windows, tabs,
// "Chrome itself", sessions with their child/background processes, leftovers, cards and inline notes.
// Pure and UI-independent: the App renders it in an NSOutlineView; tests check it directly.
//
// Also here: sorting, the sort freeze (§7.1: rows keep their order while the pointer is over the list or
// anything is selected), and the shared-renderer gutter brackets.

import Foundation
import HeadroomContracts

public enum ListScope: String, Sendable, CaseIterable, Codable { case all, chrome, claude }
public enum ChromeGrouping: String, Sendable, CaseIterable, Codable { case window, none }
public enum ClaudeGrouping: String, Sendable, CaseIterable, Codable { case none, tmux }
public enum SortColumn: String, Sendable, CaseIterable, Codable {
    case memory, name, location, state, age, pid, rss, cpu, lastActive
}

public struct ListOptions: Sendable, Hashable, Codable {
    public var scope: ListScope
    public var chromeGrouping: ChromeGrouping
    public var claudeGrouping: ClaudeGrouping
    public var sort: SortColumn
    public var ascending: Bool
    public var filter: String
    public init(scope: ListScope = .all, chromeGrouping: ChromeGrouping = .window, claudeGrouping: ClaudeGrouping = .none,
                sort: SortColumn = .memory, ascending: Bool = false, filter: String = "") {
        self.scope = scope; self.chromeGrouping = chromeGrouping; self.claudeGrouping = claudeGrouping
        self.sort = sort; self.ascending = ascending; self.filter = filter
    }
}

public enum ListSection: String, Sendable, CaseIterable, Codable { case chrome, claude, leftovers }

public enum RowKind: String, Sendable, Codable {
    /// CHROME / CLAUDE CODE / LEFTOVERS: floating group rows, never selectable.
    case section
    /// tmux-session grouping header inside CLAUDE CODE (not selectable).
    case subgroup
    case window, tab, chromeItself, overhead, session, process, leftover
    /// The first-run Chrome card (§8.6).
    case card
    /// An inline empty/error state (§6.1).
    case note
}

public enum Glyph: Sendable, Hashable {
    case locked, visible, busy, remote, shared(Int), sleeping, pinned, audible, incognito, worktree, automation, stale
}

public enum Bracket: Sendable, Hashable { case top, middle, bottom }

public enum Tone: Sendable, Hashable { case plain, busy, idle, warn, locked, muted }

public enum NoteKind: Sendable, Hashable {
    case chromeNotRunning
    case waitingForHelper
    case helperStale(Date)
    case perTabUnavailable(String)
    /// The helper cannot see some tabs (incognito without "Allow in Incognito", a profile without the helper).
    case helperBlind(String)
    case noSessions
    case noLeftovers
    case noMatches
}

public struct Row: Sendable, Identifiable {
    /// ItemID string for item rows; "section:chrome", "chromeItself:812", "note:…" otherwise.
    public let id: String
    public let item: ItemID?
    public let kind: RowKind
    public let section: ListSection
    public var title: String
    /// Extra text after the title ("+1.3 GB bg", "7 tabs · 3 windows · helper connected").
    public var badge: String?
    public var location: String
    public var state: String
    public var tone: Tone
    public var glyphs: [Glyph]
    /// nil = unknown ("—").
    public var bytes: Bytes?
    /// Shared renderer: the number is a fair share ("≈").
    public var approx: Bool
    public var protection: Protection
    public var children: [Row]
    public var selectable: Bool
    public var bracket: Bracket?
    /// Tabs sharing one main-frame renderer share this key (drives the gutter bracket).
    public var shareKey: String?
    /// One-letter favicon stand-in for tabs.
    public var monogram: String?
    public var note: NoteKind?
    public var tooltip: String?
    public var subject: FilterSubject?
    // Hidden columns
    public var started: Date?
    public var lastActive: Date?
    public var pid: Int32?
    public var rss: Bytes?
    public var cpu: Double?
    /// Sort rank for rows that must not move (cards and notes first, "Chrome itself" last).
    public var pinRank: Int

    public init(id: String, item: ItemID?, kind: RowKind, section: ListSection, title: String, badge: String? = nil,
                location: String = "", state: String = "", tone: Tone = .plain, glyphs: [Glyph] = [],
                bytes: Bytes? = nil, approx: Bool = false, protection: Protection = .none, children: [Row] = [],
                selectable: Bool = true, pinRank: Int = 0) {
        self.id = id; self.item = item; self.kind = kind; self.section = section; self.title = title
        self.badge = badge; self.location = location; self.state = state; self.tone = tone; self.glyphs = glyphs
        self.bytes = bytes; self.approx = approx; self.protection = protection; self.children = children
        self.selectable = selectable; self.pinRank = pinRank
    }

    public var isLocked: Bool { protection.isLocked }

    /// Depth-first walk (self first).
    public func walk(_ body: (Row) -> Void) {
        body(self)
        for c in children { c.walk(body) }
    }
}

public enum Fmt {
    /// "now", "12m", "30h", "2d".
    public static func age(_ t: TimeInterval) -> String {
        let s = max(0, t)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 48 * 3600 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    public static func bytes(_ b: Bytes?, approx: Bool = false) -> String {
        guard let b else { return "—" }
        return (approx ? "≈ " : "") + ByteFormat.short(b)
    }

    public static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : (many ?? one + "s"))"
    }

    public static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

public enum ListModel {
    // MARK: Build

    public static func build(_ w: WorldSnapshot, protections: [ItemID: Protection], options o: ListOptions,
                             now: Date = Date()) -> [Row] {
        let query = FilterQuery(o.filter)
        // A positive `is:` token hides the sections it rules out.
        let kinds = Set(query.tokens.compactMap { t -> ItemKind? in if case .kind(let k) = t { k } else { nil } })
        func shows(_ k: ItemKind) -> Bool { kinds.isEmpty || kinds.contains(k) }
        var out: [Row] = []
        if o.scope != .claude && shows(.tab) { out.append(chromeSection(w, protections, o, query, now)) }
        if o.scope != .chrome {
            if shows(.session) { out.append(claudeSection(w, protections, o, query, now)) }
            if shows(.leftover), let l = leftoversSection(w, protections, o, query, now) { out.append(l) }
        }
        out = out.map { sortTree($0, o) }
        return out.map(assignBrackets)
    }

    // MARK: Chrome

    static func chromeSection(_ w: WorldSnapshot, _ prot: [ItemID: Protection], _ o: ListOptions,
                              _ q: FilterQuery, _ now: Date) -> Row {
        let c = w.chrome
        var kids: [Row] = []
        let filtering = !q.isEmpty
        let tabRows = Dictionary(uniqueKeysWithValues: c.tabs.map { ($0.ref, tabRow($0, prot, now)) })
        let matches: (Row) -> Bool = { r in !filtering || (r.subject.map(q.matches) ?? false) }

        if !filtering {
            switch c.source {
            case .notRunning:
                kids.append(note(.chromeNotRunning, .chrome, "Chrome is not running"))
            case .processesOnly:
                var card = Row(id: "card:chromeSetup", item: nil, kind: .card, section: .chrome,
                               title: "Chrome is using \(ByteFormat.short(c.total)). To see and close individual tabs, choose one or both:",
                               selectable: false, pinRank: -10)
                card.bytes = nil
                kids.append(card)
            case .waiting:
                kids.append(note(.waitingForHelper, .chrome, "Waiting for Chrome helper…"))
            case .appleScript:
                kids.append(note(.perTabUnavailable(c.perTabUnavailable ?? "Per-tab memory needs the helper extension"),
                                 .chrome, c.perTabUnavailable ?? "Per-tab memory needs the helper extension"))
            case .helper:
                if let why = c.perTabUnavailable {
                    kids.append(note(.perTabUnavailable(why), .chrome, why))
                }
                if let why = c.helperNote {
                    kids.append(note(.helperBlind(why), .chrome, why))
                }
            }
            if let since = c.staleSince {
                kids.append(note(.helperStale(since), .chrome,
                                 "Chrome helper disconnected — showing data from \(Fmt.age(now.timeIntervalSince(since))) ago"))
            }
        }

        if o.chromeGrouping == .window && !c.windows.isEmpty {
            var number: [Int32: Int] = [:]
            for win in c.windows.sorted(by: { ($0.browserPid, $0.id) < ($1.browserPid, $1.id) }) {
                let n = (number[win.browserPid] ?? 0) + 1; number[win.browserPid] = n
                let tabs = c.tabs(inWindow: win).compactMap { tabRows[$0.ref] }.filter(matches)
                if filtering && tabs.isEmpty { continue }
                let all = c.tabs(inWindow: win)
                let active = all.first(where: \.active)?.title ?? all.first?.title ?? ""
                let label = win.incognito ? "Incognito" : active
                let known = all.compactMap(\.display)
                // While filtering, the window row is a heading only: selecting it (or ⌘A) must not reach the
                // tabs the filter hides (a window row closes every tab in the window).
                var r = Row(id: win.itemID.stringValue, item: filtering ? nil : win.itemID, kind: .window, section: .chrome,
                            title: "Window \(n) — \(label)" + (win.focused ? " (front)" : ""),
                            badge: Fmt.plural(all.count, "tab"),
                            bytes: known.isEmpty ? nil : known.reduce(0, +),
                            approx: all.contains { $0.sharedWith > 0 },
                            protection: prot[win.itemID] ?? .none, children: tabs, selectable: !filtering)
                r.state = win.incognito ? "incognito" : (win.focused ? "front" : "")
                r.tone = .muted
                if win.incognito { r.glyphs = [.incognito] }
                kids.append(r)
            }
            // Tabs whose window is unknown (should not happen) are still listed.
            let inWindows = Set(c.windows.flatMap { w in w.tabIds.map { TabRef(browserPid: w.browserPid, tabId: $0) } })
            kids += c.tabs.filter { !inWindows.contains($0.ref) }.compactMap { tabRows[$0.ref] }.filter(matches)
        } else {
            kids += c.tabs.compactMap { tabRows[$0.ref] }.filter(matches)
        }

        if !filtering, let itself = chromeItselfRow(w, prot) { kids.append(itself) }
        if filtering && kids.isEmpty { kids.append(note(.noMatches, .chrome, "No tabs match “\(q.source)”")) }

        let windowCount = c.windows.filter { !$0.tabIds.isEmpty }.count
        var status: String
        switch c.source {
        case .notRunning: status = "not running"
        case .helper(let p): status = p > 1 ? "helper connected (\(p) profiles)" : "helper connected"
        case .appleScript: status = "via AppleScript"
        case .processesOnly: status = "helper not set up"
        case .waiting: status = "waiting for helper"
        }
        if c.staleSince != nil { status = "helper disconnected" }
        var badge = [Fmt.plural(c.tabs.count, "tab"), Fmt.plural(windowCount, "window"), status]
        if c.tabs.isEmpty { badge = [status] }
        return Row(id: "section:chrome", item: nil, kind: .section, section: .chrome, title: "CHROME",
                   badge: badge.joined(separator: " · "), bytes: c.source == .notRunning && c.total == 0 ? nil : c.total,
                   children: kids, selectable: false)
    }

    static func tabRow(_ t: ChromeTab, _ prot: [ItemID: Protection], _ now: Date) -> Row {
        let p = prot[t.itemID] ?? .none
        var glyphs: [Glyph] = []
        if p.isLocked { glyphs.append(.locked) }
        if t.pinned { glyphs.append(.pinned) }
        if t.audible { glyphs.append(.audible) }
        if t.sharedWith > 0 { glyphs.append(.shared(t.sharedWith + 1)) }
        if t.discarded { glyphs.append(.sleeping) }
        if t.incognito { glyphs.append(.incognito) }
        var state: String
        var tone = Tone.plain
        if t.discarded { state = "sleeping"; tone = .muted }
        else if t.audible { state = "audible"; tone = .warn }
        else if t.active { state = "active" }
        else if let la = t.lastAccessed { state = "idle " + Fmt.age(now.timeIntervalSince(la)); tone = .idle }
        else { state = "" }
        if t.pinned && state == "active" { state = "active · pinned" } else if t.pinned { state += state.isEmpty ? "pinned" : " · pinned" }
        let where_ = t.host.isEmpty ? (URL(string: t.url)?.scheme ?? "") : t.host.replacingOccurrences(of: "www.", with: "")
        var r = Row(id: t.itemID.stringValue, item: t.itemID, kind: .tab, section: .chrome, title: t.title.isEmpty ? t.url : t.title,
                    location: where_, state: state, tone: tone, glyphs: glyphs, bytes: t.display,
                    approx: t.sharedWith > 0, protection: p)
        r.monogram = monogram(t)
        r.shareKey = t.sharedWith > 0 ? t.procs.first.map { "\($0)" } : nil
        r.subject = FilterSubject(tab: t, now: now)
        r.lastActive = t.active ? now : t.lastAccessed
        r.tooltip = t.incognito ? "Incognito tab" : t.url
        return r
    }

    static func monogram(_ t: ChromeTab) -> String {
        var h = t.host.replacingOccurrences(of: "www.", with: "")
        for p in ["mail.", "docs.", "calendar.", "app."] where h.hasPrefix(p) { h = String(h.dropFirst(p.count)) }
        let src = h.isEmpty ? t.title : h
        return String(src.first(where: \.isLetter) ?? "•").uppercased()
    }

    static func chromeItselfRow(_ w: WorldSnapshot, _ prot: [ItemID: Protection]) -> Row? {
        let c = w.chrome
        guard c.source != .notRunning || c.total > 0, !c.overhead.isEmpty else { return nil }
        let b = w.ownership.mainBrowsers.first?.key.pid ?? c.tabs.first?.browserPid ?? 0
        let order: [ChromeOverheadKind] = [.browser, .gpu, .utility, .extensions, .background, .hiddenTabs, .crashpad, .otherInstances]
        var kids: [Row] = []
        var parts: [String] = []
        for k in order {
            guard let s = c.overhead[k.rawValue], s.count > 0 || s.bytes > 0 else { continue }
            let id = ItemID.chromeOverhead(browserPid: b, kind: k.rawValue)
            let name: String
            switch k {
            case .browser: name = "Browser process"; parts.append("browser")
            case .gpu: name = "GPU process"; parts.append("GPU")
            case .utility: name = "Utility processes"; parts.append("utility")
            case .extensions: name = "Extensions"; parts.append("\(s.count) extension\(s.count == 1 ? "" : "s")")
            case .background: name = "Background pages and workers"; parts.append("\(s.count) background")
            case .crashpad: name = "Crashpad"
            case .otherInstances: name = "Other Chrome instances"
            case .hiddenTabs: name = "Tabs the helper can't see"; parts.append("hidden tabs")
            }
            var r = Row(id: id.stringValue, item: id, kind: .overhead, section: .chrome, title: name,
                        badge: s.count > 1 ? "×\(s.count)" : nil, state: "locked", tone: .locked, glyphs: [.locked],
                        bytes: s.bytes, protection: prot[id] ?? .locked(.chromeCore))
            if k == .otherInstances {
                let others = w.ownership.browsers.filter { b in
                    !b.isMain && w.ownership.owner[b.key.pid] == .otherChrome(browserPid: b.key.pid)
                }
                r.location = others.map { b in
                    var f: [String] = []
                    if b.headless { f.append("--headless") }
                    if b.remoteDebugging { f.append("--remote-debugging") }
                    return ([b.userDataDir.map { Fmt.tilde($0) } ?? "default profile"] + f).joined(separator: " ")
                }.joined(separator: "; ")
                r.pinRank = 5
                r.glyphs.append(.automation)
            }
            kids.append(r)
        }
        let id = "chromeItself:\(b)"
        return Row(id: id, item: nil, kind: .chromeItself, section: .chrome, title: "Chrome itself",
                   location: parts.joined(separator: " · "), state: "locked", tone: .locked, glyphs: [.locked],
                   bytes: c.overheadTotal, protection: .locked(.chromeCore), children: kids, pinRank: 10)
    }

    // MARK: Claude

    static func claudeSection(_ w: WorldSnapshot, _ prot: [ItemID: Protection], _ o: ListOptions,
                              _ q: FilterQuery, _ now: Date) -> Row {
        let sessions = w.claude.sessions
        var rows = sessions.map { sessionRow($0, prot, now) }
        if !q.isEmpty { rows = rows.filter { $0.subject.map(q.matches) ?? false } }
        var kids: [Row]
        if o.claudeGrouping == .tmux {
            let groups = Dictionary(grouping: rows) { r -> String in
                sessions.first { $0.itemID == r.item }?.tmux?.session ?? ""
            }
            kids = groups.map { name, rs in
                var g = Row(id: "tmux:\(name)", item: nil, kind: .subgroup, section: .claude,
                            title: name.isEmpty ? "Not in tmux" : "tmux: \(name)",
                            badge: Fmt.plural(rs.count, "session"), tone: .muted,
                            bytes: rs.reduce(0) { $0 + ($1.bytes ?? 0) }, children: rs, selectable: false)
                g.pinRank = name.isEmpty ? 1 : 0
                return g
            }
        } else {
            kids = rows
        }
        if sessions.isEmpty && q.isEmpty { kids.append(note(.noSessions, .claude, "No Claude Code sessions are running")) }
        if !q.isEmpty && rows.isEmpty { kids.append(note(.noMatches, .claude, "No sessions match “\(q.source)”")) }
        let busy = sessions.filter(\.busy).count
        var badge = Fmt.plural(sessions.count, "session")
        if busy > 0 { badge += " · \(busy) busy" }
        if !w.claude.staleFiles.isEmpty { badge += " · \(w.claude.staleFiles.count) stale file\(w.claude.staleFiles.count == 1 ? "" : "s") hidden" }
        return Row(id: "section:claude", item: nil, kind: .section, section: .claude, title: "CLAUDE CODE",
                   badge: badge, bytes: w.claude.sessionsTotal, children: kids, selectable: false)
    }

    static func sessionRow(_ s: ClaudeSession, _ prot: [ItemID: Protection], _ now: Date) -> Row {
        let p = prot[s.itemID] ?? .none
        var glyphs: [Glyph] = []
        if p.isLocked { glyphs.append(.locked) }
        if let t = s.tmux, t.visible || t.current { glyphs.append(.visible) }
        if s.busy { glyphs.append(.busy) }
        if s.remoteControl { glyphs.append(.remote) }
        if s.worktree != nil { glyphs.append(.worktree) }
        var loc = s.tmux?.label ?? "not in tmux"
        if let wt = s.worktree { loc += " ⎇ \(wt)" } else { loc += " › \(s.project)" }
        if !s.cwdExists { loc += " (cwd missing)" }
        var state: String
        var tone: Tone
        if s.busy {
            state = "busy " + Fmt.age(now.timeIntervalSince(s.statusSince ?? s.lastActivity ?? now)); tone = .busy
        } else if s.unregistered {
            state = "no session file"; tone = .warn
        } else if let since = s.idleSince {
            state = "idle " + Fmt.age(now.timeIntervalSince(since)); tone = .idle
        } else {
            state = s.status; tone = .muted
        }
        var badge: String?
        if s.isLauncher || p.reasons.contains(.launcher) { badge = "launched Headroom" }
        else if !s.background.isEmpty { badge = "+\(ByteFormat.short(s.backgroundBytes)) bg" }
        var kids: [Row] = []
        for u in s.children { kids.append(unitRow(u, s, background: false, prot)) }
        for u in s.background { kids.append(unitRow(u, s, background: true, prot)) }
        var r = Row(id: s.itemID.stringValue, item: s.itemID, kind: .session, section: .claude, title: s.title,
                    badge: badge, location: loc, state: state, tone: tone, glyphs: glyphs, bytes: s.total,
                    protection: p, children: kids)
        r.subject = FilterSubject(session: s, now: now)
        r.started = s.startedAt
        r.lastActive = s.busy ? now : s.idleSince
        r.pid = s.key.pid
        r.rss = s.selfRSS
        r.cpu = s.cpuPercent
        r.tooltip = Fmt.tilde(s.cwd)
        return r
    }

    static func unitRow(_ u: LinkedUnit, _ s: ClaudeSession, background: Bool, _ prot: [ItemID: Protection]) -> Row {
        let id = u.itemID
        var glyphs: [Glyph] = [.locked]
        if u.isAutomationBrowser { glyphs.append(.automation) }
        let title = u.isAutomationBrowser ? "Automation browser (\(u.command))" : u.command
        var r = Row(id: id.stringValue, item: id, kind: .process, section: .claude, title: title,
                    location: "pid \(u.root.pid)" + (u.pgid != u.root.pid ? " · pgid \(u.pgid)" : "")
                        + (u.members.count > 1 ? " · \(u.members.count) processes" : ""),
                    state: background ? "background" : "child", tone: .muted, glyphs: glyphs, bytes: u.footprint,
                    protection: prot[id] ?? .locked(Planner.childProcessReason))
        r.pid = u.root.pid
        r.tooltip = u.argv.isEmpty ? u.command : u.argv.joined(separator: " ")
        return r
    }

    // MARK: Leftovers

    static func leftoversSection(_ w: WorldSnapshot, _ prot: [ItemID: Protection], _ o: ListOptions,
                                 _ q: FilterQuery, _ now: Date) -> Row? {
        let ls = w.claude.leftovers
        if ls.isEmpty && q.isEmpty { return nil }
        var rows = ls.map { leftoverRow($0, prot, now) }
        if !q.isEmpty { rows = rows.filter { $0.subject.map(q.matches) ?? false } }
        if !q.isEmpty && rows.isEmpty {
            if ls.isEmpty { return nil }
            rows.append(note(.noMatches, .leftovers, "No leftovers match “\(q.source)”"))
        }
        return Row(id: "section:leftovers", item: nil, kind: .section, section: .leftovers, title: "LEFTOVERS",
                   badge: "from sessions that already ended · " + Fmt.plural(ls.count, "group"),
                   bytes: w.claude.leftoversTotal, children: rows, selectable: false)
    }

    static func leftoverRow(_ l: LeftoverGroup, _ prot: [ItemID: Protection], _ now: Date) -> Row {
        let p = prot[l.id] ?? .confirm([.leftover])
        var parts: [String] = []
        if let c = l.cwd ?? l.unit.cwd {
            let comps = c.components(separatedBy: "/.claude/worktrees/")
            parts.append(comps.count > 1 ? "\(URL(fileURLWithPath: comps[0]).lastPathComponent) ⎇ \(comps[1])"
                                         : URL(fileURLWithPath: c).lastPathComponent)
        }
        if let t = l.sessionTitle { parts.append("“\(t)”") }
        parts.append("pgid \(l.unit.pgid)")
        var r = Row(id: l.id.stringValue, item: l.id, kind: .leftover, section: .leftovers, title: l.unit.command,
                    location: parts.joined(separator: " · "),
                    state: "orphaned " + Fmt.age(now.timeIntervalSince(l.startedAt)), tone: .warn,
                    glyphs: p.isLocked ? [.locked] : [], bytes: l.unit.footprint, protection: p)
        r.subject = FilterSubject(leftover: l, now: now)
        r.started = l.startedAt
        r.pid = l.unit.root.pid
        r.tooltip = (l.unit.argv.isEmpty ? l.unit.command : l.unit.argv.joined(separator: " "))
            + ((l.cwd ?? l.unit.cwd).map { "\n" + Fmt.tilde($0) } ?? "")
        return r
    }

    static func note(_ k: NoteKind, _ s: ListSection, _ text: String) -> Row {
        let key: String
        switch k {
        case .chromeNotRunning: key = "notRunning"
        case .waitingForHelper: key = "waiting"
        case .helperStale: key = "stale"
        case .perTabUnavailable: key = "perTab"
        case .helperBlind: key = "helperBlind"
        case .noSessions: key = "noSessions"
        case .noLeftovers: key = "noLeftovers"
        case .noMatches: key = "noMatches"
        }
        var r = Row(id: "note:\(s.rawValue):\(key)", item: nil, kind: .note, section: s, title: text,
                    tone: .muted, selectable: false, pinRank: -5)
        r.note = k
        return r
    }

    // MARK: Sorting

    static func sortTree(_ r: Row, _ o: ListOptions) -> Row {
        var r = r
        r.children = sortRows(r.children.map { sortTree($0, o) }, o)
        return r
    }

    public static func sortRows(_ rows: [Row], _ o: ListOptions) -> [Row] {
        rows.enumerated().sorted { a, b in
            if a.element.pinRank != b.element.pinRank { return a.element.pinRank < b.element.pinRank }
            let c = compare(a.element, b.element, o.sort)
            if c != .orderedSame { return o.ascending ? c == .orderedAscending : c == .orderedDescending }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func compare(_ a: Row, _ b: Row, _ col: SortColumn) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T?, _ y: T?) -> ComparisonResult {
            switch (x, y) {
            case let (x?, y?): x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            case (nil, nil): .orderedSame
            case (nil, _): .orderedAscending
            case (_, nil): .orderedDescending
            }
        }
        func str(_ x: String, _ y: String) -> ComparisonResult { x.localizedStandardCompare(y) }
        let r: ComparisonResult
        switch col {
        case .memory: r = cmp(a.bytes, b.bytes)
        case .name: r = str(a.title, b.title)
        case .location: r = str(a.location, b.location)
        case .state: r = str(a.state, b.state)
        case .age: r = cmp(b.started, a.started)          // older = larger
        case .pid: r = cmp(a.pid, b.pid)
        case .rss: r = cmp(a.rss, b.rss)
        case .cpu: r = cmp(a.cpu, b.cpu)
        case .lastActive: r = cmp(a.lastActive, b.lastActive)
        }
        if r != .orderedSame || col == .memory { return r }
        return cmp(a.bytes, b.bytes)
    }

    // MARK: Brackets

    /// Marks runs of adjacent sibling tabs that share a renderer (the ⛓ gutter bracket).
    public static func assignBrackets(_ r: Row) -> Row {
        var r = r
        var kids = r.children.map(assignBrackets)
        var i = 0
        while i < kids.count {
            kids[i].bracket = nil
            guard let key = kids[i].shareKey else { i += 1; continue }
            var j = i + 1
            while j < kids.count, kids[j].shareKey == key { j += 1 }
            if j - i > 1 {
                for k in i..<j { kids[k].bracket = k == i ? .top : k == j - 1 ? .bottom : .middle }
            }
            i = j
        }
        r.children = kids
        return r
    }

    // MARK: Sort freeze (§7.1)

    /// parent id ("" for the root) → child ids in display order.
    public static func order(of rows: [Row]) -> [String: [String]] {
        var out: [String: [String]] = ["": rows.map(\.id)]
        func visit(_ r: Row) {
            out[r.id] = r.children.map(\.id)
            r.children.forEach(visit)
        }
        rows.forEach(visit)
        return out
    }

    /// Re-applies a previous order: rows that were already there keep their relative order, new rows go
    /// after them (in sorted order), vanished rows drop out. `outOfDate` is true when the result differs from
    /// the freshly sorted order (the "↕ Order out of date" chip).
    public static func freeze(_ rows: [Row], previous: [String: [String]]) -> (rows: [Row], outOfDate: Bool) {
        var outOfDate = false
        func apply(_ list: [Row], parent: String) -> [Row] {
            var list = list.map { r -> Row in
                var r = r
                r.children = apply(r.children, parent: r.id)
                return r
            }
            guard let prev = previous[parent] else { return list }
            let rank = Dictionary(prev.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let sorted = list.map(\.id)
            list = list.enumerated().sorted { a, b in
                switch (rank[a.element.id], rank[b.element.id]) {
                case let (x?, y?): x < y
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): a.offset < b.offset
                }
            }.map(\.element)
            if list.map(\.id) != sorted { outOfDate = true }
            return list
        }
        let result = apply(rows, parent: "").map(assignBrackets)
        return (result, outOfDate)
    }

    // MARK: Lookup helpers

    public static func index(_ rows: [Row]) -> [String: Row] {
        var out: [String: Row] = [:]
        for r in rows { r.walk { out[$0.id] = $0 } }
        return out
    }

    /// Every selectable row id in display order, skipping collapsed children when `expanded` is given.
    public static func selectableIDs(_ rows: [Row]) -> [String] {
        var out: [String] = []
        for r in rows { r.walk { if $0.selectable { out.append($0.id) } } }
        return out
    }
}
