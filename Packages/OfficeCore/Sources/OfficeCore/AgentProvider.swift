import Foundation

public enum AgentProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude Code" : "Codex" }

    public func permissionDetail(_ mode: PermissionMode) -> String {
        guard self == .codex else { return mode.detail }
        switch mode {
        case .auto: return "Works inside the workspace sandbox; asks when it needs additional access."
        case .acceptEdits: return "Edits inside the workspace sandbox; asks before untrusted commands."
        case .manual: return "Asks before untrusted commands; trusted reads and workspace edits can proceed."
        case .plan: return "Uses a read-only sandbox and cannot request write access."
        }
    }
}

#if os(macOS)
public protocol AgentProcess: Sendable {
    var output: AsyncStream<RunnerOutput> { get }
    @discardableResult func send(_ line: Data) -> Bool
    func closeInput()
    func cancel()
}

extension ClaudeProcess: AgentProcess {}

public enum CodexEnvironment {
    public static func make(base: [String: String]) -> [String: String] {
        var env = ClaudeEnvironment.make(base: base, configDirectory: nil)
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        return env
    }

    public static func locateCLI(environment: [String: String]) -> URL? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" } + [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Metadata only: initialization, account and model inventory never start an agent turn.
    public static func inventory(executable: URL, environment: [String: String], directory: URL) async -> (loggedIn: Bool?, kit: Kit) {
        guard let process = try? ClaudeProcess(executable: executable, arguments: ["app-server"], environment: environment,
                                              workingDirectory: directory, keepInputOpen: true) else { return (nil, Kit()) }
        let timeout = DispatchWorkItem { process.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel(); process.closeInput(); process.cancel() }
        process.send(CodexProtocol.initialize)
        var accountRead = false, modelsRead = false, loggedIn: Bool?, kit = Kit()
        for await output in process.output {
            guard case .line(let line) = output,
                  let json = try? JSONSerialization.jsonObject(with: Data(line.raw.utf8)) as? [String: Any] else { continue }
            let id = json["id"] as? String
            let result = json["result"] as? [String: Any] ?? [:]
            if id == "city-init" {
                guard json["error"] == nil else { break }
                process.send(CodexProtocol.line(["method": "initialized"]))
                process.send(CodexProtocol.request("account/read", id: "account", params: ["refreshToken": false]))
                process.send(CodexProtocol.request("model/list", id: "models", params: ["limit": 100]))
            } else if id == "account" {
                accountRead = true
                if json["error"] == nil { loggedIn = result["account"] is [String: Any] || result["requiresOpenaiAuth"] as? Bool == false }
            } else if id == "models" {
                modelsRead = true
                kit.models = (result["data"] as? [[String: Any]] ?? []).compactMap { model in
                    guard let value = model["model"] as? String else { return nil }
                    return ModelOption(value: value, displayName: model["displayName"] as? String ?? value,
                                       description: model["description"] as? String ?? "")
                }
            }
            if accountRead && modelsRead { break }
        }
        return (loggedIn, kit)
    }
}
#endif
