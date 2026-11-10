// SPEC §5 "Title" and "Where": pure rules, unit tested.

import Foundation
import HeadroomContracts
import HeadroomCore

public enum SessionTitle {
    /// Title rule (§5): `name` if the user set it, else the transcript's ai-title, else the tmux pane title without
    /// Claude's status glyph, else `name`, else the transcript's `custom-title`, else the project.
    public static func choose(name: String?, nameSource: String?, customTitle: String? = nil, aiTitle: String?,
                              paneTitle: String?, project: String, hostName: String? = nil) -> String {
        if let n = nonEmpty(name), nameSource == "user" { return n }
        if let a = nonEmpty(aiTitle) { return a }
        if let p = cleanPaneTitle(paneTitle, hostName: hostName) { return p }
        if let n = nonEmpty(name) { return n }
        if let c = nonEmpty(customTitle) { return c }
        return project.isEmpty ? "claude" : project
    }

    /// Strips Claude Code's leading status glyph ("✳ ", spinner characters, braille dots) and whitespace.
    /// Returns nil for an empty title or tmux's default (the host name).
    public static func cleanPaneTitle(_ t: String?, hostName: String? = nil) -> String? {
        guard var s = t?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        while let f = s.unicodeScalars.first, isGlyph(f) {
            s = String(s.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !s.isEmpty else { return nil }
        if let h = hostName, !h.isEmpty {
            let short = h.split(separator: ".").first.map(String.init) ?? h
            if s == h || s == short { return nil }
        }
        return s
    }

    static func isGlyph(_ u: Unicode.Scalar) -> Bool {
        if (0x2800...0x28FF).contains(u.value) { return true }        // braille spinner
        return "✳✢✶✻✽✺·*⏺●○◐◓◑◒⠂".unicodeScalars.contains(u)
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// Git/worktree/project context for a cwd, re-read every 30 s (SPEC §5 "Where").
public final class WhereCache: @unchecked Sendable {
    public struct Where: Sendable, Hashable {
        public let project: String
        public let branch: String?
        public let worktree: String?
        public let cwdExists: Bool
    }
    public var ttl: TimeInterval = 30
    private let lock = NSLock()
    private var cache: [String: (at: Date, value: Where)] = [:]

    public init() {}

    public func lookup(cwd: String, now: Date = Date()) -> Where {
        lock.lock()
        if let c = cache[cwd], now.timeIntervalSince(c.at) < ttl { lock.unlock(); return c.value }
        lock.unlock()
        let v = Self.compute(cwd: cwd)
        lock.lock(); cache[cwd] = (now, v); lock.unlock()
        return v
    }

    public static func compute(cwd: String) -> Where {
        var isDir: ObjCBool = false
        let exists = !cwd.isEmpty && FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue
        let head = exists ? GitInfo.head(cwd: cwd) : nil
        let worktree = head?.worktree ?? GitInfo.claudeWorktreeName(cwd)
        return Where(project: project(cwd: cwd, head: head), branch: head?.branch, worktree: worktree, cwdExists: exists)
    }

    /// Main repository folder name; else the folder above `/.claude/worktrees/<w>`; else the cwd's last component.
    public static func project(cwd: String, head: GitHead?) -> String {
        if let p = head?.project, !p.isEmpty, p != "/" { return p }
        if let r = cwd.range(of: "/.claude/worktrees/") {
            return (String(cwd[..<r.lowerBound]) as NSString).lastPathComponent
        }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
    }
}

/// "hub:3.1 › compass ⎇ my-branch" (SPEC §5 "Where"). The UI may render it differently; this is the CLI/peek form.
public enum WhereLabel {
    public static func make(tmux: TmuxLoc?, project: String, branch: String?, worktree: String?) -> String {
        var parts: [String] = []
        if let t = tmux { parts.append(t.label) }
        var repo = project
        if let w = worktree, w != project { repo += " ⎇ " + w }
        else if let b = branch { repo += " ⎇ " + b }
        parts.append(repo)
        return parts.joined(separator: " › ")
    }
}
