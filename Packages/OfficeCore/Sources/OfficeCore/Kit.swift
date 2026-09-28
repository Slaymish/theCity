import Foundation

public enum McpNaming {
    /// Tool names are `mcp__<server>__<tool>`, with every character of the server name outside `[A-Za-z0-9_-]` turned into `_`.
    public static func toolPrefix(forServer server: String) -> String {
        let safe = server.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "_" || scalar == "-" ? String(scalar) : "_"
        }.joined()
        return "mcp__\(safe)__"
    }

    public static func split(_ toolName: String, servers: [String]) -> (server: String, tool: String)? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        if let server = servers.first(where: { toolName.hasPrefix(toolPrefix(forServer: $0)) }) {
            return (server, String(toolName.dropFirst(toolPrefix(forServer: server).count)))
        }
        let parts = toolName.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts.dropFirst().joined(separator: "__"))
    }

    public static func friendly(_ toolName: String, servers: [String]) -> String {
        split(toolName, servers: servers).map { "\($0.server) › \($0.tool)" } ?? toolName
    }
}

public struct ModelOption: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { value }
    public var value: String
    public var displayName: String
    public var description: String
}

public enum HandBack {
    /// The CLI wraps a subagent's report in a notice for the model; the user only needs the indented report inside it.
    public static func clean(_ text: String) -> String {
        guard let marker = text.range(of: "The report follows:\n") else { return text }
        var lines = text[marker.upperBound...].components(separatedBy: "\n")
        if let trailer = lines.firstIndex(where: { $0.hasPrefix("agentId: ") || $0.hasPrefix("<usage>") }) {
            lines = Array(lines[..<trailer])
        }
        return lines.map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SlashCommand {
    /// Completions while the text is a lone `/query`: names starting with the query first, then names containing it.
    public static func matches(for text: String, in commands: [CommandInfo], limit: Int = 6) -> [CommandInfo] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let query = text.dropFirst().lowercased()
        let starts = commands.filter { $0.name.lowercased().hasPrefix(query) }
        let contains = commands.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
        return Array((starts + contains).prefix(limit))
    }

    /// Splits `/name arguments` into a known command and its trimmed arguments.
    public static func parse(_ text: String, commands: [CommandInfo]) -> (command: CommandInfo, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let name = trimmed.dropFirst().prefix { !$0.isWhitespace }
        guard !name.isEmpty, let command = commands.first(where: { $0.name == name }) else { return nil }
        return (command, trimmed.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct Kit: Sendable, Equatable {
    public var models: [ModelOption] = []
    public var servers: [McpServer]
    public var skills: [CommandInfo]
    /// Every slash command, skills included, with its description; the job field's picker lists these.
    public var commands: [CommandInfo]

    public init(servers: [McpServer] = [], skills: [CommandInfo] = [], commands: [CommandInfo] = []) {
        self.servers = servers
        self.skills = skills
        self.commands = commands
    }

    public var usableServers: [McpServer] { servers.filter { $0.status == "connected" } }

    /// Builds the kit from an inventory stream (handshake plus `init`) and `claude mcp list` output.
    public static func from(lines: [String], mcpList: String?) -> Kit {
        var session: SessionInit?
        var commands: [CommandInfo] = []
        var models: [ModelOption] = []
        for line in lines {
            switch StreamParser.parse(line) {
            case .event(.sessionStarted(let s)): session = s
            case .event(.controlResponse(_, let c)) where !c.isEmpty:
                commands = c
                models = modelOptions(line)
            default: break
            }
        }
        let health = mcpList.map(parseMcpList) ?? [:]
        let servers = (session?.mcpServers ?? []).map { server in
            McpServer(name: server.name, status: health[server.name] ?? server.status, source: server.source)
        }
        let described = Dictionary(commands.map { ($0.name, $0.description) }, uniquingKeysWith: { first, _ in first })
        let skills = (session?.skills ?? []).map { CommandInfo(name: $0, description: described[$0] ?? "") }
        var kit = Kit(servers: servers, skills: skills, commands: commands)
        kit.models = models
        return kit
    }

    static func modelOptions(_ line: String) -> [ModelOption] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let response = (json["response"] as? [String: Any])?["response"] as? [String: Any],
              let models = response["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let value = model["value"] as? String, value != KitLoader.inventoryModel else { return nil }
            return ModelOption(value: value, displayName: model["displayName"] as? String ?? value,
                               description: model["description"] as? String ?? "")
        }
    }

    /// `claude mcp list` prints `name: target - ✔ Connected`; names may contain `:` but not `: `.
    public static func parseMcpList(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let nameEnd = line.range(of: ": "), let statusStart = line.range(of: " - ", options: .backwards),
                  nameEnd.lowerBound < statusStart.lowerBound else { continue }
            let name = String(line[..<nameEnd.lowerBound])
            let status = line[statusStart.upperBound...].lowercased()
            result[name] = if status.contains("connected") && !status.contains("fail") { "connected" }
                else if status.contains("pending") { "pending" }
                else if status.contains("auth") { "needs-auth" }
                else if status.contains("fail") || status.contains("✘") { "failed" }
                else { "unknown" }
        }
        return result
    }

    public static func blockRules(servers: [McpServer], allowedServers: Set<String>, skills: [CommandInfo], allowedSkills: Set<String>) -> [String] {
        servers.filter { !allowedServers.contains($0.name) }.map { String(McpNaming.toolPrefix(forServer: $0.name).dropLast(2)) }
            + skills.filter { !allowedSkills.contains($0.name) }.map { "Skill(\($0.name))" }
    }
}

extension Kit {
    /// The skills and services a request names or describes, matched by word so hiring needn't wait on a model.
    public func matching(_ request: String) -> (servers: Set<String>, skills: Set<String>) {
        let asked = Self.words(request)
        let servers = usableServers.filter { !Self.words($0.name).isDisjoint(with: asked) }.map(\.name)
        let skills = skills.filter { skill in
            !Self.words(skill.name).isDisjoint(with: asked) || Self.words(skill.description).intersection(asked).count >= 2
        }.map(\.name)
        return (Set(servers), Set(skills))
    }

    static func words(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "for", "with", "use", "used", "when", "this", "that", "from", "into", "your", "you",
                                 "can", "any", "all", "are", "not", "our", "also", "asks", "asked", "user", "make", "code", "please", "want"]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { word in
            word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : String(word)
        }.filter { $0.count > 2 && !stop.contains($0) })
    }
}
