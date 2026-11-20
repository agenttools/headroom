// Rex access (the Rex counterpart of Tmux.swift; SPEC §5 Rex, §7.6 Jump, §7.7 session Undo).
//
// In Rex terms a session holds windows (tabs) and a window holds blocks (panes), drawn in layers: the first layer is
// tiled and fills the window, later ones float and can be minimized; a zoomed block is drawn over the whole window.
//
// Which multiplexer a claude runs in is decided WITHOUT any rex call (RexProcess): walking up the ppid chain from the
// claude, the first boundary met wins — a tmux pane pid or tmux process means tmux, a Rex server means Rex. So tmux
// inside a Rex block is tmux, and tmux attribution is unchanged. The claude's block then comes from its own
// REX_BLOCK/REX_SESSION (kept by the env filter); rex calls only add layout and visibility.
//
// Every call is `<env.rexPath> --autostart=false [-S <HEADROOM_REX_SERVER>] --timeout <n>s [-C <client>] …` through
// Shell.run, with every REX_* variable (REX_SERVER, REX_SESSION, REX_BLOCK, REX_CLIENT …) removed from the child's
// environment: a call never starts a server and never defaults to "the block Headroom itself runs in". `rex server …` is refused unless
// HEADROOM_REX_SERVER names a private server. Tests use RexStub (a fake rex) or, opt-in, a private server.
// NEVER run send/kill/focus/server against the user's real Rex server in tests.
//
// Read-only calls: sessions(), inspect(), state(), capture(), whoami(). Mutating calls (used only by Jump and Undo,
// which the user triggers): focus(), select(), newWindow(), newSession(), sendLine().

import Foundation
import HeadroomContracts

// MARK: - Process rules (pure; no rex call)

/// The Rex servers in a process table and each block's first process.
public struct RexTopology: Sendable, Hashable {
    public let servers: Set<Int32>
    /// Each block's first process in the table: the shell under the root-owned `login` (the counterpart of a tmux
    /// pane_pid), or the command itself for a `rex run` block; also `login` when the table has it (fixtures).
    public let blockRoots: Set<Int32>
    public init(servers: Set<Int32>, blockRoots: Set<Int32>) { self.servers = servers; self.blockRoots = blockRoots }
    public static let none = RexTopology(servers: [], blockRoots: [])
}

/// The nearest multiplexer boundary above a process.
public enum RexBoundary: Sendable, Hashable { case rex(server: Int32), tmux, none }

public enum RexProcess {
    static let serverAppSuffix = "/Rex Server.app/Contents/MacOS/rex"

    /// Executable basename "rex" and argv (after argv[0]) containing the adjacent pair "server","run".
    /// argv nil (unreadable): path ends with "/Rex Server.app/Contents/MacOS/rex". (`rex server logs --follow`,
    /// which Rex.app runs, is not a server.)
    public static func isServer(path: String, argv: [String]?) -> Bool {
        guard Ownership.basename(path) == "rex" else { return false }
        guard let argv else { return path.hasSuffix(serverAppSuffix) }
        let rest = Array(argv.dropFirst())
        return zip(rest, rest.dropFirst()).contains { $0 == "server" && $1 == "run" }
    }

    /// argv is read only for processes whose executable basename is "rex"; parentPid only for missing parents.
    public static func topology(in t: ProcessTable, argv: (ProcKey) -> [String]?,
                                parentPid: (Int32) -> Int32?) -> RexTopology {
        var servers: Set<Int32> = []
        for s in t.byPid.values where Ownership.basename(s.path) == "rex" {
            if isServer(path: s.path, argv: argv(s.key)) { servers.insert(s.pid) }
        }
        guard !servers.isEmpty else { return .none }
        var hidden: [Int32: Int32?] = [:]          // memo: parent of a ppid that is not in the table
        func parentOfMissing(_ pid: Int32) -> Int32? {
            if let m = hidden[pid] { return m }
            let p = parentPid(pid)
            hidden[pid] = .some(p)
            return p
        }
        var roots: Set<Int32> = []
        for s in t.byPid.values where s.ppid > 1 {
            if servers.contains(s.ppid) {
                // A block's first process: `login` (when the table has it; its shell is found by the next rule)
                // or the command of a `rex run` block.
                roots.insert(s.pid)
            } else if let pp = t.byPid[s.ppid] {
                if Ownership.basename(pp.path) == "login", servers.contains(pp.ppid) { roots.insert(s.pid) }
            } else if let gp = parentOfMissing(s.ppid), servers.contains(gp) {
                roots.insert(s.pid)                   // under the root-owned login that scan() cannot see
            }
        }
        return RexTopology(servers: servers, blockRoots: roots)
    }

