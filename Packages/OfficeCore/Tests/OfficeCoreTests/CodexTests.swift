import Foundation
import Testing
@testable import OfficeCore

struct CodexTests {
    func config(resume: String? = nil, mode: PermissionMode = .manual) -> RunConfig {
        RunConfig(request: "Fix the login", workingDirectory: URL(fileURLWithPath: "/tmp/project"), claudeConfigDirectory: nil,
                  model: nil, maxBudgetUSD: nil, resumeSessionID: resume, permissionMode: mode)
    }
    func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func raw(_ object: [String: Any]) -> String { String(decoding: CodexProtocol.line(object), as: UTF8.self) }

    @Test func handshakeStartsOrResumesBeforeSendingThePrompt() throws {
        for resume in [nil, "old-thread"] as [String?] {
            var adapter = CodexProtocol(config: config(resume: resume))
            let initReply = adapter.receive(raw(["id": "city-init", "result": [:]]))
            #expect(initReply.messages.count == 2)
            let start = try json(initReply.messages[1])
            #expect(start["method"] as? String == (resume == nil ? "thread/start" : "thread/resume"))
            let params = try #require(start["params"] as? [String: Any])
            #expect(params["threadId"] as? String == resume)
            #expect(params["sandbox"] as? String == "workspace-write")
            let reply = adapter.receive(raw(["id": "city-thread", "result": ["thread": ["id": "thread-1"], "model": "test-model"]]))
            guard case .sessionStarted(let info) = try #require(reply.events.first) else { Issue.record("Missing session event"); return }
            #expect(info.sessionID == "thread-1")
            #expect(info.cwd == "/tmp/project")
            let turn = try json(try #require(reply.messages.first))
            #expect(turn["method"] as? String == "turn/start")
        }
    }

    @Test func planCannotEscalateForWriteAccess() {
        let adapter = CodexProtocol(config: config(mode: .plan))
        #expect(adapter.threadParams["sandbox"] as? String == "read-only")
        #expect(adapter.threadParams["approvalPolicy"] as? String == "never")
        #expect(CodexProtocol(config: config(mode: .auto)).approvalPolicy == "on-request")
    }

    @Test func approvalsPreserveNumericAndStringIDsAndNeverAutoApprove() throws {
        for id in [42, "approval-42"] as [Any] {
            for method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] {
                var adapter = CodexProtocol(config: config())
                let update = adapter.receive(raw(["id": id, "method": method, "params": ["command": "make test", "itemId": "cmd"]]))
                #expect(update.messages.isEmpty)
                guard case .permissionRequest(let request) = try #require(update.events.first) else { Issue.record("Missing approval"); return }
                let responseData = adapter.respond(ControlMessage.allow(request))
                let response = try json(try #require(responseData))
                #expect(JSONValue(any: response["id"]) == JSONValue(any: id))
                #expect((response["result"] as? [String: String])?["decision"] == "accept")
                #expect(adapter.respond(ControlMessage.allow(request)) == nil)
            }
        }
    }

    @Test func decliningAndAnsweringQuestionsUseTheCodexResponseSchema() throws {
        var adapter = CodexProtocol(config: config())
        let update = adapter.receive(raw(["id": 7, "method": "item/tool/requestUserInput", "params": ["questions": [
            ["id": "colour", "question": "Which colour?", "header": "Colour", "options": [["label": "Blue", "description": "Cool"]]]
        ]]]))
        guard case .permissionRequest(let request) = try #require(update.events.first) else { Issue.record("Missing question"); return }
        let responseData = adapter.respond(ControlMessage.answer(request, answers: ["Which colour?": "Blue"]))
        let response = try json(try #require(responseData))
        let result = try #require(response["result"] as? [String: Any])
        let answers = try #require(result["answers"] as? [String: [String: [String]]])
        #expect(answers["colour"]?["answers"] == ["Blue"])
        let approval = adapter.receive(raw(["id": 8, "method": "item/commandExecution/requestApproval", "params": ["command": "rm important"]]))
        guard case .permissionRequest(let pending) = try #require(approval.events.first) else { Issue.record("Missing request"); return }
        let deniedData = adapter.respond(ControlMessage.deny(pending, message: "No"))
        let denied = try json(try #require(deniedData))
        #expect((denied["result"] as? [String: String])?["decision"] == "decline")
    }

    @Test func toolEventsDriveTheReducerAndFinishOnTurnCompletion() throws {
        var adapter = CodexProtocol(config: config())
        var reducer = OfficeReducer()
        _ = reducer.apply(.launched)
        let item: [String: Any] = ["id": "cmd", "type": "commandExecution", "command": "make test", "status": "inProgress"]
        let started = adapter.receive(raw(["method": "item/started", "params": ["item": item]]))
        #expect(started.events.count == 1)
        #expect(adapter.receive(raw(["method": "item/started", "params": ["item": item]])).events.isEmpty)
        for event in started.events { _ = reducer.apply(.wire(event)) }
        let done = adapter.receive(raw(["method": "item/completed", "params": ["item": item.merging(["status": "completed", "aggregatedOutput": "passed"]) { _, new in new }]]))
        #expect(done.events.count == 1)
        for event in done.events { _ = reducer.apply(.wire(event)) }
        let text = adapter.receive(raw(["method": "item/completed", "params": ["item": ["id": "reply", "type": "agentMessage", "text": "Fixed", "phase": "final_answer"]]]))
        for event in text.events { _ = reducer.apply(.wire(event)) }
        let completion = adapter.receive(raw(["method": "turn/completed", "params": ["turn": ["status": "completed"]]]))
        #expect(completion.finished)
        for event in completion.events { _ = reducer.apply(.wire(event)) }
        _ = reducer.apply(.processExited(code: 0, stderr: ""))
        #expect(reducer.state.phase == .ended(.completed(summary: "Fixed", costUSD: nil)))
    }

    @Test func rpcErrorsAndFailedTurnsEndAsFailures() {
        var adapter = CodexProtocol(config: config())
        for object: [String: Any] in [
            ["id": "city-thread", "error": ["message": "Thread is missing"]],
            ["method": "turn/completed", "params": ["turn": ["status": "failed", "error": ["message": "Limit reached"]]]]
        ] {
            let update = adapter.receive(raw(object))
            #expect(update.finished)
            guard case .result(let result) = update.events.first else { Issue.record("Missing error result"); return }
            #expect(result.isError)
        }
    }

    @Test func unsupportedServerRequestsReceiveAnError() throws {
        var adapter = CodexProtocol(config: config())
        let update = adapter.receive(raw(["id": 9, "method": "unsupported/tool", "params": [:]]))
        let reply = try json(try #require(update.messages.first))
        #expect(reply["id"] as? Int == 9)
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32601)
    }
    @Test func aPatchRecordsEachSuccessfulFileSeparately() {
        var adapter = CodexProtocol(config: config())
        var reducer = OfficeReducer()
        _ = reducer.apply(.launched)
        let item: [String: Any] = ["id": "patch", "type": "fileChange", "status": "completed", "changes": [["path": "a.swift"], ["path": "b.swift"]]]
        let update = adapter.receive(raw(["method": "item/completed", "params": ["item": item]]))
        for event in update.events { _ = reducer.apply(.wire(event)) }
        #expect(reducer.state.outputFiles == ["a.swift", "b.swift"])
    }

    @Test func childCompletionDoesNotEndTheParentAndActivitiesGoToItsDesk() {
        var adapter = CodexProtocol(config: config())
        _ = adapter.receive(raw(["id": "city-thread", "result": ["thread": ["id": "parent"]]]))
        let spawn: [String: Any] = ["id": "spawn", "type": "collabAgentToolCall", "tool": "spawnAgent", "status": "completed", "receiverThreadIds": ["child"]]
        _ = adapter.receive(raw(["method": "item/completed", "params": ["threadId": "parent", "item": spawn]]))
        let activity = adapter.receive(raw(["method": "item/completed", "params": ["threadId": "child", "item": ["id": "reply", "type": "agentMessage", "text": "Research done"]]]))
        guard case .assistant(let message) = activity.events.first else { Issue.record("Missing child reply"); return }
        #expect(message.parentToolUseID == "spawn")
        let finish = adapter.receive(raw(["method": "turn/completed", "params": ["threadId": "child", "turn": ["status": "completed"]]]))
        #expect(!finish.finished)
        #expect(finish.events == [.taskNotification(taskID: "child", toolUseID: "spawn", status: "completed")])
    }

    @Test func resumedTokenTotalsExcludeThePriorConversation() {
        var adapter = CodexProtocol(config: config(resume: "prior"))
        func tokens(_ input: Int, _ output: Int) -> [String: Int] { ["inputTokens": input, "cachedInputTokens": 0, "outputTokens": output] }
        _ = adapter.receive(raw(["method": "thread/tokenUsage/updated", "params": ["tokenUsage": ["last": tokens(10, 5), "total": tokens(110, 55)]]]))
        _ = adapter.receive(raw(["method": "thread/tokenUsage/updated", "params": ["tokenUsage": ["last": tokens(20, 8), "total": tokens(130, 63)]]]))
        let update = adapter.receive(raw(["method": "turn/completed", "params": ["turn": ["status": "completed"]]]))
        guard case .result(let result) = update.events.first else { Issue.record("Missing result"); return }
        #expect(result.totalUsage.input == 30)
        #expect(result.totalUsage.output == 13)
        #expect(result.totalCostUSD == nil)
    }

}
