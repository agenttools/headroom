// Git context for sessions (SPEC §5 "Where" and "Flags").
//
// head(cwd:) reads files only (no subprocess): walks up from cwd to the first `.git` (directory, or a worktree's
// `gitdir:` file), reads HEAD, and follows `commondir` back to the main repository.
// dirty(cwd:) runs `git status --porcelain=v1 -uno` and `git rev-list --count @{u}..HEAD` with a 2 s timeout,
// at most 4 at once, and GIT_OPTIONAL_LOCKS=0 so it never takes index.lock in the user's repos. Only for `headroom suggest --ask`.

import Foundation
import HeadroomContracts

public struct GitHead: Sendable, Hashable, Codable {
    /// Branch name, or "@<short sha>" when HEAD is detached. nil if HEAD is unreadable.
    public let branch: String?
    /// Name from /.claude/worktrees/<w>, if the cwd is inside one.
    public let worktree: String?
    /// Top of the working tree that contains cwd (the directory holding `.git`).
    public let repoRoot: String?
    /// The main repository's working tree when cwd is in a linked worktree (else == repoRoot).
    public let mainRepoRoot: String?
    public init(branch: String?, worktree: String?, repoRoot: String?, mainRepoRoot: String? = nil) {
        self.branch = branch; self.worktree = worktree; self.repoRoot = repoRoot
        self.mainRepoRoot = mainRepoRoot ?? repoRoot
    }
    /// Short project name: the main repository's folder name.
    public var project: String? { (mainRepoRoot ?? repoRoot).map { ($0 as NSString).lastPathComponent } }
}

public struct GitDirty: Sendable, Hashable, Codable {
    public let dirtyFiles: Int
    public let ahead: Int?
    public init(dirtyFiles: Int, ahead: Int?) { self.dirtyFiles = dirtyFiles; self.ahead = ahead }
}

public enum GitInfo {
    public static let gitPath = "/usr/bin/git"
    public static let dirtyTimeout: TimeInterval = 2
    public static let maxConcurrent = 4

    /// Reads .git/HEAD (following a worktree's `gitdir:` file), walking up to the repo root. No subprocess.
    public static func head(cwd: String) -> GitHead? {
        let fm = FileManager.default
        var dir = normalize(cwd)
        let worktree = claudeWorktreeName(cwd)
        while true {
            let dotGit = dir + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                let gitDir: String
                if isDir.boolValue {
                    gitDir = dotGit
                } else if let target = readGitdirFile(dotGit, relativeTo: dir) {
                    gitDir = target
                } else {
                    return GitHead(branch: nil, worktree: worktree, repoRoot: dir)
                }
                let branch = readHead(gitDir: gitDir)
                return GitHead(branch: branch, worktree: worktree, repoRoot: dir,
                               mainRepoRoot: mainWorkingTree(gitDir: gitDir) ?? dir)
            }
            if dir == "/" || dir.isEmpty { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }

    /// Lexical normalisation ("." / ".." / "//" / trailing "/"), keeping /private (NSString.standardizingPath
    /// would strip it, and the kernel reports cwds with it).
    static func normalize(_ p: String) -> String {
        var parts: [Substring] = []
        for c in p.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// "<w>" when `path` is inside `/.claude/worktrees/<w>`.
    public static func claudeWorktreeName(_ path: String) -> String? {
        guard let r = path.range(of: "/.claude/worktrees/") else { return nil }
        let rest = path[r.upperBound...]
        let name = rest.split(separator: "/").first.map(String.init)
        return (name?.isEmpty ?? true) ? nil : name
    }

    /// Parses the `gitdir: <path>` file of a linked worktree or submodule.
    static func readGitdirFile(_ file: String, relativeTo dir: String) -> String? {
        guard let s = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        for line in s.split(separator: "\n") where line.hasPrefix("gitdir:") {
            let p = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            let abs = p.hasPrefix("/") ? p : dir + "/" + p
            return normalize(abs)
        }
        return nil
    }

    /// Branch from HEAD ("ref: refs/heads/x" → "x"; a sha → "@abc1234").
    static func readHead(gitDir: String) -> String? {
        guard let s = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return nil }
        let head = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
            return ref
        }
        return head.isEmpty ? nil : "@" + String(head.prefix(7))
    }

    /// For a linked worktree (`<repo>/.git/worktrees/<w>` with a `commondir` file) → `<repo>`.
    static func mainWorkingTree(gitDir: String) -> String? {
        guard let c = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) else { return nil }
        let rel = c.trimmingCharacters(in: .whitespacesAndNewlines)
        let common = normalize(rel.hasPrefix("/") ? rel : gitDir + "/" + rel)
        guard (common as NSString).lastPathComponent == ".git" else { return nil }
        return (common as NSString).deletingLastPathComponent
    }

    /// `git status --porcelain=v1 -uno` + `git rev-list --count @{u}..HEAD`, 2 s timeout. Only for `headroom suggest --ask`.
    /// nil when cwd is not a repo or git timed out. `ahead` is nil when there is no upstream.
    public static func dirty(cwd: String) async -> GitDirty? {
        await limiter.acquire()
        let r = await dirtyNow(cwd: cwd)
        await limiter.release()
        return r
    }

    static func dirtyNow(cwd: String) async -> GitDirty? {
        let env = gitEnvironment()
        let st = await Shell.run(gitPath, ["-C", cwd, "status", "--porcelain=v1", "-uno"],
                                 timeout: dirtyTimeout, environment: env)
        guard st.ok else { return nil }
        let files = st.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
        let ah = await Shell.run(gitPath, ["-C", cwd, "rev-list", "--count", "@{u}..HEAD"],
                                 timeout: dirtyTimeout, environment: env)
        let ahead = ah.ok ? Int(ah.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        return GitDirty(dirtyFiles: files, ahead: ahead)
    }

    static func gitEnvironment() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["GIT_OPTIONAL_LOCKS"] = "0"      // never take index.lock in someone's live repo
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["LC_ALL"] = "C"
        return e
    }

    static let limiter = AsyncLimiter(GitInfo.maxConcurrent)
}

/// A tiny async counting semaphore (FIFO waiters).
public actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(_ n: Int) { available = max(n, 1) }
    public func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