    /// Convenience: argv = sys.args($0)?.argv, parentPid = sys.parentPid.
    public static func topology(in t: ProcessTable, sys: any SysKit) -> RexTopology {
        topology(in: t, argv: { sys.args($0)?.argv }, parentPid: { sys.parentPid($0) })
    }

    /// panePids.contains(pid), or (in the table) TmuxClient.isTmuxProcess(path:argv0:).
    public static func isTmux(_ pid: Int32, in t: ProcessTable, panePids: Set<Int32>,
                              argv0: (ProcKey) -> String?) -> Bool {
        if panePids.contains(pid) { return true }
        guard let s = t.byPid[pid] else { return false }
        return TmuxClient.isTmuxProcess(path: s.path, argv0: argv0(s.key))
    }

    /// Nearest boundary above `pid`. isTmux(pid) → .tmux. Then up to 64 steps: p = t.byPid[cur]?.ppid ?? parentPid(cur);
    /// nil, ≤ 1 or already seen → .none; servers ∋ p → .rex(server: p); isTmux(p) → .tmux; cur = p.
    public static func boundary(of pid: Int32, in t: ProcessTable, servers: Set<Int32>,
                                parentPid: (Int32) -> Int32?, isTmux: (Int32) -> Bool) -> RexBoundary {
        if isTmux(pid) { return .tmux }
        var cur = pid
        var seen: Set<Int32> = [pid]
        for _ in 0..<64 {
            guard let p = t.byPid[cur]?.ppid ?? parentPid(cur), p > 1, seen.insert(p).inserted else { return .none }
            if servers.contains(p) { return .rex(server: p) }
            if isTmux(p) { return .tmux }
            cur = p
        }
        return .none
    }

    /// Convenience over sys + tmux pane pids.
    public static func boundary(of pid: Int32, in t: ProcessTable, topology: RexTopology, sys: any SysKit,
                                tmuxPanePids: Set<Int32>) -> RexBoundary {
        boundary(of: pid, in: t, servers: topology.servers, parentPid: { sys.parentPid($0) },
                 isTmux: { isTmux($0, in: t, panePids: tmuxPanePids, argv0: { sys.args($0)?.argv0 }) })
    }
}

// MARK: - What rex reports

/// One row of `rex ls --json`.
public struct RexSessionRef: Sendable, Hashable {
    public let sessionId, label: String
    public init(sessionId: String, label: String) { self.sessionId = sessionId; self.label = label }
}

/// A Rex app (not a CLI) client attached to a session, from `session inspect`'s `clients`.
public struct RexAppClient: Sendable, Hashable {
    public let clientId: String
    /// principal.transport is "unix" (or absent).
    public let local: Bool
    /// connection_state == "connected"; a "lost" client still counts as attached (Rex keeps it ~60 s).
    public let connected: Bool
    public let connectedAt: Date?
    public init(clientId: String, local: Bool, connected: Bool, connectedAt: Date?) {
        self.clientId = clientId; self.local = local; self.connected = connected; self.connectedAt = connectedAt
    }
}

