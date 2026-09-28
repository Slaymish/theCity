import Foundation

public enum KitLoader {
    /// A model name that cannot exist: the CLI still sends its handshake and `init` (skills, servers), then stops with `model_not_found` at no cost.
    static let inventoryModel = "office-inventory-no-such-model"

    #if os(macOS)
    public static func load(executable: URL, environment: [String: String], workingDirectory: URL) async -> Kit {
        async let lines = inventoryLines(executable: executable, environment: environment, workingDirectory: workingDirectory)
        async let health = mcpList(executable: executable, environment: environment, workingDirectory: workingDirectory)
        return Kit.from(lines: await lines, mcpList: await health)
    }

    static func inventoryLines(executable: URL, environment: [String: String], workingDirectory: URL) async -> [String] {
        let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--permission-prompt-tool", "stdio", "--no-session-persistence", "--model", inventoryModel]
        guard let process = try? ClaudeProcess(executable: executable, arguments: arguments, environment: environment,
                                               workingDirectory: workingDirectory, keepInputOpen: true) else { return [] }
        process.send(ControlMessage.initialize())
        process.send(ControlMessage.userMessage("inventory"))
        var lines: [String] = []
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            process.cancel()
        }
        for await output in process.output {
            guard case .line(let line) = output else { continue }
            lines.append(line.raw)
            if case .event(.result) = line.parsed { process.closeInput() }
        }
        timeout.cancel()
        return lines
    }

    static func mcpList(executable: URL, environment: [String: String], workingDirectory: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = executable
                process.arguments = ["mcp", "list"]
                process.environment = environment
                process.currentDirectoryURL = workingDirectory
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return continuation.resume(returning: nil) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    if process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
#endif
}
