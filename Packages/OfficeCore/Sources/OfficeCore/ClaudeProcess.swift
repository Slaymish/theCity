import Foundation

public enum RunnerOutput: Sendable, Equatable {
    case line(StreamLine)
    case exited(code: Int32, stderr: String)
}

public enum PermissionMode: String, Sendable, CaseIterable, Identifiable {
    case auto, acceptEdits, manual, plan

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .acceptEdits: "Accept edits"
        case .manual: "Ask every time"
        case .plan: "Plan only"
        }
    }

    public var detail: String {
        switch self {
        case .auto: "Runs tools without asking; Claude checks each action and only stops for risky ones."
        case .acceptEdits: "Edits files freely but asks before running commands."
        case .manual: "Asks before every tool that isn't already allowed."
        case .plan: "Reads and plans only; nothing is changed."
        }
    }
}

public struct RunConfig: Sendable, Equatable {
    public var request: String
    public var workingDirectory: URL
    public var claudeConfigDirectory: URL?
    public var model: String?
    public var maxBudgetUSD: Double?
    public var appendSystemPrompt: String?
    public var agents: String?
    public var resumeSessionID: String?
    public var blockedTools: [String]
    public var permissionMode: PermissionMode

    public init(request: String, workingDirectory: URL, claudeConfigDirectory: URL?, model: String?,
                maxBudgetUSD: Double?, appendSystemPrompt: String? = nil, agents: String? = nil, resumeSessionID: String? = nil,
                blockedTools: [String] = [], permissionMode: PermissionMode = .auto) {
        self.request = request
        self.workingDirectory = workingDirectory
        self.claudeConfigDirectory = claudeConfigDirectory
        self.model = model
        self.maxBudgetUSD = maxBudgetUSD
        self.appendSystemPrompt = appendSystemPrompt
        self.agents = agents
        self.resumeSessionID = resumeSessionID
        self.blockedTools = blockedTools
        self.permissionMode = permissionMode
    }

    /// `AskUserQuestion` only exists when a host answers `can_use_tool` over stdio; plain `-p` leaves it out.
    public var arguments: [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", permissionMode.rawValue,
            "--permission-prompt-tool", "stdio",
        ]
        if let resumeSessionID { args += ["--resume", resumeSessionID] }
        if !blockedTools.isEmpty { args += ["--disallowedTools", blockedTools.joined(separator: ",")] }
        if let model { args += ["--model", model] }
        if let appendSystemPrompt { args += ["--append-system-prompt", appendSystemPrompt] }
        if let agents { args += ["--agents", agents] }
        if let maxBudgetUSD { args += ["--max-budget-usd", String(maxBudgetUSD)] }
        return args
    }
}

public enum ClaudeEnvironment {
    static let sessionVariables: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID",
        "CLAUDE_EFFORT", "CLAUDE_CODE_EXECPATH",
    ]

    public static var extraPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local"]
    }

    /// Apps launched from Finder get a bare PATH and none of the shell's variables, so both are rebuilt here.
    public static func make(base: [String: String], configDirectory: URL?) -> [String: String] {
        var env = base.filter { !sessionVariables.contains($0.key) }
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in extraPaths.reversed() where !path.contains(extra) { path.insert(extra, at: 0) }
        env["PATH"] = path.joined(separator: ":")
        if let configDirectory { env["CLAUDE_CONFIG_DIR"] = configDirectory.path }
        return env
    }

    public static func locateCLI(environment: [String: String], alsoSearch extras: [String] = extraPaths) -> URL? {
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + extras
        return dirs.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `claude auth status` exits 1 when logged out; nil means the answer could not be read.
    public static func isLoggedIn(executable: URL, environment: [String: String]) async -> Bool? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = executable
                process.arguments = ["auth", "status"]
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return continuation.resume(returning: nil) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                continuation.resume(returning: json?["loggedIn"] as? Bool)
            }
        }
    }
}

public final class ClaudeProcess: @unchecked Sendable {
    public let output: AsyncStream<RunnerOutput>
    private let process = Process()
    private let lock = NSLock()
    private var cancelling = false
    private var input: FileHandle?

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL,
                keepInputOpen: Bool = false) throws {
        signal(SIGPIPE, SIG_IGN)
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        if keepInputOpen {
            let stdin = Pipe()
            process.standardInput = stdin
            input = stdin.fileHandleForWriting
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = stdout
        process.standardError = stderr

        let (stream, continuation) = AsyncStream.makeStream(of: RunnerOutput.self, bufferingPolicy: .unbounded)
        output = stream

        let finished = DispatchGroup()
        finished.enter()
        process.terminationHandler = { _ in finished.leave() }

        let stderrBox = StderrBox()
        finished.enter()
        DispatchQueue.global().async {
            stderrBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            finished.leave()
        }

        try process.run()

        let process = self.process
        finished.enter()
        Task.detached {
            await Self.readLines(from: stdout.fileHandleForReading) { continuation.yield(.line($0)) }
            finished.leave()
        }
        finished.notify(queue: .global()) {
            continuation.yield(.exited(code: process.terminationStatus, stderr: String(decoding: stderrBox.data, as: UTF8.self)))
            continuation.finish()
        }
    }

    @discardableResult
    public func send(_ line: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let input else { return false }
        do {
            try input.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    public func closeInput() {
        lock.lock()
        defer { lock.unlock() }
        try? input?.close()
        input = nil
    }

    /// SIGINT first: the CLI then marks running subagents killed and still writes its final `result` line.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelling, process.isRunning else { return }
        cancelling = true
        process.interrupt()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Splits on `\n` only: `AsyncLineSequence` also splits on U+2028, which JSON strings may contain unescaped.
    static func readLines(from handle: FileHandle, onLine: (StreamLine) -> Void) async {
        var buffer: [UInt8] = []
        var index = 0
        func flush() {
            guard !buffer.isEmpty else { return }
            onLine(StreamParser.parse(String(decoding: buffer, as: UTF8.self), index: index))
            index += 1
            buffer.removeAll(keepingCapacity: true)
        }
        do {
            for try await byte in handle.bytes {
                if byte == UInt8(ascii: "\n") { flush() } else { buffer.append(byte) }
            }
        } catch {}
        flush()
    }
}

private final class StderrBox: @unchecked Sendable {
    var data = Data()
}
