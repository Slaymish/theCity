import Foundation

public enum ToolCaption {
    public static let limit = 24
    public static let thinking = "thinking…"

    public static func text(name: String, input: JSONValue) -> String {
        let field = { (key: String) in input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        let file = { (key: String) in field(key).map { URL(fileURLWithPath: $0).lastPathComponent } }
        return switch name {
        case "Read", "NotebookRead": compose("reading ", file("file_path"))
        case "Write": compose("writing ", file("file_path"))
        case "Edit", "MultiEdit": compose("editing ", file("file_path"))
        case "NotebookEdit": compose("editing ", file("notebook_path"))
        case "Bash": compose("running ", field("description") ?? field("command").map { String($0.prefix { !$0.isWhitespace }) })
        case "BashOutput": "checking output"
        case "KillShell", "KillBash": "stopping a shell"
        case "Grep": compose("searching ", field("pattern"), quoted: true)
        case "Glob": compose("finding ", field("pattern"))
        case "WebSearch": compose("web: ", field("query"), quoted: true)
        case "WebFetch": compose("reading ", field("url").flatMap(host))
        case "Agent", "Task": compose("delegating: ", field("description") ?? field("subagent_type"))
        case "TodoWrite", "ExitPlanMode": "planning"
        case "Skill": compose("using ", field("skill"))
        default: compose("using ", name.components(separatedBy: "__").last)
        }
    }

    private static func compose(_ verb: String, _ detail: String?, quoted: Bool = false) -> String {
        guard let detail else { return verb.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: [":"]) }
        let wrap = quoted ? 2 : 0
        let room = limit - verb.count - wrap
        let fitted = detail.count <= room ? detail : String(detail.prefix(max(room - 1, 1))) + "…"
        return verb + (quoted ? "\"\(fitted)\"" : fitted)
    }

    private static func host(_ url: String) -> String? {
        guard let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
