import Foundation
import OfficeCore

enum Wording {
    static func verb(_ toolName: String) -> String {
        if let split = McpNaming.split(toolName, servers: []) { return "Calling \(OfficeScene.shortName(split.server))" }
        return switch toolName {
        case "Read", "NotebookRead": "Reading"
        case "Glob", "Grep", "LS": "Searching"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": "Writing"
        case "Bash", "BashOutput": "Running a command"
        case "WebFetch", "WebSearch": "Browsing"
        case "Skill": "Using a skill"
        case "ToolSearch": "Finding tools"
        case "TodoWrite": "Planning"
        case "Agent", "Task": "Delegating"
        default: toolName
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

struct ActivityItem: Identifiable, Equatable {
    let id = UUID()
    let room: String
    let text: String
}
