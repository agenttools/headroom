// Terminal I/O, argument parsing and small formatting helpers for the `headroom` CLI.
// Everything goes through CLIIO so tests can capture output and fake a TTY.

import Darwin
import Foundation
import HeadroomContracts

/// Exit codes (docs/cli.md): 0 ok, 1 error, 2 needs confirmation or refused.
enum Exit {
    static let ok: Int32 = 0
    static let error: Int32 = 1
    static let refused: Int32 = 2
}

/// A user-facing failure with its exit code.
struct CLIError: Error, Equatable {
    let message: String
    let code: Int32
    init(_ message: String, code: Int32 = Exit.error) { self.message = message; self.code = code }
}

/// Where the CLI writes and reads. `standard` is the real terminal; tests use `CaptureIO`.
class CLIIO: @unchecked Sendable {
    func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
    func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    /// Writes without a newline (the y/N prompt).
    func prompt(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }
    func readLine() -> String? { Swift.readLine(strippingNewline: true) }
    /// stdin is a terminal (the y/N prompt is possible).
    var stdinIsTTY: Bool { isatty(STDIN_FILENO) == 1 }
    /// stdout is a terminal (titles are truncated to the window width).
    var stdoutIsTTY: Bool { isatty(STDOUT_FILENO) == 1 }
    var columns: Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0 { return Int(w.ws_col) }
        return 120
    }
    static let standard = CLIIO()
}

/// Test double: records stdout/stderr, answers prompts from a queue, pretends to be (or not be) a TTY.
final class CaptureIO: CLIIO, @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout: [String] = []
    private var _stderr: [String] = []
    private var answers: [String]
    let tty: Bool
    init(tty: Bool = false, answers: [String] = []) { self.tty = tty; self.answers = answers }
    override func out(_ s: String) { lock.withLock { _stdout.append(s) } }
    override func err(_ s: String) { lock.withLock { _stderr.append(s) } }
    override func prompt(_ s: String) { lock.withLock { _stderr.append(s) } }
    override func readLine() -> String? {
        lock.withLock { answers.isEmpty ? nil : answers.removeFirst() }
    }
    override var stdinIsTTY: Bool { tty }
    override var stdoutIsTTY: Bool { false }
    override var columns: Int { 120 }
    var stdout: String { lock.withLock { _stdout.joined(separator: "\n") } }
    var stderr: String { lock.withLock { _stderr.joined(separator: "\n") } }
}

/// Minimal GNU-style parser: `--flag`, `--opt value`, `--opt=value`, `-y`, `--` ends options.
struct ParsedArgs: Equatable {
    var flags: Set<String> = []
    var options: [String: String] = [:]
    var positionals: [String] = []

    /// `flags` and `options` are long names without dashes. `short` maps "-y" → "yes".
    static func parse(_ args: [String], flags: Set<String>, options: Set<String> = [],
                      short: [String: String] = [:]) throws(CLIError) -> ParsedArgs {
        var p = ParsedArgs()
        var i = 0
        var onlyPositionals = false
        while i < args.count {
            let a = args[i]; i += 1
            if onlyPositionals || !a.hasPrefix("-") || a == "-" { p.positionals.append(a); continue }
            if a == "--" { onlyPositionals = true; continue }
            if !a.hasPrefix("--") {
                guard let long = short[a] else { throw CLIError("unknown option \(a)") }
                p.flags.insert(long); continue
            }
            var name = String(a.dropFirst(2))
            var value: String?
            if let eq = name.firstIndex(of: "=") {
                value = String(name[name.index(after: eq)...]); name = String(name[..<eq])
            }
            if flags.contains(name) {
                guard value == nil else { throw CLIError("--\(name) takes no value") }
                p.flags.insert(name)
            } else if options.contains(name) {
                if value == nil {
                    guard i < args.count else { throw CLIError("--\(name) needs a value") }
                    value = args[i]; i += 1
                }
                p.options[name] = value
            } else {
                throw CLIError("unknown option --\(name)")
            }
        }
        return p
    }

    func has(_ f: String) -> Bool { flags.contains(f) }
}

enum Text {
    /// Pads or truncates to exactly `n` columns (character count; good enough for a terminal table).
    static func col(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(max(0, n - 1))) + "…" : s.padding(toLength: n, withPad: " ", startingAt: 0)
    }
    static func rcol(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }
    static func trunc(_ s: String, _ n: Int) -> String {
        guard n > 1, s.count > n else { return s }
        return String(s.prefix(n - 1)) + "…"
    }
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
    static func age(_ seconds: Int?) -> String {
        guard let s = seconds else { return "–" }
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 48 * 3600 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
    static func bytes(_ b: Bytes?) -> String { b.map(ByteFormat.short) ?? "—" }
    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : (many ?? one + "s"))"
    }
    static func tilde(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") || path == home ? "~" + path.dropFirst(home.count) : path
    }
}

enum JSONOut {
    static func write<T: Encodable>(_ v: T, _ io: CLIIO) -> Int32 {
        do {
            let data = try HeadroomJSON.encoder().encode(v)
            io.out(String(decoding: data, as: UTF8.self))
            return Exit.ok
        } catch {
            io.err("headroom: could not encode JSON: \(error)")
            return Exit.error
        }
    }
}
