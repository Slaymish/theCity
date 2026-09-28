import Foundation
import Testing
@testable import OfficeCore

struct GitTests {
    @Test func porcelainListsEachWorktreeWithItsBranch() {
        let text = """
        worktree /Users/me/app
        HEAD 3aa6801
        branch refs/heads/main

        worktree /Users/me/app/.claude/worktrees/probe
        HEAD 3aa6801
        branch refs/heads/feature/login
        locked

        worktree /Users/me/app/.claude/worktrees/loose
        HEAD 3aa6801
        detached
        """
        #expect(Git.worktrees(fromPorcelain: text) == [
            Git.Worktree(path: "/Users/me/app", branch: "main"),
            Git.Worktree(path: "/Users/me/app/.claude/worktrees/probe", branch: "feature/login"),
            Git.Worktree(path: "/Users/me/app/.claude/worktrees/loose", branch: nil),
        ])
    }

    @Test func worktreeFlagOnlyWhenAsked() throws {
        let config = RunConfig(request: "hi", workingDirectory: URL(fileURLWithPath: "/tmp"), claudeConfigDirectory: nil, model: nil, maxBudgetUSD: nil)
        #expect(!config.arguments.contains("--worktree"))
        var worktree = config
        worktree.worktreeName = "reception-ai"
        let flag = try #require(worktree.arguments.firstIndex(of: "--worktree"))
        #expect(worktree.arguments[flag + 1] == "reception-ai")
    }

    @Test func slugsAreSafeWorktreeNames() {
        #expect(Git.slug("Reception AI Options") == "reception-ai-options")
        #expect(Git.slug("feature/login") == "feature-login")
        #expect(Git.slug("  ✨ ") == "job")
    }

    @Test func jobsAskingAtOnceGetTheirOwnWorktrees() async throws {
        let repo = URL(fileURLWithPath: "/tmp").appendingPathComponent("GitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try shell("git init -q -b main && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init", in: repo)

        async let first = Git.worktree(named: "Polish", from: "main", in: repo)
        async let second = Git.worktree(named: "Polish", from: "main", in: repo)
        let made = try await [first, second]
        #expect(Set(made.map(\.lastPathComponent)) == ["polish", "polish-2"])
        #expect(await Git.currentBranch(in: made[0]) != Git.currentBranch(in: made[1]))
        #expect(await Git.currentBranch(in: made[0])?.hasPrefix("worktree-polish") == true)
        #expect(await Git.checkout(of: made[0]) != Git.checkout(of: repo))

        let name = try await Git.freshWorktreeName("Polish", in: repo)
        #expect(name == "polish-3")
        #expect(try await Git.freshWorktreeName("Polish", in: repo) == "polish-4")
    }

    @Test func aBranchRunsWhereItIsCheckedOutOrInANewWorktree() async throws {
        let repo = URL(fileURLWithPath: "/tmp").appendingPathComponent("GitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try shell("git init -q -b main && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init && git branch feature/login", in: repo)

        let branches = try #require(await Git.branches(in: repo))
        #expect(branches.current == "main")
        #expect(Set(branches.local) == ["main", "feature/login"])

        #expect(try await Git.directory(for: "main", in: repo) == repo)
        let made = try await Git.directory(for: "feature/login", in: repo)
        #expect(made.lastPathComponent == "feature-login")
        #expect(await Git.currentBranch(in: made) == "feature/login")
        #expect(ProjectPath.canonical(try await Git.directory(for: "feature/login", in: repo).path) == ProjectPath.canonical(made.path))
    }

    @Test func removingAWorktreeKeepsAnythingUnsaved() async throws {
        let repo = URL(fileURLWithPath: "/tmp").appendingPathComponent("GitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try shell("git init -q -b main && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init", in: repo)

        let clean = try await Git.worktree(named: "clean", from: "main", in: repo)
        #expect(await Git.removeWorktree(at: clean.path))
        #expect(!FileManager.default.fileExists(atPath: clean.path))
        #expect(await Git.branches(in: repo)?.local == ["main"])

        let dirty = try await Git.worktree(named: "dirty", from: "main", in: repo)
        try "draft".write(to: dirty.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        #expect(await !Git.removeWorktree(at: dirty.path))
        #expect(FileManager.default.fileExists(atPath: dirty.appendingPathComponent("notes.txt").path))

        let committed = try await Git.worktree(named: "committed", from: "main", in: repo)
        try shell("git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m work", in: committed)
        #expect(await Git.removeWorktree(at: committed.path))
        #expect(await Git.branches(in: repo)?.local.contains("worktree-committed") == true)
        #expect(await !Git.removeWorktree(at: repo.path))
    }

    @Test func aFolderOutsideGitHasNoBranches() async throws {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("GitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await Git.branches(in: folder) == nil)
    }

    private func shell(_ script: String, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
