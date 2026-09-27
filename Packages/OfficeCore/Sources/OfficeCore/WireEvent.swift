import Foundation

public enum WireEvent: Sendable, Equatable {
    case sessionStarted(SessionInit)
    case assistant(AssistantMessage)
    case user(UserMessage)
    case taskStarted(TaskStarted)
    case taskProgress(TaskProgress)
    case taskUpdated(taskID: String, status: String?)
    case taskNotification(taskID: String, toolUseID: String?, status: String?)
    case thinkingTokens(estimatedDelta: Int)
    case backgroundTasksChanged(count: Int)
    case permissionRequest(PermissionRequest)
    case controlResponse(requestID: String?, commands: [CommandInfo])
    case rateLimit(RateLimit)
    case result(RunResult)
    case unknown(type: String, subtype: String?)
}

public struct RateLimit: Sendable, Equatable {
    public struct Window: Sendable, Equatable, Codable {
        public var utilization: Double
        public var resetsAt: Date?
    }

    public var status: String?
    public var resetsAt: Date?
    public var kind: String?
    /// Share of the plan's rolling limits used so far: `five_hour` (the session) and `seven_day` (the week).
    public var windows: [String: Window] = [:]
    /// True once the plan's limits are used up and the job is spending extra-usage credits.
    public var isUsingOverage = false

    public var isRejected: Bool { status == "rejected" }
}

public struct SessionInit: Sendable, Equatable {
    public var sessionID: String?
    public var model: String?
    public var cwd: String?
    public var agents: [String]
    public var skills: [String] = []
    public var mcpServers: [McpServer] = []
}

public struct McpServer: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var status: String
    public var source: String?

    public init(name: String, status: String, source: String?) {
        self.name = name
        self.status = status
        self.source = source
    }
}

public struct CommandInfo: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public struct TokenUsage: Sendable, Equatable {
    public var input: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    public var output: Int

    public static let zero = TokenUsage(input: 0, cacheCreation: 0, cacheRead: 0, output: 0)

    public var total: Int { input + cacheCreation + cacheRead + output }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            output: lhs.output + rhs.output
        )
    }
}

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case thinking
    case toolUse(id: String, name: String, subagentType: String?, description: String?, input: JSONValue)
    case other(type: String)
}

public struct AssistantMessage: Sendable, Equatable {
    /// Shared by every event that carries a block of the same API message.
    public var messageID: String?
    /// Nil for the main session; the spawning `Agent` tool_use id for a subagent.
    public var parentToolUseID: String?
    public var model: String?
    public var blocks: [ContentBlock]
    public var usage: TokenUsage?
    public var error: String?
}

public struct ToolResult: Sendable, Equatable {
    public var toolUseID: String
    public var isError: Bool
    public var text: String?
}

public struct AgentReport: Sendable, Equatable {
    public var agentType: String?
    /// `async_launched` for a background subagent: an acknowledgement, not a finish.
    public var status: String?
    public var totalTokens: Int?
    public var totalDurationMs: Int?
}

public struct UserMessage: Sendable, Equatable {
    public var parentToolUseID: String?
    public var toolResults: [ToolResult]
    public var agentReport: AgentReport?
}

public struct TaskStarted: Sendable, Equatable {
    public var taskID: String
    public var toolUseID: String?
    public var subagentType: String?
    public var description: String?
    public var prompt: String?
    public var isBackgrounded: Bool
}

public struct TaskProgress: Sendable, Equatable {
    public var taskID: String
    public var toolUseID: String?
    public var subagentType: String?
    public var lastToolName: String?
    public var totalTokens: Int?
    public var durationMs: Int?
}

public struct RunResult: Sendable, Equatable {
    public var subtype: String?
    /// A not-logged-in run reports `subtype: "success"` with `is_error: true`, so this is the field to trust.
    public var isError: Bool
    public var text: String?
    public var terminalReason: String?
    public var totalCostUSD: Double?
    public var durationMs: Int?
    public var numTurns: Int?
    public var errors: [String]
    /// Keyed by model id; includes subagent usage, unlike the top-level `usage`. Cumulative across a process's results.
    public var modelUsage: [String: TokenUsage]

    public var totalUsage: TokenUsage { modelUsage.values.reduce(.zero, +) }
}
