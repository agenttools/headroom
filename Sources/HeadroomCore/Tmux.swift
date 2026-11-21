// tmux access (SPEC §5 tmux, §7.6 Jump, §7.7 session Undo).
//
// Every call is `<env.tmuxPath> -u <env.tmuxBaseArgs> …` through Shell.run (off the main thread, 2 s timeout), so
// tests point it at a private server with HEADROOM_TMUX_SOCKET=headroom-test (`-L headroom-test`).
// NEVER run kill/send-keys against the user's real tmux server in tests.
//
// Read-only calls: panes(), clients(), capture(), hasSession(). Mutating calls (used only by Jump and Undo, which
// the user triggers): jump(), newWindow(), newSession(), sendKeys().

import Foundation
import HeadroomContracts

public struct TmuxClient: Sendable {
    public let env: HeadroomEnv
    public var timeout: TimeInterval
    public init(env: HeadroomEnv = .current, timeout: TimeInterval = 2) { self.env = env; self.timeout = timeout }

    public static let paneFormat = "#{pane_id}\t#{pane_pid}\t#{pane_active}\t#{window_active}\t#{session_attached}\t#{session_name}\t#{window_index}\t#{pane_index}\t#{window_name}\t#{pane_title}\t#{pane_current_command}"
    public static let clientFormat = "#{client_activity}\t#{client_tty}\t#{client_session}"

    /// `-u` on every call: without a UTF-8 locale the tmux client replaces every tab and non-ASCII character
    /// in its output with "_". An app opened from Finder or the Dock has no LANG, so the tab-separated
    /// `-F` formats below would not parse and every session would show as "not in tmux".
    public static let clientArgs = ["-u"]

    /// Test seam: variables added to the tmux child's environment (for example LC_ALL=C).
    var extraEnvironment: [String: String] = [:]

    /// Runs tmux with the configured binary and socket. Missing binary or no server → a non-ok Result.
    public func run(_ args: [String]) async -> Shell.Result {
        guard FileManager.default.isExecutableFile(atPath: env.tmuxPath) else {
            return Shell.Result(status: 127, stdout: "", stderr: "tmux not found at \(env.tmuxPath)", timedOut: false)
        }
        return await Shell.run(env.tmuxPath, Self.clientArgs + env.tmuxBaseArgs + args, timeout: timeout,
                               environment: childEnvironment)
    }

    /// With a private socket (tests), drop TMUX/TMUX_PANE so nothing can resolve to the caller's own tmux server.
    var childEnvironment: [String: String]? {
        guard env.tmuxSocket != nil || !extraEnvironment.isEmpty else { return nil }
        var e = ProcessInfo.processInfo.environment
        if env.tmuxSocket != nil { e["TMUX"] = nil; e["TMUX_PANE"] = nil }
        e.merge(extraEnvironment) { _, new in new }
        return e
    }

    // MARK: - Read-only

    /// `list-panes -a` (one call per tick). [] when there is no server.
    public func panes() async -> [TmuxPane] {
        let r = await run(["list-panes", "-a", "-F", Self.paneFormat])
        return r.ok ? Self.parsePanes(r.stdout) : []
    }

    /// `list-clients`. [] when there is no server or no client.
    public func clients() async -> [TmuxClientInfo] {
        let r = await run(["list-clients", "-F", Self.clientFormat])
        return r.ok ? Self.parseClients(r.stdout) : []
    }

    public func hasSession(_ name: String) async -> Bool {
        await run(["has-session", "-t", "=\(name)"]).ok
    }

    /// Read-only `capture-pane -p -t <pane> -S -<lines>`.
    public func capture(pane: String, lines: Int = 15) async -> String? {
        let r = await run(["capture-pane", "-p", "-t", pane, "-S", "-\(max(lines, 1))"])
        return r.ok ? r.stdout : nil
    }

    // MARK: - Parsing (pure; unit tested on captured output)

