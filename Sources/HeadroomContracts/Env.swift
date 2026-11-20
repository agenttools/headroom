// Environment, test seams and well-known paths. Every module reads configuration through HeadroomEnv,
// never getenv directly, so tests can inject a scratch world.
//
// Test seams (SPEC §11):
//   HEADROOM_DRY_RUN=1                 every signal/close logs and returns .dryRun
//   HEADROOM_CLAUDE_DIR=<dir>          replaces ~/.claude (sessions/, projects/)
//   HEADROOM_SUPPORT_DIR=<dir>         replaces ~/Library/Application Support/Headroom
//   HEADROOM_TMUX=<path>               tmux binary (default /opt/homebrew/bin/tmux)
//   HEADROOM_TMUX_SOCKET=<name>        adds `-L <name>` to every tmux call (tests: headroom-test)
//   HEADROOM_REX=<path>                rex CLI (default: ~/.local/bin/rex; with the account's real HOME also the CLI
//                                      inside /Applications/Rex.app or /Applications/Rex Beta.app)
//   HEADROOM_REX_SERVER=<unix:///abs>  adds `-S <address>` to every rex call (tests: a private server). Any other
//                                      form makes every rex call refuse. `rex server …` runs only when it is set.
//   HEADROOM_CLAUDE_VERSIONS_GLOB=<g>  extra ':'-separated fnmatch globs accepted as a claude binary path
//                                      (e.g. "/private/tmp/*/claude/versions/*")
//   HEADROOM_MOCK=1                    Headroom.context() returns the MockWorld + mock executor
//   HEADROOM_MOCK_CHROME=<mode>        mock only: helper|processesOnly|appleScript|waiting|notRunning|stale
//   HEADROOM_MOCK_JITTER=1             mock only: tab footprints change on every snapshot (sort-freeze QA)

import Foundation

public enum HeadroomIDs {
    public static let bundleId = "dev.adder.headroom"
    public static let nativeHostName = "dev.adder.headroom"
    public static let signingIdentity = "Headroom Local Signing"
    public static let version = "0.1.0"
}

public enum KnownPaths {
    public static let chromeExecutable = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    public static let claudeVersionsMarker = "/claude/versions/"
    public static func defaultChromeUserDataDir(home: String) -> String {
        home + "/Library/Application Support/Google/Chrome"
    }

    public static let rexAppBundleId = "com.superlogical.rex"
    /// The account's home from the user database (getpwuid(getuid()).pw_dir), not $HOME; NSHomeDirectory() if
    /// unreadable.
    public static let accountHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let s = String(cString: dir)
            if !s.isEmpty { return s }
        }
        return NSHomeDirectory()
    }()
    /// `home/.local/bin/rex`, plus the two /Applications CLIs only when `home` is the account's own home, so a test
    /// HOME never resolves to the real binary. (A GUI app's PATH lacks ~/.local/bin, so the path is explicit.)
    public static func rexCandidates(home: String) -> [String] {
        var out = [home + "/.local/bin/rex"]
        if (home as NSString).standardizingPath == (accountHome as NSString).standardizingPath {
            out += ["/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
                    "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"]
        }
        return out
    }
    /// First executable candidate, else the first candidate.
    public static func defaultRexPath(home: String) -> String {
        let c = rexCandidates(home: home)
        return c.first { FileManager.default.isExecutableFile(atPath: $0) } ?? c[0]
    }
}

public struct HeadroomEnv: Sendable, Hashable {
    public var home: String
    public var claudeDir: String
    public var supportDir: String
    public var tmuxPath: String
    public var tmuxSocket: String?
    public var dryRun: Bool
    public var mock: Bool
    public var claudeVersionsGlobs: [String]
    /// CLAUDE_PID of the launching session, if Headroom was started from a Claude terminal (locked row).
    public var launcherClaudePid: Int32?
    /// Mock only (HEADROOM_MOCK_CHROME): the simulated Chrome data source. nil = "helper".
    public var mockChrome: String?
    /// Mock only (HEADROOM_MOCK_JITTER=1): tab footprints change on every snapshot.
    public var mockJitter: Bool
    /// The rex CLI (HEADROOM_REX, else KnownPaths.defaultRexPath(home:)).
    public var rexPath: String
    /// HEADROOM_REX_SERVER: a private Rex server address (tests). nil = rex's own personal socket.
    public var rexServer: String?