/// One block (pane) with its place and what decides whether it is drawn.
public struct RexBlock: Sendable, Hashable {
    public let blockId, sessionId, sessionLabel, windowId, windowLabel: String
    /// 1-based.
    public let windowIndex, paneIndex: Int
    /// The block's own label, e.g. "shell".
    public let label: String
    /// windowId == the session's active_window_id, or the active tab is unknown (absent, null, or naming no listed
    /// tab): then every tab counts as active (unknown means protected).
    public let windowActive: Bool
    /// This block is the window's zoomed_block_id.
    public let zoomed: Bool
    /// The window has a zoomed block (null/absent = none).
    public let windowZoomed: Bool
    /// Layer kind != "tiled" (unknown kinds count as floating).
    public let floating: Bool
    /// Layer state == "minimized".
    public let minimized: Bool
    /// ≥ 1 client in the session's clients that is not a known non-viewer (kind cli or agent), in any connection
    /// state: an app client, or one whose kind or id Rex did not report, or a kind Headroom does not know.
    public let sessionAttached: Bool
    public init(blockId: String, sessionId: String, sessionLabel: String, windowId: String, windowLabel: String,
                windowIndex: Int, paneIndex: Int, label: String, windowActive: Bool, zoomed: Bool,
                windowZoomed: Bool, floating: Bool, minimized: Bool, sessionAttached: Bool) {
        self.blockId = blockId; self.sessionId = sessionId; self.sessionLabel = sessionLabel
        self.windowId = windowId; self.windowLabel = windowLabel; self.windowIndex = windowIndex
        self.paneIndex = paneIndex; self.label = label; self.windowActive = windowActive; self.zoomed = zoomed
        self.windowZoomed = windowZoomed; self.floating = floating; self.minimized = minimized
        self.sessionAttached = sessionAttached
    }
    /// Drawn in its window: not minimized, and floating (over any zoom), or nothing zoomed, or itself zoomed.
    public var drawn: Bool { !minimized && (floating || !windowZoomed || zoomed) }
    /// Rex has no "current session": every drawn block of the active tab of an attached session counts.
    public var visible: Bool { sessionAttached && windowActive && drawn }
}

/// One `rex session inspect <id> --json`.
public struct RexInspect: Sendable, Hashable {
    public let sessionId, label: String
    public let blocks: [RexBlock]
    /// App clients with an id (Jump targets). Whether the session counts as attached is RexBlock.sessionAttached.
    public let appClients: [RexAppClient]
    public init(sessionId: String, label: String, blocks: [RexBlock], appClients: [RexAppClient]) {
        self.sessionId = sessionId; self.label = label; self.blocks = blocks; self.appClients = appClients
    }
}

/// Everything one discovery pass learned (`ls` + one `session inspect` per session).
public struct RexState: Sendable, Hashable {
    /// `ls` succeeded.
    public var reachable: Bool
    /// reachable, every session in `ls` inspected (so ≤ maxSessions sessions), and every inspect succeeded before
    /// the deadline.
    public var complete: Bool
    public var sessions: [RexSessionRef]
    /// ls order, then layout order.
    public var blocks: [RexBlock]
    /// sessionId → app clients, with a key for every session that was inspected successfully.
    public var appClients: [String: [RexAppClient]]
    public init(reachable: Bool, complete: Bool, sessions: [RexSessionRef], blocks: [RexBlock],
                appClients: [String: [RexAppClient]]) {
        self.reachable = reachable; self.complete = complete; self.sessions = sessions; self.blocks = blocks
        self.appClients = appClients
    }
    public static let empty = RexState(reachable: false, complete: false, sessions: [], blocks: [], appClients: [:])
    /// Every session's app clients (in session order), de-duplicated by clientId.
    public var allAppClients: [RexAppClient] {
        var seen: Set<String> = []
        var out: [RexAppClient] = []
        let order = sessions.map(\.sessionId) + appClients.keys.sorted().filter { k in !sessions.contains { $0.sessionId == k } }
        for id in order {
            for c in appClients[id] ?? [] where seen.insert(c.clientId).inserted { out.append(c) }
        }
        return out
    }
}