    /// Parses `list-panes -F paneFormat`. Lines with too few fields are skipped. A pane title that contains
    /// tabs is rejoined (the last field is always pane_current_command).
    public static func parsePanes(_ output: String) -> [TmuxPane] {
        var out: [TmuxPane] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 11, f[0].hasPrefix("%"), let pid = Int32(f[1]),
                  let wi = Int(f[6]), let pi = Int(f[7]) else { continue }
            let title = f[9..<(f.count - 1)].joined(separator: "\t")
            out.append(TmuxPane(paneId: f[0], panePid: pid, paneActive: f[2] == "1", windowActive: f[3] == "1",
                                sessionAttached: Int(f[4]) ?? 0, session: f[5], windowIndex: wi, paneIndex: pi,
                                windowName: f[8], paneTitle: title, currentCommand: f[f.count - 1]))
        }
        return out
    }

    public static func parseClients(_ output: String) -> [TmuxClientInfo] {
        var out: [TmuxClientInfo] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let act = Int(f[0]) else { continue }
            out.append(TmuxClientInfo(activity: act, tty: f[1], session: f[2]))
        }
        return out
    }

    /// The session of the most recently active client (SPEC §5 `current`).
    public static func currentSession(_ clients: [TmuxClientInfo]) -> String? {
        clients.max { $0.activity < $1.activity }?.session
    }

    /// Resolves a pane to a TmuxLoc with `visible` and `current` filled in (SPEC §5).
    public static func location(of pane: TmuxPane, clients: [TmuxClientInfo]) -> TmuxLoc {
        let current = pane.visible && currentSession(clients) == pane.session
        return TmuxLoc(paneId: pane.paneId, session: pane.session, windowName: pane.windowName,
                       windowIndex: pane.windowIndex, paneIndex: pane.paneIndex, panePid: pane.panePid,
                       visible: pane.visible, current: current)
    }

    /// The pane whose pane_pid is `ppid` (a claude's parent shell), else the `%pane` hint if it still exists.
    public static func pane(forParent ppid: Int32, hint: String?, in panes: [TmuxPane]) -> TmuxPane? {
        if let p = panes.first(where: { $0.panePid == ppid }) { return p }
        if let h = hint { return panes.first { $0.paneId == h } }
        return nil
    }

    /// A tmux server or client: executable basename "tmux", or argv0 basename starting with "tmux".
    /// (RexProcess.boundary uses it: the nearest of a tmux process and a Rex server decides the multiplexer.)
    public static func isTmuxProcess(path: String, argv0: String?) -> Bool {
        if Ownership.basename(path) == "tmux" { return true }
        guard let a0 = argv0, !a0.isEmpty else { return false }
        return Ownership.basename(a0).hasPrefix("tmux")
    }

    /// The client to drive for a jump: the most active client attached to `session`, else the most active one.
    public static func jumpClient(for session: String, clients: [TmuxClientInfo]) -> TmuxClientInfo? {
        clients.filter { $0.session == session }.max { $0.activity < $1.activity }
            ?? clients.max { $0.activity < $1.activity }
    }

    // MARK: - Mutating (user-triggered only)

    /// What `jump(paneId:)` did.
    public enum Jump: Sendable, Equatable {
        /// tmux now shows the pane on this client. `tty` is the client's terminal device (`client_tty`), which is
        /// how the terminal app finds the window to bring forward (SPEC §7.6 step 4).
        case switched(tty: String, session: String)
        /// The pane is gone.
        case noPane
        /// No client is attached to the server (the caller then copies `tmux attach`).
        case noClient(session: String)
        /// tmux refused or did not answer. `reason` is tmux's message, for the note Jump shows.
        case failed(session: String, reason: String)

        public var tty: String? { if case .switched(let t, _) = self { t } else { nil } }
    }

    /// SPEC §7.6 steps 1–3 for a pane id: reads the panes and clients, then `jump(to:clients:)`.
    public func jump(paneId: String) async -> Jump {
        async let ps = panes()
        async let cs = clients()
        let (allPanes, allClients) = await (ps, cs)
        guard let pane = allPanes.first(where: { $0.paneId == paneId }) else { return .noPane }
        return await jump(to: pane, clients: allClients)
    }

    /// SPEC §7.6 steps 2–3, on state the caller just read: picks the client (`jumpClient`), then runs
    /// `switch-client -c <tty> -t <sess>; select-window -t %P; select-pane -t %P`. Never answers `.noPane`: a pane
    /// that went away since the caller's read is tmux's own error, in `.failed`.
    public func jump(to pane: TmuxPane, clients allClients: [TmuxClientInfo]) async -> Jump {
        guard let client = Self.jumpClient(for: pane.session, clients: allClients) else {
            return .noClient(session: pane.session)
        }
        let paneId = pane.paneId
        let r = await run(["switch-client", "-c", client.tty, "-t", pane.session, ";",
                           "select-window", "-t", paneId, ";", "select-pane", "-t", paneId])
        if r.ok { return .switched(tty: client.tty, session: pane.session) }
        let said = Self.firstLine(r.stderr) ?? (r.timedOut ? "tmux did not answer" : "tmux exited with status \(r.status)")
        return .failed(session: pane.session, reason: said)
    }

    /// `new-window -d -t '<sess>:' -n <name> -c <cwd>`; creates the session if it is gone (SPEC §7.7).
    /// Returns the new pane id.
    public func newWindow(session: String, name: String, cwd: String) async -> String? {
        if await hasSession(session) {
            let r = await run(["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "=\(session):", "-n", name,
                               "-c", cwd])
            if r.ok { return Self.firstLine(r.stdout) }
        }
        return await newSession(session, cwd: cwd, windowName: name)
    }

    /// `new-session -d -s <sess> -c <cwd>`. Returns the first pane id.
    public func newSession(_ session: String, cwd: String, windowName: String? = nil) async -> String? {
        var args = ["new-session", "-d", "-P", "-F", "#{pane_id}", "-s", session, "-c", cwd]
        if let windowName { args += ["-n", windowName] }
        let r = await run(args)
        return r.ok ? Self.firstLine(r.stdout) : nil
    }

    /// Types `keys` literally (`send-keys -l`), then Enter if asked.
    public func sendKeys(pane: String, _ keys: String, enter: Bool = true) async -> Bool {
        guard await run(["send-keys", "-t", pane, "-l", keys]).ok else { return false }
        return enter ? await run(["send-keys", "-t", pane, "Enter"]).ok : true
    }

    static func firstLine(_ s: String) -> String? {
        let l = s.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return (l?.isEmpty ?? true) ? nil : l
    }
}
