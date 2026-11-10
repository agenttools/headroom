// GitInfo.head reads files only (fake .git layouts in a scratch dir); dirty() runs git in a scratch repo.
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomCore

func makeScratch(_ name: String) -> String {
    let base = CoreSelfTest.realPath(NSTemporaryDirectory())
    let dir = base + "/headroom-wp1-\(name)-\(UUID().uuidString.prefix(8))"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func write(_ path: String, _ s: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try! s.write(toFile: path, atomically: true, encoding: .utf8)
}

@Suite struct GitHeadTests {
    @Test func branchFromSubdirectory() {
        let repo = makeScratch("repo")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        write(repo + "/.git/HEAD", "ref: refs/heads/feature/tabs\n")
        try! FileManager.default.createDirectory(atPath: repo + "/src/deep", withIntermediateDirectories: true)
        let h = GitInfo.head(cwd: repo + "/src/deep")
        #expect(h?.branch == "feature/tabs")
        #expect(h?.repoRoot == repo)
        #expect(h?.mainRepoRoot == repo)
        #expect(h?.worktree == nil)
        #expect(h?.project == (repo as NSString).lastPathComponent)
    }

    @Test func detachedHead() {
        let repo = makeScratch("detached")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        write(repo + "/.git/HEAD", "3f2a9c1d0e8b7a6f5e4d3c2b1a0f9e8d7c6b5a49\n")
        #expect(GitInfo.head(cwd: repo)?.branch == "@3f2a9c1")
    }

    @Test func claudeWorktreeWithGitdirFile() {
        let repo = makeScratch("main")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        write(repo + "/.git/HEAD", "ref: refs/heads/main\n")
        write(repo + "/.git/worktrees/fix-bug/HEAD", "ref: refs/heads/worktree-fix-bug\n")
        write(repo + "/.git/worktrees/fix-bug/commondir", "../..\n")
        let wt = repo + "/.claude/worktrees/fix-bug"
        write(wt + "/.git", "gitdir: \(repo)/.git/worktrees/fix-bug\n")
        let h = GitInfo.head(cwd: wt + "/pkg")
        #expect(h?.branch == "worktree-fix-bug")
        #expect(h?.worktree == "fix-bug")
        #expect(h?.repoRoot == wt)
        #expect(h?.mainRepoRoot == repo)
        #expect(h?.project == (repo as NSString).lastPathComponent)
    }

    @Test func relativeGitdir() {
        let root = makeScratch("rel")
        defer { try? FileManager.default.removeItem(atPath: root) }
        write(root + "/repo/.git/worktrees/w/HEAD", "ref: refs/heads/w\n")
        write(root + "/repo/.git/worktrees/w/commondir", "../..\n")
        write(root + "/w/.git", "gitdir: ../repo/.git/worktrees/w\n")
        let h = GitInfo.head(cwd: root + "/w")
        #expect(h?.branch == "w")
        #expect(h?.mainRepoRoot == root + "/repo")
    }

    @Test func notARepo() {
        let dir = makeScratch("plain")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(GitInfo.head(cwd: dir) == nil || GitInfo.head(cwd: dir)?.repoRoot != dir)
        #expect(GitInfo.head(cwd: "/definitely/not/here") == nil)
        #expect(GitInfo.claudeWorktreeName("/x/.claude/worktrees/abc/def") == "abc")
        #expect(GitInfo.claudeWorktreeName("/x/.claude/worktrees/") == nil)
    }
}

@Suite struct GitDirtyTests {
    @Test func countsTrackedChangesAndNoUpstream() async throws {
        let repo = makeScratch("dirty")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let git = { (args: [String]) async -> Shell.Result in
            await Shell.run(GitInfo.gitPath, ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t",
                                              "-c", "commit.gpgsign=false"] + args, timeout: 10)
        }
        #expect(await git(["init", "-q", "-b", "main"]).ok)
        write(repo + "/a.txt", "1\n"); write(repo + "/b.txt", "1\n")
        #expect(await git(["add", "."]).ok)
        #expect(await git(["commit", "-q", "-m", "init"]).ok)
        #expect(await GitInfo.dirty(cwd: repo) == GitDirty(dirtyFiles: 0, ahead: nil))
        write(repo + "/a.txt", "2\n")
        write(repo + "/untracked.txt", "x\n")          // -uno: not counted
        #expect(await GitInfo.dirty(cwd: repo) == GitDirty(dirtyFiles: 1, ahead: nil))
        #expect(GitInfo.head(cwd: repo)?.branch == "main")
        // No index.lock is left behind (GIT_OPTIONAL_LOCKS=0).
        #expect(!FileManager.default.fileExists(atPath: repo + "/.git/index.lock"))
    }

    @Test func notARepoIsNil() async {
        let dir = makeScratch("norepo")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(await GitInfo.dirty(cwd: dir) == nil)
    }

    @Test func limiterCapsConcurrency() async {
        let lim = AsyncLimiter(2)
        actor Counter { var cur = 0, peak = 0
            func inc() { cur += 1; peak = max(peak, cur) }
            func dec() { cur -= 1 } }
        let c = Counter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 {
                g.addTask {
                    await lim.acquire(); await c.inc()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await c.dec(); await lim.release()
                }
            }
        }
        #expect(await c.peak == 2)
    }
}
