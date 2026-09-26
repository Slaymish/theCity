import Foundation

public enum ParsedLine: Sendable, Equatable {
    case event(WireEvent)
    case malformed(reason: String)
}

public struct StreamLine: Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var raw: String
    public var parsed: ParsedLine

    public init(index: Int, raw: String, parsed: ParsedLine) {
        self.index = index
        self.raw = raw
        self.parsed = parsed
    }
}

public enum StreamParser {
    public static func parse(_ raw: String, index: Int) -> StreamLine {
        StreamLine(index: index, raw: raw, parsed: parse(raw))
    }

    public static func parse(_ raw: String) -> ParsedLine {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .malformed(reason: "Empty line") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        } catch {
            return .malformed(reason: "Not JSON")
        }
        guard let json = object as? [String: Any] else { return .malformed(reason: "Not a JSON object") }
        guard let type = json["type"] as? String else { return .malformed(reason: "Missing \"type\"") }
        let subtype = json["subtype"] as? String

        switch (type, subtype) {
        case ("system", "init"):
            return .event(.sessionStarted(SessionInit(
                sessionID: json["session_id"] as? String,
                model: json["model"] as? String,
                cwd: json["cwd"] as? String,
                agents: json["agents"] as? [String] ?? [],
                skills: json["skills"] as? [String] ?? [],
                mcpServers: (json["mcp_servers"] as? [[String: Any]] ?? []).compactMap { server in
                    (server["name"] as? String).map {
                        McpServer(name: $0, status: server["status"] as? String ?? "unknown", source: server["source"] as? String)
                    }
                }
            )))
        case ("system", "task_started"):
            guard let taskID = json["task_id"] as? String else { return .malformed(reason: "task_started without task_id") }
            return .event(.taskStarted(TaskStarted(
                taskID: taskID,
                toolUseID: json["tool_use_id"] as? String,
                subagentType: json["subagent_type"] as? String,
                description: json["description"] as? String,
                prompt: json["prompt"] as? String,
                isBackgrounded: json["is_backgrounded"] as? Bool ?? false
            )))
        case ("system", "task_progress"):
            guard let taskID = json["task_id"] as? String else { return .malformed(reason: "task_progress without task_id") }
            let usage = json["usage"] as? [String: Any]
            return .event(.taskProgress(TaskProgress(
                taskID: taskID,
                toolUseID: json["tool_use_id"] as? String,
                subagentType: json["subagent_type"] as? String,
                lastToolName: json["last_tool_name"] as? String,
                totalTokens: usage?["total_tokens"] as? Int,
                durationMs: usage?["duration_ms"] as? Int
            )))
        case ("system", "task_updated"):
            guard let taskID = json["task_id"] as? String else { return .malformed(reason: "task_updated without task_id") }
            let patch = json["patch"] as? [String: Any]
            return .event(.taskUpdated(taskID: taskID, status: patch?["status"] as? String))
        case ("system", "task_notification"):
            guard let taskID = json["task_id"] as? String else { return .malformed(reason: "task_notification without task_id") }
            return .event(.taskNotification(
                taskID: taskID,
                toolUseID: json["tool_use_id"] as? String,
                status: json["status"] as? String
            ))
        case ("system", "thinking_tokens"):
            return .event(.thinkingTokens(estimatedDelta: json["estimated_tokens_delta"] as? Int ?? 0))
        case ("system", "background_tasks_changed"):
            return .event(.backgroundTasksChanged(count: (json["tasks"] as? [Any])?.count ?? 0))
        case ("assistant", _):
            guard let message = json["message"] as? [String: Any] else { return .malformed(reason: "assistant without message") }
            return .event(.assistant(AssistantMessage(
                messageID: message["id"] as? String,
                parentToolUseID: json["parent_tool_use_id"] as? String,
                model: message["model"] as? String,
                blocks: contentArray(message).map(block),
                usage: (message["usage"] as? [String: Any]).map(snakeUsage),
                error: json["error"] as? String
            )))
        case ("user", _):
            guard let message = json["message"] as? [String: Any] else { return .malformed(reason: "user without message") }
            let results = contentArray(message).compactMap { item -> ToolResult? in
                guard item["type"] as? String == "tool_result", let id = item["tool_use_id"] as? String else { return nil }
                return ToolResult(toolUseID: id, isError: item["is_error"] as? Bool ?? false, text: resultText(item["content"]))
            }
            let report = (json["tool_use_result"] as? [String: Any]).flatMap { r -> AgentReport? in
                guard r["agentType"] != nil || r["agentId"] != nil else { return nil }
                return AgentReport(
                    agentType: r["agentType"] as? String,
                    status: r["status"] as? String,
                    totalTokens: r["totalTokens"] as? Int,
                    totalDurationMs: r["totalDurationMs"] as? Int
                )
            }
            return .event(.user(UserMessage(
                parentToolUseID: json["parent_tool_use_id"] as? String,
                toolResults: results,
                agentReport: report
            )))
        case ("control_request", _):
            guard let requestID = json["request_id"] as? String, let request = json["request"] as? [String: Any] else {
                return .malformed(reason: "control_request without request_id")
            }
            guard request["subtype"] as? String == "can_use_tool" else {
                return .event(.unknown(type: "control_request", subtype: request["subtype"] as? String))
            }
            return .event(.permissionRequest(PermissionRequest(requestID: requestID, request: request)))
        case ("control_response", _):
            let response = json["response"] as? [String: Any]
            let commands = ((response?["response"] as? [String: Any])?["commands"] as? [[String: Any]] ?? []).compactMap { command in
                (command["name"] as? String).map { CommandInfo(name: $0, description: command["description"] as? String ?? "") }
            }
            return .event(.controlResponse(requestID: response?["request_id"] as? String, commands: commands))
        case ("rate_limit_event", _):
            let info = json["rate_limit_info"] as? [String: Any]
            return .event(.rateLimit(RateLimit(
                status: info?["status"] as? String,
                resetsAt: (info?["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                kind: info?["rateLimitType"] as? String,
                windows: (info?["unifiedWindows"] as? [String: [String: Any]] ?? [:]).compactMapValues { window in
                    (window["utilization"] as? Double).map {
                        RateLimit.Window(utilization: $0, resetsAt: (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
                    }
                }
            )))
        case ("result", _):
            let modelUsage = (json["modelUsage"] as? [String: [String: Any]] ?? [:]).mapValues(camelUsage)
            return .event(.result(RunResult(
                subtype: subtype,
                isError: json["is_error"] as? Bool ?? false,
                text: json["result"] as? String,
                terminalReason: json["terminal_reason"] as? String,
                totalCostUSD: json["total_cost_usd"] as? Double,
                durationMs: json["duration_ms"] as? Int,
                numTurns: json["num_turns"] as? Int,
                errors: json["errors"] as? [String] ?? [],
                modelUsage: modelUsage
            )))
        default:
            return .event(.unknown(type: type, subtype: subtype))
        }
    }

    private static func contentArray(_ message: [String: Any]) -> [[String: Any]] {
        message["content"] as? [[String: Any]] ?? []
    }

    private static func block(_ item: [String: Any]) -> ContentBlock {
        switch item["type"] as? String {
        case "text":
            return .text(item["text"] as? String ?? "")
        case "thinking", "redacted_thinking":
            return .thinking
        case "tool_use":
            let input = item["input"] as? [String: Any]
            return .toolUse(
                id: item["id"] as? String ?? "",
                name: item["name"] as? String ?? "",
                subagentType: input?["subagent_type"] as? String,
                description: input?["description"] as? String,
                input: JSONValue(any: input)
            )
        case let other:
            return .other(type: other ?? "unknown")
        }
    }

    private static func resultText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        let parts = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func snakeUsage(_ u: [String: Any]) -> TokenUsage {
        TokenUsage(
            input: u["input_tokens"] as? Int ?? 0,
            cacheCreation: u["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
            output: u["output_tokens"] as? Int ?? 0
        )
    }

    private static func camelUsage(_ u: [String: Any]) -> TokenUsage {
        TokenUsage(
            input: u["inputTokens"] as? Int ?? 0,
            cacheCreation: u["cacheCreationInputTokens"] as? Int ?? 0,
            cacheRead: u["cacheReadInputTokens"] as? Int ?? 0,
            output: u["outputTokens"] as? Int ?? 0
        )
    }
}