/// `rex whoami --json` (the server's identity, not the CLI's).
public struct RexServerInfo: Sendable, Hashable {
    public let pid: Int32
    public let version: String
    public let apiRevision: Int
    public init(pid: Int32, version: String, apiRevision: Int) {
        self.pid = pid; self.version = version; self.apiRevision = apiRevision
    }
}

/// The terminal a `window new` / `new` created.
public struct RexNewTerminal: Sendable, Hashable {
    public let sessionId, windowId, blockId: String
    public init(sessionId: String, windowId: String, blockId: String) {
        self.sessionId = sessionId; self.windowId = windowId; self.blockId = blockId
    }
}

// MARK: - Client

public struct RexClient: Sendable {
    public let env: HeadroomEnv
    /// rex --timeout per call, in seconds (Shell's own timeout is one second longer).
    public static let readTimeout = 2, peekTimeout = 4, jumpTimeout = 5, undoTimeout = 10
    /// Wall-clock limit of one state() pass (ls + inspects); the rest is cancelled.
    public static let stateDeadline: TimeInterval = 3
    public static let maxSessions = 64, maxConcurrent = 8
    public init(env: HeadroomEnv = .current) { self.env = env }

    /// Runs rex with the configured binary and server: `rexBaseArgs --timeout <n>s [-C client] args`.
    /// Refused with nothing run: binary not executable → 127; HEADROOM_REX_SERVER not a `unix:///` address → 2;
    /// `server …` without HEADROOM_REX_SERVER (it would reach the user's own server) → 2.
    public func run(_ args: [String], timeout: Int = RexClient.readTimeout, client: String? = nil) async -> Shell.Result {
        guard FileManager.default.isExecutableFile(atPath: env.rexPath) else {
            return Shell.Result(status: 127, stdout: "", stderr: "rex not found at \(env.rexPath)", timedOut: false)
        }
        if let s = env.rexServer, !s.hasPrefix("unix:///") {
            return Shell.Result(status: 2, stdout: "",
                                stderr: "HEADROOM_REX_SERVER must be a unix:/// address, not \(s); rex not run",
                                timedOut: false)
        }
        if args.first == "server", env.rexServer == nil {
            return Shell.Result(status: 2, stdout: "",
                                stderr: "rex server … runs only against HEADROOM_REX_SERVER; rex not run", timedOut: false)
        }
        let argv = env.rexBaseArgs + ["--timeout", "\(timeout)s"] + (client.map { ["-C", $0] } ?? []) + args
        return await Shell.run(env.rexPath, argv, timeout: Double(timeout) + 1, environment: childEnvironment)
    }

