import Foundation

/// A starting setup for a floor that suits one kind of work. Reception offers it only when a request fits.
public struct FloorPreset: Sendable, Equatable, Identifiable {
    public enum Session: String, Sendable {
        case fresh
        case long
    }

    public var id: String
    public var name: String
    public var purpose: String
    public var roles: [String]
    public var session: Session
    public var hints: [String]

    public init(id: String, name: String, purpose: String, roles: [String], session: Session, hints: [String]) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.roles = roles
        self.session = session
        self.hints = hints
    }

    public static func named(_ id: String?) -> FloorPreset? {
        id.flatMap { id in builtIn.first { $0.id == id } }
    }

    /// Ordered by precedence: a tie goes to the earlier preset, so a security review beats a plain review.
    public static let builtIn: [FloorPreset] = [
        FloorPreset(
            id: "security", name: "Security Review",
            purpose: "Audits code for vulnerabilities without changing it.",
            roles: ["security-reviewer"], session: .fresh,
            hints: ["security", "vulnerab", "audit", "cve", "secrets", "injection", "threat model", "pen test", "xss", "csrf", "permissions"]),
        FloorPreset(
            id: "bugfix", name: "Bug Fix",
            purpose: "Reproduces bugs, finds the root cause and fixes it with a test.",
            roles: ["debugger", "builder", "tester"], session: .fresh,
            hints: ["bug", "broken", "crash", "error", "fails", "failing", "regression", "flaky", "doesn't work", "not working", "exception", "stack trace"]),
        FloorPreset(
            id: "frontend", name: "Frontend",
            purpose: "Builds screens, components and visual changes that match the design.",
            roles: ["designer", "builder", "reviewer"], session: .long,
            hints: ["screen", "page", "component", "layout", "style", "figma", "penpot", "button", "css", "swiftui", "ui", "modal", "animation"]),
        FloorPreset(
            id: "review", name: "Code Review",
            purpose: "Reviews changes and runs the tests before they merge.",
            roles: ["reviewer", "tester"], session: .fresh,
            hints: ["review", "pull request", "diff", "before i merge", "check my changes", "code review", "look over"]),
        FloorPreset(
            id: "feature", name: "Feature Build",
            purpose: "Builds features and behaviour across several files, then tests and reviews them.",
            roles: ["researcher", "builder", "tester", "reviewer"], session: .long,
            hints: ["implement", "add support", "build", "feature", "endpoint", "integrate", "support for", "extend"]),
        FloorPreset(
            id: "quickfix", name: "Quick Fix",
            purpose: "Makes small, clear changes such as typos, renames and version bumps.",
            roles: ["builder"], session: .fresh,
            hints: ["typo", "rename", "bump", "one-line", "quick fix", "tweak"]),
        FloorPreset(
            id: "docs", name: "Docs & Copy",
            purpose: "Writes documentation, changelogs and user-facing text.",
            roles: ["writer"], session: .long,
            hints: ["readme", "docs", "documentation", "changelog", "release notes", "copy", "wording", "write up", "guide"]),
        FloorPreset(
            id: "research", name: "Deep Research",
            purpose: "Investigates questions, compares options and writes up what it finds.",
            roles: ["researcher", "writer"], session: .fresh,
            hints: ["research", "compare", "comparison", "options", "investigate", "evaluate", "which should", "how does", "why does", "explore", "alternatives", "summarise", "summarize"]),
    ]

    /// The preset whose hints a request uses most, or nil when none clearly fits.
    public static func match(_ request: String) -> FloorPreset? {
        let text = " " + request.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.joined(separator: " ") + " "
        let scored = builtIn.map { preset in
            (preset, preset.hints.filter { text.contains(" " + $0) }.count)
        }
        guard let top = scored.map(\.1).max(), top > 0 else { return nil }
        return scored.first { $0.1 == top }?.0
    }
}
