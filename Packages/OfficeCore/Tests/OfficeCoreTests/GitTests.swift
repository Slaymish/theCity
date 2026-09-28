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

    @Test func worktreeFlagOnlyWhenAsked() {
        let config = RunConfig(request: "hi", workingDirectory: URL(fileURLWithPath: "/tmp"), claudeConfigDirectory: nil, model: nil, maxBudgetUSD: nil)
        #expect(!config.arguments.contains("--worktree"))
        var worktree = config
        worktree.createsWorktree = true
        #expect(worktree.arguments.contains("--worktree"))
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