    /// ProcessInfo environment minus every REX_* key (always) — REX_SERVER, REX_SESSION, REX_BLOCK, REX_CLIENT and
    /// what else a Rex block exports (REX_BIN_DIR …): Headroom (or `swift test`) may itself run inside a Rex block,
    /// and rex would otherwise default to that server, session, block or client.
    var childEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("REX_") }
    }

    // MARK: - Read-only

    /// `ls --json`. nil when rex is missing, no server runs, or the output is not understood.
    public func sessions() async -> [RexSessionRef]? {
        let r = await run(["ls", "--json"])
        return r.ok ? Self.parseSessions(r.stdout) : nil
    }

    /// `session inspect <id> --json`.
    public func inspect(_ sessionId: String) async -> RexInspect? {
        let r = await run(["session", "inspect", sessionId, "--json"])
        return r.ok ? Self.parseInspect(r.stdout) : nil
    }

    private enum StateEvent: Sendable { case inspected(String, RexInspect?), deadline }

    /// `ls`, then one `session inspect` per session (at most maxSessions, maxConcurrent at a time). The sessions in
    /// `wanted` (those that hold a claude: their REX_SESSION) that `ls` lists are inspected first and always; the
    /// others follow in `ls` order, up to maxSessions in all. Whatever has not finished when `deadline` seconds have
    /// passed since the start is cancelled (Shell stops the children it started) and the state is marked incomplete.
    /// `.empty` when `ls` fails.
    public func state(sessionsFirst wanted: Set<String> = [],
                      deadline: TimeInterval = RexClient.stateDeadline) async -> RexState {
        let start = Date()
        guard let refs = await sessions() else { return .empty }
        let first = refs.filter { wanted.contains($0.sessionId) }
        let rest = refs.filter { !wanted.contains($0.sessionId) }
        let want = first + rest.prefix(max(0, Self.maxSessions - first.count))
        let remaining = max(0, deadline - Date().timeIntervalSince(start))
        let (results, allDone) = await withTaskGroup(of: StateEvent.self,
                                                     returning: ([String: RexInspect], Bool).self) { g in
            var results: [String: RexInspect] = [:]
            var ok = true
            guard !want.isEmpty else { return (results, ok) }
            g.addTask {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return .deadline
            }
            var next = 0, pending = 0
            while next < want.count && pending < Self.maxConcurrent {
                let id = want[next].sessionId; next += 1; pending += 1
                g.addTask { .inspected(id, await self.inspect(id)) }
            }
            while pending > 0, let e = await g.next() {
                switch e {
                case .deadline:
                    g.cancelAll()
                    return (results, false)
                case let .inspected(id, ins):
                    pending -= 1
                    if let ins { results[id] = ins } else { ok = false }
                    if next < want.count {
                        let nid = want[next].sessionId; next += 1; pending += 1
                        g.addTask { .inspected(nid, await self.inspect(nid)) }
                    }
                }
            }
            g.cancelAll()                                   // ends the sleeper
            return (results, ok)
        }
        var blocks: [RexBlock] = []
        var clients: [String: [RexAppClient]] = [:]
        for ref in refs {                                   // ls order, whatever order they were inspected in
            guard let ins = results[ref.sessionId] else { continue }
            blocks += ins.blocks
            clients[ref.sessionId] = ins.appClients
        }
        return RexState(reachable: true, complete: allDone && want.count == refs.count, sessions: refs,
                        blocks: blocks, appClients: clients)
    }

    /// Read-only `capture -s <session> -b <block> --trim`, last `lines` lines. nil on failure, or when the output
    /// reached Shell's cap (Shell keeps the FIRST 8 MB of a primary-screen scrollback, so the tail would be wrong).
    public func capture(session: String, block: String, lines: Int = 60) async -> String? {
        let r = await run(["capture", "-s", session, "-b", block, "--trim"], timeout: Self.peekTimeout)
        guard r.ok, r.stdout.utf8.count < Shell.defaultMaxOutput - 16 else { return nil }
        return Self.tail(r.stdout, lines: lines)
    }

    /// `whoami --json`: the server's pid, version and API revision.
    public func whoami() async -> RexServerInfo? {
        let r = await run(["whoami", "--json"])
        return r.ok ? Self.parseWhoami(r.stdout) : nil
    }

    // MARK: - Mutating (user-triggered only: Jump and Undo)

    /// Server side of Jump: `focus -s <session> <block>` makes the block's tab active and focuses the block.
    /// This changes shared session state (as tmux select-window does).
    public func focus(session: String, block: String) async -> Bool {
        await run(["focus", "-s", session, block], timeout: Self.jumpTimeout).ok
    }

    /// App side of Jump: `do session.select session_id=… window_id=…`, sent to `client` (or Rex's default app client
    /// when nil). Needs Remote Control turned on in the app (off by default). The whole result is returned so a
    /// caller can tell the user why it failed (selectFailureReason).
    @discardableResult
    public func select(session: String, window: String, client: String?) async -> Shell.Result {
        await run(["do", "session.select", "session_id=\(session)", "window_id=\(window)"],
                  timeout: Self.jumpTimeout, client: client)
    }

    /// First non-empty stderr line of a failed rex call, without rex's "Error: " prefix.
    static func errorLine(_ r: Shell.Result) -> String? {
        for raw in r.stderr.split(separator: "\n") {
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Error:") { l = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            if !l.isEmpty { return l }
        }
        return nil
    }

    /// Why `do session.select` failed, for the note Jump or Undo shows. `action` names what the user ran ("Jump",
    /// "Undo"). Remote Control is named only when rex says nothing more specific: exit 3 is a client target that was
    /// not found (Rex.app not connected yet, or it reconnected with a new client id), and an app that refuses says why.
    public static func selectFailureReason(_ r: Shell.Result, action: String) -> String {
        if r.timedOut { return "Rex.app did not answer. Make sure it has a window open." }
        let msg = errorLine(r)
        if r.status == 3 {
            return "Rex.app is not connected to the Rex server" + (msg.map { " (\($0))" } ?? "") + "."
        }
        if let msg { return msg.hasSuffix(".") ? msg : msg + "." }   // the app's own refusal names its cause
        return "Turn on Remote Control in Rex so \(action) can switch sessions."
    }

    /// `window new -s <session> <name> -c <cwd> --focus=false --json`: a new tab that does not take focus.
    public func newWindow(session: String, name: String, cwd: String) async -> RexNewTerminal? {
        let r = await run(["window", "new", "-s", session, Self.positional(name, "claude"), "-c", cwd,
                           "--focus=false", "--json"], timeout: Self.undoTimeout)
        return r.ok ? Self.parseNewWindow(r.stdout, sessionId: session) : nil
    }

    /// `new <label> -c <cwd> --window=<name> --json`: a new session with one tab.
    public func newSession(label: String, cwd: String, windowName: String) async -> RexNewTerminal? {
        let r = await run(["new", Self.positional(label, "headroom"), "-c", cwd,
                           "--window=\(Self.positional(windowName, "claude"))", "--json"], timeout: Self.undoTimeout)
        return r.ok ? Self.parseNewSession(r.stdout) : nil
    }

    /// Types `text` (`send`), then presses Return (`send-key enter`). Text that starts with "-" (rex would read a
    /// flag) or contains a line break (it would run early) is refused and nothing runs.
    public func sendLine(session: String, block: String, _ text: String) async -> Bool {
        guard !text.hasPrefix("-"), !text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return false
        }
        guard await run(["send", "-s", session, "-b", block, text], timeout: Self.undoTimeout).ok else { return false }
        return await run(["send-key", "-s", session, "-b", block, "enter"], timeout: Self.undoTimeout).ok
    }

    // MARK: - Parsing (pure; unit tested on hand-written fixtures). Lenient: unknown keys are ignored.

    static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// `{"sessions":[{session_id,label}]}`. Rows without a session_id are skipped; nil when not that shape.
    public static func parseSessions(_ json: String) -> [RexSessionRef]? {
        guard let o = object(json), let rows = o["sessions"] as? [Any] else { return nil }
        return rows.compactMap { row in
            guard let d = row as? [String: Any], let id = d["session_id"] as? String else { return nil }
            return RexSessionRef(sessionId: id, label: d["label"] as? String ?? "")
        }
    }

    /// `session inspect --json`: blocks in tab order, then layer order, then layout order; app clients with an id.
    /// Viewer state Headroom cannot read counts as protected (unknown means protected): an unknown active tab makes
    /// every tab active, and any client that is not a known non-viewer (cli, agent) makes the session attached.
    public static func parseInspect(_ json: String) -> RexInspect? {
        guard let o = object(json), let sid = o["session_id"] as? String else { return nil }
        let label = o["label"] as? String ?? ""
        let windows = o["windows"] as? [Any] ?? []
        let windowIds = Set(windows.compactMap { ($0 as? [String: Any])?["window_id"] as? String })
        // Unknown active tab (absent, null, not a string, or naming no listed tab): every tab counts as active.
        let active = (o["active_window_id"] as? String).flatMap { windowIds.contains($0) ? $0 : nil }
        var clients: [RexAppClient] = []
        var viewers = 0
        for case let c as [String: Any] in o["clients"] as? [Any] ?? [] {
            let kind = (c["info"] as? [String: Any])?["kind"] as? String
            // Only a known non-viewer is skipped. app, other, an absent or an unknown kind may be showing the session.
            if kind == "cli" || kind == "agent" { continue }
            viewers += 1
            guard kind == "app", let id = c["client_id"] as? String else { continue }   // Jump targets only
            let transport = (c["principal"] as? [String: Any])?["transport"] as? String
            clients.append(RexAppClient(clientId: id, local: (transport ?? "unix") == "unix",
                                        connected: c["connection_state"] as? String == "connected",
                                        connectedAt: (c["connected_at"] as? String).flatMap(parseDate)))
        }
        let attached = viewers > 0
        var blocks: [RexBlock] = []
        for (wi, wAny) in windows.enumerated() {
            guard let w = wAny as? [String: Any], let wid = w["window_id"] as? String else { continue }
            let wlabel = w["label"] as? String ?? ""
            let zoomedId = w["zoomed_block_id"] as? String
            var pane = 0
            for case let l as [String: Any] in w["layers"] as? [Any] ?? [] {
                let floating = (l["kind"] as? String ?? "tiled") != "tiled"
                let minimized = l["state"] as? String == "minimized"
                for case let b as [String: Any] in l["blocks"] as? [Any] ?? [] {
                    guard let bid = b["block_id"] as? String else { continue }
                    pane += 1
                    blocks.append(RexBlock(
                        blockId: bid, sessionId: sid, sessionLabel: label, windowId: wid, windowLabel: wlabel,
                        windowIndex: wi + 1, paneIndex: pane, label: b["label"] as? String ?? "",
                        windowActive: active.map { wid == $0 } ?? true, zoomed: zoomedId == bid,
                        windowZoomed: zoomedId != nil,
                        floating: floating, minimized: minimized, sessionAttached: attached))
                }
            }
        }
        return RexInspect(sessionId: sid, label: label, blocks: blocks, appClients: clients)
    }

    /// `whoami --json`: pid, rex_version and api_revision are all required.
    public static func parseWhoami(_ json: String) -> RexServerInfo? {
        guard let o = object(json), let pid = (o["pid"] as? Int).flatMap({ Int32(exactly: $0) }),
              let v = o["rex_version"] as? String, let api = o["api_revision"] as? Int else { return nil }
        return RexServerInfo(pid: pid, version: v, apiRevision: api)
    }

    /// `window new --json`: `{window_id, block_ids:[…]}`.
    public static func parseNewWindow(_ json: String, sessionId: String) -> RexNewTerminal? {
        guard let o = object(json), let wid = o["window_id"] as? String,
              let bid = (o["block_ids"] as? [Any])?.first as? String else { return nil }
        return RexNewTerminal(sessionId: sessionId, windowId: wid, blockId: bid)
    }

    /// `new --json`: `{session_id, initial_windows:[{window_id, block_ids:[…]}]}`.
    public static func parseNewSession(_ json: String) -> RexNewTerminal? {
        guard let o = object(json), let sid = o["session_id"] as? String,
              let w = (o["initial_windows"] as? [Any])?.first as? [String: Any],
              let wid = w["window_id"] as? String, let bid = (w["block_ids"] as? [Any])?.first as? String else {
            return nil
        }
        return RexNewTerminal(sessionId: sid, windowId: wid, blockId: bid)
    }

    /// ISO 8601, with or without fractional seconds (Rex writes microseconds).
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - Placement and choices (pure)

    /// A discovered block as a placed RexLoc; visible = b.visible.
    public static func location(of b: RexBlock) -> RexLoc {
        RexLoc(blockId: b.blockId, sessionId: b.sessionId, sessionLabel: b.sessionLabel, windowId: b.windowId,
               windowLabel: b.windowLabel, windowIndex: b.windowIndex, paneIndex: b.paneIndex, visible: b.visible)
    }

    /// A claude's RexLoc from its REX_BLOCK / REX_SESSION. blockEnv must start "block:". Found in state.blocks →
    /// location(of:). Otherwise (discovery failed, timed out, or the block is unknown) an UNPLACED loc that counts as
    /// visible (fail-closed: unknown means protected) — this needs sessionEnv starting "session:". Otherwise nil.
    public static func locate(blockEnv: String?, sessionEnv: String?, state: RexState) -> RexLoc? {
        guard let bid = blockEnv, bid.hasPrefix("block:") else { return nil }
        if let b = state.blocks.first(where: { $0.blockId == bid }) { return location(of: b) }
        guard let sid = sessionEnv, sid.hasPrefix("session:") else { return nil }
        let label = state.sessions.first { $0.sessionId == sid }?.label ?? ""
        return RexLoc(blockId: bid, sessionId: sid, sessionLabel: label, visible: true)
    }

    /// The LOCAL (transport unix) app client to send `session.select` to: a connected local app client of `session`,
    /// else any connected local app client, most recently connected first. nil when none is connected. A remote
    /// device's client is never chosen: `session.select` would switch what that device shows.
    public static func jumpClient(session: String, state: RexState) -> RexAppClient? {
        func best(_ cs: [RexAppClient]) -> RexAppClient? {
            cs.filter { $0.connected && $0.local }
                .max { ($0.connectedAt ?? .distantPast) < ($1.connectedAt ?? .distantPast) }
        }
        return best(state.appClients[session] ?? []) ?? best(state.allAppClients)
    }

    /// A connected app client from another device. Without `-C`, rex's default client could then be that device.
    public static func remoteAppConnected(_ state: RexState) -> Bool {
        state.allAppClients.contains { $0.connected && !$0.local }
    }

    /// Last `lines` lines; a trailing newline does not count as a line (and is kept).
    public static func tail(_ text: String, lines: Int) -> String {
        var parts = text.components(separatedBy: "\n")
        let trailing = text.hasSuffix("\n")
        if trailing { parts.removeLast() }
        let kept = parts.suffix(max(lines, 0))
        guard !kept.isEmpty else { return "" }
        return kept.joined(separator: "\n") + (trailing ? "\n" : "")
    }

    /// Undo recovery after `window new` failed or timed out (it may still have worked): the one block of the one
    /// window in `after` whose windowId is not in `before` and whose windowLabel == positional(name, "claude");
    /// first block by paneIndex. Zero or several such windows → nil. `before` must come from an inspect that
    /// SUCCEEDED; with an unknown `before`, do not recover (an old tab with the same label would be adopted).
    public static func recoverNewWindow(before: [RexBlock], after: [RexBlock], sessionId: String,
                                        name: String) -> RexNewTerminal? {
        let n = positional(name, "claude")
        let old = Set(before.map(\.windowId))
        let fresh = after.filter { $0.sessionId == sessionId && !old.contains($0.windowId) && $0.windowLabel == n }
        guard Set(fresh.map(\.windowId)).count == 1,
              let b = fresh.min(by: { $0.paneIndex < $1.paneIndex }) else { return nil }
        return RexNewTerminal(sessionId: sessionId, windowId: b.windowId, blockId: b.blockId)
    }

    /// Undo recovery after `new` failed or timed out: the one session id in `after` not in `before` whose label ==
    /// positional(label, "headroom"); else nil.
    public static func recoverNewSession(before: [RexSessionRef], after: [RexSessionRef], label: String) -> String? {
        let l = positional(label, "headroom")
        let old = Set(before.map(\.sessionId))
        let fresh = after.filter { !old.contains($0.sessionId) && $0.label == l }
        return fresh.count == 1 ? fresh[0].sessionId : nil
    }

    /// A safe positional argument: whitespace/newlines trimmed and leading "-" removed (repeatedly, so the result
    /// never reads as a flag); empty → fallback.
    static func positional(_ s: String, _ fallback: String) -> String {
        var t = Substring(s)
        while let c = t.first, c == "-" || c.isWhitespace || c.isNewline { t.removeFirst() }
        let r = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? fallback : r
    }
}