    public init(home: String, claudeDir: String, supportDir: String, tmuxPath: String, tmuxSocket: String?,
                dryRun: Bool, mock: Bool, claudeVersionsGlobs: [String], launcherClaudePid: Int32?,
                mockChrome: String? = nil, mockJitter: Bool = false, rexPath: String? = nil,
                rexServer: String? = nil) {
        self.home = home; self.claudeDir = claudeDir; self.supportDir = supportDir; self.tmuxPath = tmuxPath
        self.tmuxSocket = tmuxSocket; self.dryRun = dryRun; self.mock = mock
        self.claudeVersionsGlobs = claudeVersionsGlobs; self.launcherClaudePid = launcherClaudePid
        self.mockChrome = mockChrome; self.mockJitter = mockJitter
        self.rexPath = rexPath ?? KnownPaths.defaultRexPath(home: home)
        self.rexServer = rexServer
    }

    public init(environment e: [String: String]) {
        let home = e["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        func v(_ k: String) -> String? { e[k].flatMap { $0.isEmpty ? nil : $0 } }
        self.init(
            home: home,
            claudeDir: v("HEADROOM_CLAUDE_DIR") ?? home + "/.claude",
            supportDir: v("HEADROOM_SUPPORT_DIR") ?? home + "/Library/Application Support/Headroom",
            tmuxPath: v("HEADROOM_TMUX") ?? "/opt/homebrew/bin/tmux",
            tmuxSocket: v("HEADROOM_TMUX_SOCKET"),
            dryRun: v("HEADROOM_DRY_RUN") == "1",
            mock: v("HEADROOM_MOCK") == "1",
            claudeVersionsGlobs: v("HEADROOM_CLAUDE_VERSIONS_GLOB")?.split(separator: ":").map(String.init) ?? [],
            launcherClaudePid: v("CLAUDE_PID").flatMap { Int32($0) },
            mockChrome: v("HEADROOM_MOCK_CHROME"),
            mockJitter: v("HEADROOM_MOCK_JITTER") == "1",
            rexPath: v("HEADROOM_REX"),
            rexServer: v("HEADROOM_REX_SERVER"))
    }

    public static var current: HeadroomEnv { HeadroomEnv(environment: ProcessInfo.processInfo.environment) }

    // Derived paths
    public var sessionsDir: String { claudeDir + "/sessions" }
    public var projectsDir: String { claudeDir + "/projects" }
    public var runDir: String { supportDir + "/run" }
    public var socketPath: String { runDir + "/app.sock" }
    public var actionsLog: String { supportDir + "/actions.jsonl" }
    public var closedLog: String { supportDir + "/closed.jsonl" }
    public var extensionDir: String { supportDir + "/ChromeExtension" }
    public var nativeHostManifest: String {
        home + "/Library/Application Support/Google/Chrome/NativeMessagingHosts/\(HeadroomIDs.nativeHostName).json"
    }
    public var defaultChromeUserDataDir: String { KnownPaths.defaultChromeUserDataDir(home: home) }

    /// Arguments to prepend to every tmux invocation (`-L <socket>` in tests).
    public var tmuxBaseArgs: [String] { tmuxSocket.map { ["-L", $0] } ?? [] }

    /// Prepended to every rex call: never start a server; `-S <address>` with HEADROOM_REX_SERVER.
    public var rexBaseArgs: [String] { ["--autostart=false"] + (rexServer.map { ["-S", $0] } ?? []) }

    /// True if `path` is a claude binary: contains "/claude/versions/" or matches a test glob.
    public func isClaudeBinary(path: String) -> Bool {
        if path.contains(KnownPaths.claudeVersionsMarker) { return true }
        return claudeVersionsGlobs.contains { fnmatch($0, path, 0) == 0 }
    }
}
