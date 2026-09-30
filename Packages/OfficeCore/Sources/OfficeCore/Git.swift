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

    #if os(macOS)
    /// Nil when the folder isn't in a git repository.
    public static func branches(in directory: URL) async -> Branches? {
        guard let list = try? await run(["worktree", "list", "--porcelain"], in: directory),
              let refs = try? await run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: directory) else { return nil }
        let current = try? await run(["branch", "--show-current"], in: directory)
        return Branches(current: current.flatMap { $0.isEmpty ? nil : $0 },
                        local: refs.split(separator: "\n").map(String.init),
                        worktrees: worktrees(fromPorcelain: list))
    }

    public static func revision(in directory: URL) async -> String? {
        try? await run(["rev-parse", "--short", "HEAD"], in: directory)
    }

    public static func workspaceStatus(in directory: URL) async -> String? {
        try? await run(["status", "--porcelain", "--untracked-files=normal"], in: directory)
    }

    public static func currentBranch(in directory: URL) async -> String? {
        guard let name = try? await run(["branch", "--show-current"], in: directory), !name.isEmpty else { return nil }
        return name
    }

    /// The root of the checkout a folder sits in, so jobs in two subfolders of one tree still count as sharing it.
    public static func checkout(of directory: URL) async -> String? {
        guard let top = try? await run(["rev-parse", "--show-toplevel"], in: directory) else { return nil }
        return ProjectPath.canonical(top)
    }

    /// The branch checked out in a folder, or its commit when detached, for a worktree to start from.
    public static func head(of directory: URL) async throws -> String {
        if let branch = await currentBranch(in: directory) { return branch }
        return try await run(["rev-parse", "--short", "HEAD"], in: directory)
    }

    /// Where a job on `branch` runs: wherever it's already checked out, or a new worktree made for it.
    public static func directory(for branch: String, in directory: URL) async throws -> URL {
        guard let top = try? await run(["rev-parse", "--show-toplevel"], in: directory) else { throw Failure.notARepository }
        if await currentBranch(in: directory) == branch { return directory }
        return try await lock.serially {
            let trees = worktrees(fromPorcelain: try await run(["worktree", "list", "--porcelain"], in: directory))
            if let tree = trees.first(where: { $0.branch == branch }) {
                return URL(fileURLWithPath: tree.path).appendingPathComponent(subfolder(of: directory, top: top))
            }
            let target = try await freeSlot(slug(branch), in: directory, trees: trees, top: top, needsBranch: false).url
            _ = try await run(["worktree", "add", target.path, branch], in: directory)
            return target.appendingPathComponent(subfolder(of: directory, top: top))
        }
    }

    /// A new worktree on its own `worktree-<name>` branch starting at `base`, for a job that mustn't share the checkout `base` is in.
    public static func worktree(named name: String, from base: String, in directory: URL) async throws -> URL {
        guard let top = try? await run(["rev-parse", "--show-toplevel"], in: directory) else { throw Failure.notARepository }
        return try await lock.serially {
            let trees = worktrees(fromPorcelain: try await run(["worktree", "list", "--porcelain"], in: directory))
            let (name, target) = try await freeSlot(slug(name), in: directory, trees: trees, top: top, needsBranch: true)
            _ = try await run(["worktree", "add", "-b", "worktree-\(name)", target.path, base], in: directory)
            return target.appendingPathComponent(subfolder(of: directory, top: top))
        }
    }

    /// A name no worktree folder or `worktree-<name>` branch uses yet, since `claude --worktree <name>` reuses one that exists.
    public static func freshWorktreeName(_ name: String, in directory: URL) async throws -> String {
        guard let top = try? await run(["rev-parse", "--show-toplevel"], in: directory) else { throw Failure.notARepository }
        return try await lock.serially {
            let trees = worktrees(fromPorcelain: try await run(["worktree", "list", "--porcelain"], in: directory))
            return try await freeSlot(slug(name), in: directory, trees: trees, top: top, needsBranch: true).name
        }
    }

    /// Removes a worktree and then its branch, only as far as git allows without forcing: uncommitted work or unmerged commits stay.
    @discardableResult
    public static func removeWorktree(at root: String) async -> Bool {
        let tree = URL(fileURLWithPath: root)
        guard let list = try? await run(["worktree", "list", "--porcelain"], in: tree),
              let main = worktrees(fromPorcelain: list).first?.path, ProjectPath.canonical(main) != ProjectPath.canonical(root) else { return false }
        let mainURL = URL(fileURLWithPath: main)
        let branch = await currentBranch(in: tree)
        return (try? await lock.serially {
            _ = try await run(["worktree", "remove", root], in: mainURL)
            if let branch { _ = try? await run(["branch", "-d", branch], in: mainURL) }
            return true
        }) ?? false
    }

    static func slug(_ text: String) -> String {
        let words = text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let slug = String(words.joined(separator: "-").prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "job" : slug
    }

    private static let lock = Serial()

    private static func subfolder(of directory: URL, top: String) -> String {
        let inside = ProjectPath.relative(directory.path, to: URL(fileURLWithPath: top))
        return inside == directory.path ? "" : inside
    }

    private static func freeSlot(_ name: String, in directory: URL, trees: [Worktree], top: String, needsBranch: Bool) async throws -> (name: String, url: URL) {
        let root = URL(fileURLWithPath: trees.first?.path ?? top).appendingPathComponent(".claude/worktrees")
        let branches = needsBranch ? Set(try await run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: directory).split(separator: "\n").map(String.init)) : []
        var candidate = name, n = 2
        while true {
            let target = root.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: target.path), !branches.contains("worktree-\(candidate)"),
               await lock.reserve(target.path) {
                return (candidate, target)
            }
            candidate = "\(name)-\(n)"
            n += 1
        }
    }

    /// Runs worktree changes one at a time, so two jobs asking at once can't pick the same folder or race git's locks.
    private actor Serial {
        private var last: Task<Void, Never>?
        private var reserved: Set<String> = []

        func serially<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
            let previous = last
            let task = Task { () async throws -> T in
                await previous?.value
                return try await work()
            }
            last = Task { _ = try? await task.value }
            return try await task.value
        }

        /// A folder handed out stays taken for the app's lifetime, since `claude --worktree` makes it only later.
        func reserve(_ path: String) -> Bool { reserved.insert(path).inserted }
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
                // Drained on its own thread: a full stderr pipe blocks git before stdout ever closes.
                let drained = DispatchGroup(), errorBox = StderrBox()
                drained.enter()
                DispatchQueue.global().async {
                    errorBox.data = errors.fileHandleForReading.readDataToEndOfFile()
                    drained.leave()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                drained.wait()
                let message = errorBox.data
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0 else {
                    return continuation.resume(throwing: Failure.command(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                continuation.resume(returning: text)
            }
        }
    }
    #endif
}
