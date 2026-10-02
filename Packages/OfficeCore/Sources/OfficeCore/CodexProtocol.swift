import Foundation

/// Converts app-server v2 notifications into the office's provider-independent events.
/// No account calls or model turns are performed by the translator itself.
struct CodexProtocol {
    struct Update {
        var messages: [Data] = []
        var events: [WireEvent] = []
        var finished = false
    }
    let config: RunConfig
    private(set) var threadID: String?
    private var model: String?
    private var reply = ""
    private var usage = TokenUsage.zero
    private var contextWindow: Int?
    private var usageBaseline: TokenUsage?
    private var requests: [String: JSONValue] = [:]
    private var started = Set<String>()
    private var childParents: [String: String] = [:]
    private var fileChanges: [String: [String]] = [:]

    init(config: RunConfig) { self.config = config; model = config.model }

    static var initialize: Data {
        request("initialize", id: "city-init", params: ["clientInfo": ["name": "the_city", "title": "The City", "version": "1.0"],
                                                      "capabilities": ["experimentalApi": true]])
    }

    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(10)
        return data
    }
    static func request(_ method: String, id: String, params: [String: Any]) -> Data {
        line(["method": method, "id": id, "params": params])
    }

    var threadParams: [String: Any] {
        var params: [String: Any] = ["cwd": config.workingDirectory.path,
                                   "sandbox": config.permissionMode == .plan ? "read-only" : "workspace-write",
                                   "approvalPolicy": approvalPolicy,
                                   "approvalsReviewer": "user"]
        if let model { params["model"] = model }
        if let brief = config.appendSystemPrompt { params["developerInstructions"] = brief }
        if let resume = config.resumeSessionID { params["threadId"] = resume }
        return params
    }

    var approvalPolicy: String {
        switch config.permissionMode {
        case .auto: "on-request"
        case .acceptEdits, .manual: "untrusted"
        case .plan: "never"
        }
    }

    mutating func receive(_ raw: String) -> Update {
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return Update() }
        let params = json["params"] as? [String: Any] ?? [:]
        let method = json["method"] as? String ?? ""
        var update = Update()
        if let error = json["error"] as? [String: Any], json["id"] as? String != nil {
            update.events = [result(error: error["message"] as? String ?? "Codex request failed")]
            update.finished = true
            return update
        }
        switch json["id"] as? String {
        case "city-init":
            update.messages = [Self.line(["method": "initialized"]),
                               Self.request(config.resumeSessionID == nil ? "thread/start" : "thread/resume", id: "city-thread", params: threadParams)]
            return update
        case "city-thread":
            let response = json["result"] as? [String: Any] ?? [:]
            let thread = response["thread"] as? [String: Any] ?? [:]
            guard let id = thread["id"] as? String else {
                update.events = [result(error: "Codex did not return a thread ID")]; update.finished = true; return update
            }
            threadID = id
            model = response["model"] as? String ?? model
            update.events = [.sessionStarted(SessionInit(sessionID: id, model: model, cwd: config.workingDirectory.path, agents: []))]
            update.messages = [Self.request("turn/start", id: "city-turn", params: ["threadId": id, "input": [["type": "text", "text": config.request]]])]
            return update
        default: break
        }
        // Each server request must retain its original string or numeric JSON-RPC id.
        if let id = json["id"], !method.isEmpty {
            let key = Self.key(id)
            requests[key] = JSONValue(any: json)
            if method == "item/tool/requestUserInput" {
                let questions = params["questions"] as? [[String: Any]] ?? []
                var request = PermissionRequest(requestID: key, toolName: "AskUserQuestion", kind: .question(questions.map {
                    AskedQuestion(question: $0["question"] as? String ?? "", header: $0["header"] as? String,
                                  options: ($0["options"] as? [[String: Any]] ?? []).map {
                                      QuestionOption(label: $0["label"] as? String ?? "", description: $0["description"] as? String)
                                  }, multiSelect: false)
                }))
                request.input = .object([:])
                request.agentID = (params["threadId"] as? String).flatMap { childParents[$0] == nil ? nil : $0 }
                request.toolUseID = params["itemId"] as? String
                update.events = [.permissionRequest(request)]
            } else if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                let summary = [params["command"] as? String, params["reason"] as? String, params["grantRoot"] as? String].compactMap { $0 }.joined(separator: "\n")
                var request = PermissionRequest(requestID: key, toolName: method.contains("commandExecution") ? "Bash" : "Edit", kind: .approval(summary: summary.isEmpty ? "Approve Codex file changes" : summary))
                request.agentID = (params["threadId"] as? String).flatMap { childParents[$0] == nil ? nil : $0 }
                request.toolUseID = params["itemId"] as? String
                update.events = [.permissionRequest(request)]
            } else {
                // Unsupported server tools must receive an explicit error instead of hanging the turn.
                requests[key] = nil
                update.messages = [Self.line(["id": id, "error": ["code": -32601, "message": "The City does not support \(method)"]])]
            }
            return update
        }
        let sourceThread = params["threadId"] as? String
        let parent = sourceThread.flatMap { childParents[$0] }
        if let sourceThread, let threadID, sourceThread != threadID, parent == nil { return update }
        if method == "turn/completed", let sourceThread, parent != nil {
            let turn = params["turn"] as? [String: Any] ?? [:]
            update.events = [.taskNotification(taskID: sourceThread, toolUseID: parent, status: turn["status"] as? String)]
            return update
        }
        switch method {
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let id = item["id"] as? String else { break }
            let type = item["type"] as? String ?? ""
            let complete = method == "item/completed"
            if type == "agentMessage", complete {
                let text = item["text"] as? String ?? ""
                if parent == nil, !text.isEmpty { reply = text }
                update.events = [.assistant(AssistantMessage(messageID: id, parentToolUseID: parent, model: model, blocks: [.text(text)]))]
            } else if type == "reasoning", !complete {
                update.events = [.assistant(AssistantMessage(messageID: id, parentToolUseID: parent, model: model, blocks: [.thinking]))]
            } else if type == "fileChange" {
                let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                if started.insert(id).inserted {
                    fileChanges[id] = paths
                    for (index, path) in paths.enumerated() {
                        update.events.append(.assistant(AssistantMessage(messageID: id, parentToolUseID: parent, model: model, blocks: [
                            .toolUse(id: "\(id):\(index)", name: "Edit", subagentType: nil, description: nil,
                                     input: .object(["file_path": .string(path)]))
                        ])))
                    }
                }
                if complete {
                    let failed = ["failed", "declined"].contains(item["status"] as? String ?? "")
                    let results = (fileChanges.removeValue(forKey: id) ?? paths).enumerated().map {
                        ToolResult(toolUseID: "\(id):\($0.offset)", isError: failed, text: nil)
                    }
                    update.events.append(.user(UserMessage(parentToolUseID: parent, toolResults: results)))
                }
            } else if ["commandExecution", "mcpToolCall", "webSearch", "collabAgentToolCall"].contains(type) {
                if started.insert(id).inserted {
                    let name = toolName(item)
                    update.events.append(.assistant(AssistantMessage(messageID: id, parentToolUseID: parent, model: model, blocks: [
                        .toolUse(id: id, name: name, subagentType: nil, description: nil, input: toolInput(item))
                    ])))
                }
                if complete {
                    let status = item["status"] as? String ?? ""
                    let text = item["aggregatedOutput"] as? String ?? item["text"] as? String
                    let receivers = item["receiverThreadIds"] as? [String] ?? []
                    let spawned = type == "collabAgentToolCall" && item["tool"] as? String == "spawnAgent" && status == "completed"
                    if spawned {
                        for receiver in receivers {
                            childParents[receiver] = id
                            update.events.append(.taskStarted(TaskStarted(taskID: receiver, toolUseID: id, description: item["prompt"] as? String, isBackgrounded: true)))
                        }
                    }
                    update.events.append(.user(UserMessage(parentToolUseID: parent,
                        toolResults: [ToolResult(toolUseID: id, isError: ["failed", "declined"].contains(status), text: text)],
                        agentReport: spawned ? AgentReport(status: "async_launched") : nil)))
                }
            }
        case "serverRequest/resolved":
            if let id = params["requestId"] {
                let key = Self.key(id)
                requests[key] = nil
                update.events = [.controlResponse(requestID: key, commands: [])]
            }
        case "thread/tokenUsage/updated":
            guard parent == nil else { break }
            let tokenUsage = params["tokenUsage"] as? [String: Any] ?? [:]
            let last = Self.tokens(tokenUsage["last"] as? [String: Any] ?? [:])
            let total = Self.tokens(tokenUsage["total"] as? [String: Any] ?? [:])
            if usageBaseline == nil { usageBaseline = Self.subtract(total, last) }
            usage = Self.subtract(total, usageBaseline ?? .zero)
            contextWindow = tokenUsage["modelContextWindow"] as? Int
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let error = turn["error"] as? [String: Any]
            let status = turn["status"] as? String
            update.events = [result(error: status == "completed" ? nil : error?["message"] as? String ?? "Codex turn \(status ?? "failed")")]
            update.finished = true
        default: break
        }
        return update
    }

    mutating func respond(_ line: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let response = json["response"] as? [String: Any], let key = response["request_id"] as? String,
              let request = requests.removeValue(forKey: key), let originalID = request["id"] else { return nil }
        let answer = response["response"] as? [String: Any] ?? [:]
        let allowed = answer["behavior"] as? String == "allow"
        var result: [String: Any] = ["decision": allowed ? "accept" : "decline"]
        if request["method"]?.stringValue == "item/tool/requestUserInput" {
            let questions = (request["params"]?["questions"]?.any as? [[String: Any]]) ?? []
            let updated = answer["updatedInput"] as? [String: Any] ?? [:]
            let answers = updated["answers"] as? [String: String] ?? [:]
            var mapped: [String: Any] = [:]
            for question in questions {
                guard let id = question["id"] as? String, let text = question["question"] as? String else { continue }
                mapped[id] = ["answers": allowed ? answers[text].map { [$0] } ?? [] : []]
            }
            result = ["answers": mapped]
        }
        return Self.line(["id": originalID.any, "result": result])
    }

    private func result(error: String?) -> WireEvent {
        .result(RunResult(subtype: error == nil ? "success" : "error_during_execution", isError: error != nil,
                          text: error ?? reply, errors: error.map { [$0] } ?? [],
                          modelUsage: [model ?? "Codex": ModelUsage(usage: usage, contextWindow: contextWindow)]))
    }
    private func toolName(_ item: [String: Any]) -> String {
        switch item["type"] as? String {
        case "commandExecution": "Bash"
        case "fileChange": "Edit"
        case "mcpToolCall": McpNaming.toolPrefix(forServer: item["server"] as? String ?? "unknown") + (item["tool"] as? String ?? "tool")
        case "collabAgentToolCall": "Agent"
        default: "WebSearch"
        }
    }
    private func toolInput(_ item: [String: Any]) -> JSONValue {
        if item["type"] as? String == "fileChange" {
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return .object(["file_path": .string(paths.joined(separator: ", "))])
        }
        return JSONValue(any: item["arguments"] ?? item)
    }
    private static func tokens(_ json: [String: Any]) -> TokenUsage {
        let cached = json["cachedInputTokens"] as? Int ?? 0
        return TokenUsage(input: max(0, (json["inputTokens"] as? Int ?? 0) - cached), cacheCreation: json["cacheWriteInputTokens"] as? Int ?? 0,
                          cacheRead: cached, output: json["outputTokens"] as? Int ?? 0)
    }
    private static func subtract(_ total: TokenUsage, _ baseline: TokenUsage) -> TokenUsage {
        TokenUsage(input: max(0, total.input - baseline.input), cacheCreation: max(0, total.cacheCreation - baseline.cacheCreation),
                   cacheRead: max(0, total.cacheRead - baseline.cacheRead), output: max(0, total.output - baseline.output))
    }
    private static func key(_ id: Any) -> String { "codex:" + String(decoding: (try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed])) ?? Data(), as: UTF8.self) }
}
