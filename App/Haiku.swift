import Foundation
import OfficeCore

/// One bare Haiku request on a Claude account, with no tools, servers, settings or saved session.
@MainActor
enum Haiku {
    static func ask(_ prompt: String, system: String, schema: String? = nil, configDirectory: URL?) async -> String? {
        let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        guard let executable = RunController.executable(environment: environment) else { return nil }
        var arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--model", "haiku",
                         "--no-session-persistence", "--system-prompt", system, "--tools", "", "--strict-mcp-config",
                         "--mcp-config", #"{"mcpServers":{}}"#, "--disable-slash-commands", "--setting-sources", ""]
        if let schema { arguments += ["--json-schema", schema] }
        guard let process = try? ClaudeProcess(executable: executable, arguments: arguments, environment: environment,
                                               workingDirectory: FileManager.default.temporaryDirectory) else { return nil }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            process.cancel()
        }
        defer { timeout.cancel() }
        var text: String?
        for await output in process.output {
            if case .line(let line) = output, case .event(.result(let result)) = line.parsed, !result.isError { text = result.text }
        }
        return text
    }

    /// With a schema, the result text is the JSON the schema describes.
    static func ask<Reply: Decodable>(_ reply: Reply.Type, prompt: String, system: String, schema: String, configDirectory: URL?) async -> Reply? {
        guard let text = await ask(prompt, system: system, schema: schema, configDirectory: configDirectory) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: Data(text.utf8))
    }
}
