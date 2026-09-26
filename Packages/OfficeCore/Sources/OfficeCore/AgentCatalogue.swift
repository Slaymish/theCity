import Foundation

public struct Department: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public enum AgentCatalogue {
    public static func load(workingDirectory: URL) -> [Department] {
        let folder = workingDirectory.appendingPathComponent(".claude/agents")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .compactMap(parse)
            .sorted { $0.name < $1.name }
    }

    public static func parse(_ markdown: String) -> Department? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        guard let name = fields["name"], !name.isEmpty else { return nil }
        return Department(name: name, description: fields["description"] ?? "")
    }

    public static func hiringBrief(for departments: [Department]) -> String {
        let names = departments.map(\.name).joined(separator: ", ")
        return "The office has hired these departments for this job, in working order: \(names). Delegate the work to them with the Agent tool, using exactly those subagent types."
    }
}
