import Foundation
import OfficeCore

/// Gives floors and projects short labels, using a bare Haiku session.
@MainActor
enum FloorNamer {
    static func label(for request: String, avoiding existing: [String], configDirectory: URL?) async -> String? {
        let system = """
        You label floors in an office building. Each floor is a team working on a task. \
        Reply with only a label of two to four words, in title case, that captures what the task is about, \
        e.g. "Login Page Fixes" or "Quarterly Slide Deck". No quotes, no punctuation at the end.
        """
        return await ask(String(request.prefix(2000)), system: system, configDirectory: configDirectory)
            .flatMap { usable($0, existing: existing) }
    }

    /// Names a project for its building's billboard from the folder name and whatever describes it.
    static func projectName(folder: URL, configDirectory: URL?) async -> String? {
        let system = """
        You name projects. Given a folder name and any README or manifest text, reply with only the clear, \
        human name of the project in title case, one to four words, e.g. "The Office" for a folder called theOffice. \
        Prefer the name the project uses for itself. No quotes, no punctuation at the end.
        """
        let files = ["README.md", "README", "package.json", "Package.swift", "project.yml", "Cargo.toml", "pyproject.toml"]
        let context = files.compactMap { file -> String? in
            guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { return nil }
            return "\(file):\n\(text.prefix(1200))"
        }
        let prompt = (["Folder name: \(folder.lastPathComponent)"] + context).joined(separator: "\n\n")
        return await ask(prompt, system: system, configDirectory: configDirectory).flatMap { usable($0, existing: []) }
    }

    private static func ask(_ prompt: String, system: String, configDirectory: URL?) async -> String? {
        let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        guard let executable = ClaudeEnvironment.locateCLI(environment: environment) else { return nil }
        let arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--model", "haiku",
                         "--no-session-persistence", "--system-prompt", system, "--tools", "", "--strict-mcp-config",
                         "--mcp-config", #"{"mcpServers":{}}"#, "--disable-slash-commands", "--setting-sources", ""]
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

    private static func usable(_ raw: String, existing: [String]) -> String? {
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.").union(.whitespaces))
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        var candidate = trimmed
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(trimmed) \(n)"
            n += 1
        }
        return candidate
    }
}
