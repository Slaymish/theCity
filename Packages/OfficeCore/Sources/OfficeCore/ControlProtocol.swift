import Foundation

public struct QuestionOption: Sendable, Equatable, Hashable, Codable {
    public var label: String
    public var description: String?
}

public struct AskedQuestion: Sendable, Equatable, Hashable, Codable {
    public var question: String
    public var header: String?
    public var options: [QuestionOption]
    public var multiSelect: Bool
}

public struct PermissionRequest: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case question([AskedQuestion])
        case approval(summary: String)
    }

    public var id: String { requestID }
    public var requestID: String
    public var toolName: String
    public var toolUseID: String?
    /// Set when a subagent asks; equals that subagent's `task_id`.
    public var agentID: String?
    public var input: JSONValue
    public var kind: Kind
    /// The CLI's own rule for "always allow"; echoing it back as `updatedPermissions` makes the CLI save it.
    public var suggestions: JSONValue

    public var suggestedRules: [String] {
        guard case .array(let items) = suggestions else { return [] }
        return items.flatMap { item -> [String] in
            guard case .array(let rules)? = item["rules"] else { return [] }
            return rules.compactMap { rule in
                guard let tool = rule["toolName"]?.stringValue else { return nil }
                return rule["ruleContent"]?.stringValue.map { "\(tool)(\($0))" } ?? tool
            }
        }
    }

    /// A request rebuilt from a companion snapshot, which carries what the cards show but not the tool's input.
    public init(requestID: String, toolName: String, kind: Kind) {
        self.requestID = requestID
        self.toolName = toolName
        self.kind = kind
        input = .null
        suggestions = .null
    }

    init(requestID: String, request: [String: Any]) {
        self.requestID = requestID
        toolName = request["tool_name"] as? String ?? "unknown"
        toolUseID = request["tool_use_id"] as? String
        agentID = request["agent_id"] as? String
        input = JSONValue(any: request["input"])
        suggestions = JSONValue(any: request["permission_suggestions"])
        if toolName == "AskUserQuestion" {
            let questions = (request["input"] as? [String: Any])?["questions"] as? [[String: Any]] ?? []
            kind = .question(questions.map { q in
                AskedQuestion(
                    question: q["question"] as? String ?? "",
                    header: q["header"] as? String,
                    options: (q["options"] as? [[String: Any]] ?? []).map {
                        QuestionOption(label: $0["label"] as? String ?? "", description: $0["description"] as? String)
                    },
                    multiSelect: q["multiSelect"] as? Bool ?? false
                )
            })
        } else {
            let summary = input["command"]?.stringValue
                ?? input["file_path"]?.stringValue
                ?? input["url"]?.stringValue
                ?? request["description"] as? String
                ?? Self.compact(request["input"])
                ?? toolName
            kind = .approval(summary: summary)
        }
    }
}

extension PermissionRequest {
    public static func preview(question: String) -> PermissionRequest {
        PermissionRequest(requestID: "preview", request: [
            "tool_name": "AskUserQuestion",
            "input": ["questions": [["question": question, "options": [] as [Any]]]],
        ])
    }

    public static func preview(command: String, rule: String) -> PermissionRequest {
        PermissionRequest(requestID: "preview-approval", request: [
            "tool_name": "Bash",
            "input": ["command": command],
            "permission_suggestions": [["rules": [["toolName": "Bash", "ruleContent": rule]]]],
        ])
    }

    public static func preview(question: String, header: String, options: [String]) -> PermissionRequest {
        PermissionRequest(requestID: "preview-question", request: [
            "tool_name": "AskUserQuestion",
            "input": ["questions": [["question": question, "header": header, "options": options.map { ["label": $0] }]]],
        ])
    }

    static func compact(_ input: Any?) -> String? {
        guard let input = input as? [String: Any], !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Lines written to the CLI's stdin under `--input-format stream-json --permission-prompt-tool stdio`.
public enum ControlMessage {
    public static func initialize(requestID: String = UUID().uuidString) -> Data {
        line(["type": "control_request", "request_id": requestID, "request": ["subtype": "initialize"]])
    }

    public static func setPermissionMode(_ mode: PermissionMode, requestID: String = UUID().uuidString) -> Data {
        line(["type": "control_request", "request_id": requestID, "request": ["subtype": "set_permission_mode", "mode": mode.rawValue]])
    }

    public static func userMessage(_ text: String) -> Data {
        line(["type": "user", "message": ["role": "user", "content": text]])
    }

    public static func allow(_ request: PermissionRequest, always: Bool = false) -> Data {
        var response: [String: Any] = ["behavior": "allow", "updatedInput": request.input.any]
        if always, case .array = request.suggestions { response["updatedPermissions"] = request.suggestions.any }
        return respond(request.requestID, response)
    }

    public static func deny(_ request: PermissionRequest, message: String) -> Data {
        respond(request.requestID, ["behavior": "deny", "message": message])
    }

    /// Keyed by question text; a multi-select answer is its labels joined with ", ".
    public static func answer(_ request: PermissionRequest, answers: [String: String]) -> Data {
        let answered = request.input.setting("answers", to: .object(answers.mapValues { .string($0) }))
        return respond(request.requestID, ["behavior": "allow", "updatedInput": answered.any])
    }

    private static func respond(_ requestID: String, _ response: [String: Any]) -> Data {
        line(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": response]])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
