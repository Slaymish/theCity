import Foundation
import Testing
@testable import OfficeCore

struct ControlTests {
    static func requests(_ fixture: String) throws -> [PermissionRequest] {
        try Fixture.events(fixture).compactMap { if case .permissionRequest(let r) = $0 { r } else { nil } }
    }

    @Test func questionRequestCarriesTheQuestions() throws {
        let request = try #require(try Self.requests("ask-question.jsonl").first)
        #expect(request.toolName == "AskUserQuestion")
        #expect(request.agentID == nil)
        #expect(request.kind == .question([AskedQuestion(
            question: "Which colour do you prefer?", header: "Colour",
            options: [QuestionOption(label: "Red", description: "A warm, bold colour"),
                      QuestionOption(label: "Blue", description: "A cool, calm colour")],
            multiSelect: false)]))
    }

    @Test func answerEchoesInputWithAnswers() throws {
        let request = try #require(try Self.requests("ask-question.jsonl").first)
        let data = ControlMessage.answer(request, answers: ["Which colour do you prefer?": "Blue"])
        #expect(data.last == UInt8(ascii: "\n"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let response = try #require(json["response"] as? [String: Any])
        #expect(response["request_id"] as? String == request.requestID)
        let inner = try #require(response["response"] as? [String: Any])
        #expect(inner["behavior"] as? String == "allow")
        let updated = try #require(inner["updatedInput"] as? [String: Any])
        #expect((updated["answers"] as? [String: String]) == ["Which colour do you prefer?": "Blue"])
        #expect((updated["questions"] as? [Any])?.count == 1)
    }

    @Test func approvalsNameTheCommandAndTheAskingRoom() throws {
        let wire = try Fixture.events("approval-requests.jsonl")
        let requests = try Self.requests("approval-requests.jsonl")
        #expect(requests.map(\.kind) == [.approval(summary: "curl -sI https://example.com | head -1"),
                                         .approval(summary: "curl -sI https://example.com | head -1")])
        var reducer = OfficeReducer()
        let events = reducer.run(wire)
        let raised = events.compactMap { if case .handRaised(_, let room) = $0 { room } else { nil } }
        #expect(raised == ["general-purpose", "manager"])
        #expect(reducer.state.pendingRequests.count == 2)
        let lowered = reducer.apply(.requestResolved(requestID: requests[0].requestID))
        #expect(lowered == [.handLowered(requestID: requests[0].requestID, room: "general-purpose")])
    }

    @Test func endingTheRunLowersEveryHand() throws {
        var reducer = OfficeReducer()
        _ = reducer.run(try Fixture.events("approval-requests.jsonl"))
        let events = reducer.apply(.processExited(code: 0, stderr: ""))
        #expect(events.filter { if case .handLowered = $0 { true } else { false } }.count == 2)
        #expect(reducer.state.pendingRequests.isEmpty)
    }

    @Test func denyCarriesTheReason() throws {
        let request = try #require(try Self.requests("approval-requests.jsonl").last)
        let json = try JSONSerialization.jsonObject(with: ControlMessage.deny(request, message: "No")) as? [String: Any]
        let inner = (json?["response"] as? [String: Any])?["response"] as? [String: Any]
        #expect(inner?["behavior"] as? String == "deny")
        #expect(inner?["message"] as? String == "No")
    }

    @Test func catalogueReadsTheSampleWorkspace() {
        let departments = AgentCatalogue.load(workingDirectory: Fixture.directory.deletingLastPathComponent().appendingPathComponent("SampleWorkspace"))
        #expect(departments.filter { !$0.isBuiltIn }.map(\.name) == ["build", "design", "research", "review"])
        #expect(departments.drop { !$0.isBuiltIn }.allSatisfy { $0.isBuiltIn })
        #expect(departments.first?.description.hasPrefix("Builds the thing") == true)
    }

    @Test func catalogueHandlesQuotesAndRejectsMissingFrontmatter() {
        #expect(AgentCatalogue.parse("---\nname: \"ops\"\ndescription: 'Runs: things'\n---\nbody") == Department(name: "ops", description: "Runs: things"))
        #expect(AgentCatalogue.parse("no frontmatter") == nil)
    }
}

struct WorkflowTests {
    @Test func alwaysAllowEchoesTheCLIsSuggestion() throws {
        let request = try #require(try ControlTests.requests("always-allow.jsonl").first)
        #expect(request.suggestedRules == ["Bash(curl -sI https://example.com)"])
        let json = try JSONSerialization.jsonObject(with: ControlMessage.allow(request, always: true)) as? [String: Any]
        let inner = (json?["response"] as? [String: Any])?["response"] as? [String: Any]
        let updated = try #require(inner?["updatedPermissions"] as? [[String: Any]])
        #expect(updated.first?["destination"] as? String == "localSettings")
        let plain = try JSONSerialization.jsonObject(with: ControlMessage.allow(request)) as? [String: Any]
        #expect(((plain?["response"] as? [String: Any])?["response"] as? [String: Any])?["updatedPermissions"] == nil)
    }

    @Test func budgetExhaustionIsItsOwnFailure() throws {
        var reducer = OfficeReducer()
        let events = reducer.runToExit(try Fixture.events("budget-exceeded.jsonl"), code: 1)
        #expect(events.contains(.runEnded(.failed(.budgetExhausted, message: "Reached maximum budget ($0.01)"))))
    }

    @Test func resumedSessionKeepsItsID() throws {
        var reducer = OfficeReducer()
        _ = reducer.run(try Fixture.events("follow-up-resume.jsonl"))
        #expect(reducer.state.sessionID == "d6dac005-4b6b-499e-8fdf-d9d11e4997c9")
    }

    @Test func roomsRecordBriefToolsAndReport() throws {
        var reducer = OfficeReducer()
        _ = reducer.run(try Fixture.events("three-rooms.jsonl"))
        let research = try #require(reducer.state.handoffs(in: "research").first)
        #expect(research.brief == "Research greeting brief")
        #expect(research.prompt?.isEmpty == false)
        #expect(research.tools.map(\.name) == ["Glob", "Read", "Read"])
        #expect(research.tools.last?.summary?.hasSuffix("research.md") == true)
        #expect(research.report?.isEmpty == false)
    }

    @Test func outputFilesComeFromSuccessfulWrites() throws {
        var reducer = OfficeReducer()
        _ = reducer.run(try Fixture.events("three-rooms.jsonl"))
        #expect(reducer.state.outputFiles.map { URL(fileURLWithPath: $0).lastPathComponent } == ["hello.txt"])
    }
}

struct PendingRequestAgeTests {
    private let request = PermissionRequest(requestID: "a", toolName: "Bash", kind: .approval(summary: "ls"))

    @Test func remembersWhenItArrived() {
        let then = Date(timeIntervalSince1970: 1000)
        #expect(PendingRequest(request: request, room: "build", since: then).since == then)
    }

    @Test func arrivalTimeIsNotPartOfEquality() {
        let early = PendingRequest(request: request, room: "build", since: Date(timeIntervalSince1970: 1))
        let late = PendingRequest(request: request, room: "build", since: Date(timeIntervalSince1970: 2))
        #expect(early == late)
    }
}
