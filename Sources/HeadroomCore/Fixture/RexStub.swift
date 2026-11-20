// A fake `rex` for tests (the Rex counterpart of a private tmux socket, for code that must never reach the user's
// real Rex server). Point HEADROOM_REX at `stub.path`; every call is logged and answered from canned responses.
//
//     let stub = RexStub(); defer { stub.remove() }
//     stub.respond("ls", stdout: #"{"sessions":[]}"#)
//     let env = HeadroomEnv(environment: ["HOME": "/nonexistent", "HEADROOM_REX": stub.path])
//     _ = await RexClient(env: env).sessions()
//     stub.commands()   // [["ls", "--json"]]

import Foundation

/// A fake `rex` for tests: a /bin/sh script in NSTemporaryDirectory()/headroom-rexstub-<UUID>. Logs each call's argv
/// (fields joined by U+001F, one call per line) to dir/calls.log, then sleeps/prints/exits per its route. Never
/// talks to a Rex server.
public final class RexStub: @unchecked Sendable {
    public let dir: String
    /// Point HEADROOM_REX here.
    public var path: String { dir + "/rex" }

    /// The delay's `sleep` writes nowhere, so a call cancelled while it sleeps releases Shell's pipes at once.
    static let script = """
    #!/bin/sh
    d=$(cd "$(dirname "$0")" && pwd); sep=$(printf '\\037'); line=""; first=1
    for a in "$@"; do if [ $first = 1 ]; then line="$a"; first=0; else line="$line$sep$a"; fi; done
    printf '%s\\n' "$line" >> "$d/calls.log"
    while [ $# -gt 0 ]; do case "$1" in --autostart=*) shift ;; --timeout|-S|-C) shift; shift ;; *) break ;; esac; done
    case "$1 $2" in "session inspect") r="inspect $3" ;; "window new") r="window-new" ;; "server stop") r="server-stop" ;; *) r="$1" ;; esac
    r=$(printf '%s' "$r" | tr ' :/' '___')
    [ -f "$d/resp/$r.delay" ] && sleep "$(cat "$d/resp/$r.delay")" >/dev/null 2>&1
    [ -f "$d/resp/$r.out" ] && cat "$d/resp/$r.out"
    [ -f "$d/resp/$r.err" ] && cat "$d/resp/$r.err" >&2
    [ -f "$d/resp/$r.code" ] && exit "$(cat "$d/resp/$r.code")"
    exit 0

    """

    public init() {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("headroom-rexstub-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir + "/resp", withIntermediateDirectories: true)
        fm.createFile(atPath: dir + "/rex", contents: Data(Self.script.utf8),
                      attributes: [.posixPermissions: 0o755])
    }

    /// File name of a route's responses: ' ', ':' and '/' become '_'.
    static func fileName(_ route: String) -> String {
        String(route.map { " :/".contains($0) ? "_" : $0 })
    }

    /// Route = first word after the global flags (--autostart=*, --timeout X, -S X, -C X skipped), except
    /// "session inspect <id>" → "inspect <id>", "window new" → "window-new", "server stop" → "server-stop".
    /// Stored in dir/resp/<route with ' ', ':', '/' → '_'>.{out,err,code,delay}. Unset route: no output, exit 0.
    /// Calling it again for the same route replaces the earlier answer.
    public func respond(_ route: String, stdout: String, stderr: String = "", exit: Int32 = 0,
                        delay: TimeInterval = 0) {
        let base = dir + "/resp/" + Self.fileName(route)
        let fm = FileManager.default
        fm.createFile(atPath: base + ".out", contents: Data(stdout.utf8))
        if stderr.isEmpty {
            try? fm.removeItem(atPath: base + ".err")
        } else {
            fm.createFile(atPath: base + ".err", contents: Data(stderr.utf8))
        }
        fm.createFile(atPath: base + ".code", contents: Data("\(exit)".utf8))
        if delay > 0 {
            fm.createFile(atPath: base + ".delay", contents: Data(String(format: "%.3f", delay).utf8))
        } else {
            try? fm.removeItem(atPath: base + ".delay")
        }
    }

    /// Full argv per call, oldest first.
    public func calls() -> [[String]] {
        guard let text = try? String(contentsOfFile: dir + "/calls.log", encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
    }

    /// The same with the global flags removed (what the script routes on).
    public func commands() -> [[String]] { calls().map(Self.withoutGlobalFlags) }

    static func withoutGlobalFlags(_ argv: [String]) -> [String] {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--autostart=") { i += 1 } else if ["--timeout", "-S", "-C"].contains(a) { i += 2 } else { break }
        }
        return Array(argv[min(i, argv.count)...])
    }

    public func remove() { try? FileManager.default.removeItem(atPath: dir) }
}
