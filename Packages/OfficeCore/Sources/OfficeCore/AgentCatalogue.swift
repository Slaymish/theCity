import Foundation

public struct Department: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var prompt: String
    public var tools: [String]?
    public var isBuiltIn: Bool

    public init(name: String, description: String, prompt: String = "", tools: [String]? = nil, isBuiltIn: Bool = false) {
        self.name = name
        self.description = description
        self.prompt = prompt
        self.tools = tools
        self.isBuiltIn = isBuiltIn
    }
}

public enum AgentCatalogue {
    /// Project agents come first and replace a built-in of the same name.
    public static func load(workingDirectory: URL) -> [Department] {
        let folder = workingDirectory.appendingPathComponent(".claude/agents")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let project = files
            .filter { $0.pathExtension == "md" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .compactMap(parse)
            .sorted { $0.name < $1.name }
        let names = Set(project.map(\.name))
        return project + builtIn.filter { !names.contains($0.name) }
    }

    public static let builtIn: [Department] = [
        Department(
            name: "researcher",
            description: "Reads the codebase, docs and the web to answer a question before anyone builds. Writes no files.",
            prompt: "You are the office researcher. Investigate the question you are given by reading the codebase, its documentation and, where useful, the web. Report findings with file paths and sources, separate what you verified from what you inferred, and keep the summary short. Do not edit files.",
            tools: ["Read", "Grep", "Glob", "WebSearch", "WebFetch"],
            isBuiltIn: true),
        Department(
            name: "designer",
            description: "Shapes interfaces and user flows, matching the project's existing components and tokens.",
            prompt: "You are the office designer. Work out the interface or user flow for the task, reusing the project's existing components, design tokens and conventions. Never invent colours, spacing or type sizes the project does not already define; list anything missing as a question instead. Implement the design when asked to build it.",
            isBuiltIn: true),
        Department(
            name: "builder",
            description: "Writes and edits code to implement a planned change, following the project's conventions.",
            prompt: "You are the office builder. Implement the change you are given with the smallest diff that does the job, following the conventions already in the codebase. Build or type-check when the project allows it, and report what you changed and anything left undone.",
            isBuiltIn: true),
        Department(
            name: "reviewer",
            description: "Reviews changes for bugs, regressions and unclear code. Writes no files.",
            prompt: "You are the office reviewer. Review the changes you are pointed at for correctness bugs, regressions, security issues and needless complexity. Report each finding with a file and line, the concrete failure, and a suggested fix, most severe first. Do not edit files.",
            tools: ["Read", "Grep", "Glob"],
            isBuiltIn: true),
        Department(
            name: "security-reviewer",
            description: "Audits code for security vulnerabilities, most severe first. Writes no files.",
            prompt: "You are the office security reviewer. Audit the code you are pointed at for vulnerabilities: injection, broken authentication or authorisation, exposed secrets, unsafe deserialisation, insecure dependencies and data leaks. Report only real, exploitable issues, each with a file and line, how it could be exploited, and a fix, most severe first. Do not edit files.",
            tools: ["Read", "Grep", "Glob", "WebSearch", "WebFetch"],
            isBuiltIn: true),
        Department(
            name: "debugger",
            description: "Reproduces a bug and finds its root cause before anyone changes the code.",
            prompt: "You are the office debugger. Reproduce the bug you are given, ideally as a failing test, then trace it to its root cause. Report the reproduction steps, the cause with file and line, and the smallest fix that addresses the cause rather than the symptom. Only add the failing test; leave the fix to the builder.",
            isBuiltIn: true),
        Department(
            name: "tester",
            description: "Writes and runs tests, then reports what passes and what fails.",
            prompt: "You are the office tester. Find how the project runs its tests, add or update tests that cover the change you are given, run them, and report the results faithfully, including failing output.",
            isBuiltIn: true),
        Department(
            name: "writer",
            description: "Writes documentation, READMEs, changelogs and user-facing copy.",
            prompt: "You are the office writer. Write or update documentation and user-facing text for the task, matching the project's existing tone and spelling. Be concise and concrete.",
            tools: ["Read", "Grep", "Glob", "Write", "Edit"],
            isBuiltIn: true),
    ]

    /// The JSON for `claude --agents`, so built-ins work without files in the project.
    public static func agentsJSON(for departments: [Department]) -> String? {
        var agents: [String: [String: Any]] = [:]
        for department in departments where department.isBuiltIn {
            var agent: [String: Any] = ["description": department.description, "prompt": department.prompt]
            if let tools = department.tools { agent["tools"] = tools }
            agents[department.name] = agent
        }
        guard !agents.isEmpty, let data = try? JSONSerialization.data(withJSONObject: agents, options: .sortedKeys) else { return nil }
        return String(data: data, encoding: .utf8)
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
        return "Hired subagents for this job, in their usual order: \(names). Delegate each stage the job needs to its matching subagent via the Agent tool, with subagent_type exactly as named. Subagents cannot see this conversation, so give each a self-contained brief: the goal, relevant file paths and earlier stages' findings. Do trivial steps yourself and skip stages the job does not need."
    }
}
