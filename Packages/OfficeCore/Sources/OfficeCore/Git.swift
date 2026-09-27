import Foundation

/// A project's branches and worktrees, so a job can run on a branch without switching the project folder.
public enum Git {
    public struct Worktree: Sendable, Equatable {
        public var path: String
        public var branch: String?
    }

    public struct Branches: Sendable, Equatable {
        public var current: String?
        public var local: [String]
        public var worktrees: [Worktree]
    }

    public enum Failure: Error, LocalizedError {
        case notARepository
        case command(String)

        public var errorDescription: String? {
            switch self {
            case .notARepository: "The project folder isn’t a git repository."
            case .command(let message): message
            }
        }
    }

    public static func worktrees(fromPorcelain text: String) -> [Worktree] {
        text.components(separatedBy: "\n\n").compactMap { block in
            var path: String?, branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst("branch refs/heads/".count)) }
            }
            return path.map { Worktree(path: $0, branch: branch) }
        }
    }

    /// Nil when the folder isn't in a git repository.
    public static func branches(in directory: URL) async -> Branches? {
        guard let list = try? await run(["worktree", "list", "--porcelain"], in: directory),
              let refs = try? await run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: directory) else { return nil }
        let current = try? await run(["branch", "--show-current"], in: directory)
        return Branches(current: current.flatMap { $0.isEmpty ? nil : $0 },
                        local: refs.split(separator: "\n").map(String.init),
                        worktrees: worktrees(fromPorcelain: list))
    }

    public static func currentBranch(in directory: URL) async -> String? {
        guard let name = try? await run(["branch", "--show-current"], in: directory), !name.isEmpty else { return nil }
        return name
    }

    /// Where a job on `branch` runs: wherever it's already checked out, or a new worktree where `claude --worktree` puts its own.
    public static func directory(for branch: String, in directory: URL) async throws -> URL {
        guard let top = try? await run(["rev-parse", "--show-toplevel"], in: directory) else { throw Failure.notARepository }
        if await currentBranch(in: directory) == branch { return directory }
        let inside = ProjectPath.relative(directory.path, to: URL(fileURLWithPath: top))
        let subfolder = inside == directory.path ? "" : inside
        let trees = worktrees(fromPorcelain: try await run(["worktree", "list", "--porcelain"], in: directory))
        if let tree = trees.first(where: { $0.branch == branch }) {
            return URL(fileURLWithPath: tree.path).appendingPathComponent(subfolder)
        }
        let root = URL(fileURLWithPath: trees.first?.path ?? top).appendingPathComponent(".claude/worktrees")
        let name = branch.replacingOccurrences(of: "/", with: "-")
        var target = root.appendingPathComponent(name), n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = root.appendingPathComponent("\(name)-\(n)")
            n += 1
        }
        _ = try await run(["worktree", "add", target.path, branch], in: directory)
        return target.appendingPathComponent(subfolder)
    }

    private static func run(_ arguments: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", directory.path] + arguments
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return continuation.resume(throwing: error) }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0 else {
                    return continuation.resume(throwing: Failure.command(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                continuation.resume(returning: text)
            }
        }
    }
}
