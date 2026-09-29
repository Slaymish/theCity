import Foundation
import Testing
@testable import OfficeCore

/// Paths through the reducer that the recorded stories skip over.
struct ReducerEdgeTests {
    @Test func launchingStartsTheRunOnceBeforeAnyLineArrives() throws {
        var reducer = OfficeReducer()
        #expect(reducer.state.phase == .idle)
        #expect(reducer.apply(.launched).contains(.runStarted))
        #expect(reducer.state.phase == .running)
        let rest = reducer.runToExit(try Fixture.events("three-rooms.jsonl"))
        #expect(!rest.contains(.runStarted))
        #expect(reducer.apply(.launched).isEmpty)
    }

    @Test func everyChangeToTheTallyIsAnnounced() throws {
        for fixture in ["three-rooms.jsonl", "haiku-manager.jsonl", "cancelled.jsonl"] {
            var reducer = OfficeReducer()
            var announced = 0
            for event in try Fixture.events(fixture) {
                let before = reducer.state.tally
                let events = reducer.apply(.wire(event))
                guard reducer.state.tally != before else { continue }
                #expect(events.contains(.tallyChanged(reducer.state.tally)), "\(fixture): \(event) changed the tally silently")
                announced += 1
            }
            #expect(announced > 0)
        }
    }

    @Test func aTaskThatStartsWithoutItsSpawnStillGetsARoom() throws {
        let wire = try Fixture.events("three-rooms.jsonl")
        guard case .taskStarted(let task) = wire[2] else { Issue.record("line 2 is not task_started"); return }
        var reducer = OfficeReducer()
        let events = reducer.run([wire[0], wire[2]])
        let id = try #require(task.toolUseID)
        #expect(events.contains(.handoff(toolUseID: id, room: task.subagentType ?? "general-purpose", description: task.description)))
        #expect(events.contains(.roomStarted(toolUseID: id, room: task.subagentType ?? "general-purpose")))
        #expect(reducer.state.handoffs[id]?.phase == .working)
        #expect(reducer.state.handoffs[id]?.brief == task.description)
    }

    @Test func aRunErrorThatIsNotAboutSigningInSaysWhatWentWrong() throws {
        var reducer = OfficeReducer()
        let events = reducer.runToExit(try Fixture.events("inventory.jsonl"), code: 1)
        guard case .runEnded(.failed(.runError, let message)) = events.last(where: { if case .runEnded = $0 { true } else { false } }) else {
            Issue.record("expected a run error, got \(events.suffix(2))")
            return
        }
        #expect(message?.isEmpty == false)
    }

    @Test func servicesAndSkillsAreRememberedForTheRun() throws {
        var reducer = OfficeReducer()
        _ = reducer.runToExit(try Fixture.events("skill-and-mcp.jsonl"))
        #expect(!reducer.state.mcpServers.isEmpty)
        #expect(reducer.state.mcpServers.contains { $0.name.contains("specification-website") })
        #expect(reducer.state.skillsByRoom["manager"] == ["office-house-style"])
        #expect(reducer.state.serviceCallsByServer.values.reduce(0, +) >= 2)
    }

    @Test func contextNeedsAKnownNonZeroWindow() {
        var state = OfficeState()
        state.mainModel = "m"
        state.contextTokens = 50
        #expect(state.contextFraction() == nil)
        #expect(state.contextFraction(windows: ["m": 0]) == nil)
        #expect(state.contextFraction(windows: ["m": 100]) == 0.5)
        state.contextWindows["m"] = 200
        #expect(state.contextFraction(windows: ["m": 100]) == 0.25)
    }

    @Test func aToolsSummaryPrefersItsTarget() {
        let input = JSONValue(any: ["description": "List files", "command": "ls -la", "pattern": "*.swift"])
        #expect(ToolCall(name: "Bash", input: input).summary == "ls -la")
        #expect(ToolCall(name: "Agent", input: JSONValue(any: ["description": "Research"])).summary == "Research")
        #expect(ToolCall(name: "Read", input: .null).summary == nil)
    }

    @Test func aHandoffStartsInTheForeground() {
        #expect(!Handoff(toolUseID: "t", room: "r", taskID: nil, phase: .requested).isBackground)
    }

    @Test func roomCountsKeepEveryField() {
        #expect(RoomCounts(working: 1, idle: 2, waiting: 3).waiting == 3)
        #expect(RoomCounts(working: 1, idle: 2, waiting: 3) + RoomCounts(waiting: 1) == RoomCounts(working: 1, idle: 2, waiting: 4))
    }
}

struct RequestParsingTests {
    @Test func aQuestionWithoutMultiSelectIsSingleChoice() {
        let request = PermissionRequest(requestID: "r", request: [
            "tool_name": "AskUserQuestion", "tool_use_id": "toolu_1", "agent_id": "a1",
            "input": ["questions": [["question": "Pick", "options": [["label": "A"]]]]],
        ])
        #expect(request.toolUseID == "toolu_1")
        #expect(request.agentID == "a1")
        #expect(request.kind == .question([AskedQuestion(question: "Pick", header: nil, options: [QuestionOption(label: "A", description: nil)], multiSelect: false)]))
    }

    @Test func approvalsAreSummarisedByWhatTheyTouch() {
        func summary(_ input: [String: Any], description: String? = nil) -> String? {
            var request: [String: Any] = ["tool_name": "Tool", "input": input]
            if let description { request["description"] = description }
            if case .approval(let text) = PermissionRequest(requestID: "r", request: request).kind { return text }
            return nil
        }
        #expect(summary(["command": "ls", "file_path": "/a"]) == "ls")
        #expect(summary(["file_path": "/a", "url": "https://x"]) == "/a")
        #expect(summary(["url": "https://x"], description: "Fetch") == "https://x")
        #expect(summary([:], description: "Fetch") == "Fetch")
    }
}

struct KitEdgeTests {
    @Test func unknownServersAreSplitAtTheirFirstSeparator() {
        let split = McpNaming.split("mcp__github__create_issue", servers: [])
        #expect(split?.server == "github")
        #expect(split?.tool == "create_issue")
        #expect(McpNaming.split("mcp__github", servers: []) == nil)
        #expect(McpNaming.split("Read", servers: ["github"]) == nil)
    }

    @Test func mcpListStatusesAreRead() {
        let text = """
        github: https://example.com/mcp (HTTP) - ✔ Connected
        slack: https://example.com/slack (HTTP) - ✘ Failed to connect
        broken: npx broken - failed
        crossed: npx crossed - ✘
        linear: https://example.com/linear (HTTP) - ⚠ Needs authentication
        slow: npx slow - ⏳ Pending
        odd: npx odd - ?
        claude.ai Gmail: https://example.com/gmail - ✔ Connected
        no status line
        """
        #expect(Kit.parseMcpList(text) == [
            "github": "connected", "slack": "failed", "broken": "failed", "crossed": "failed", "linear": "needs-auth",
            "slow": "pending", "odd": "unknown", "claude.ai Gmail": "connected",
        ])
    }

    @Test func wordsDropShortOnesStopWordsAndPlurals() {
        #expect(Kit.words("Use the PDFs and tests for my buses") == ["pdfs", "test", "buse"])
        #expect(Kit.words("docs") == ["docs"])
        #expect(Kit.words("an ox") == [])
    }

    @Test func aSkillIsPickedByNameOrTwoDescriptionWords() {
        let kit = Kit(servers: [], skills: [
            CommandInfo(name: "pdf", description: "Read and write PDF files"),
            CommandInfo(name: "deck", description: "Build slide presentations for meetings"),
        ])
        #expect(kit.matching("turn this into a pdf").skills == ["pdf"])
        #expect(kit.matching("prepare slide presentations").skills == ["deck"])
        #expect(kit.matching("prepare slide notes").skills == [])
    }

    @Test func everyPresetIsFoundByItsID() {
        for preset in FloorPreset.builtIn { #expect(FloorPreset.named(preset.id) == preset) }
        #expect(FloorPreset.named("nope") == nil)
        #expect(FloorPreset.match("it doesn't work at all")?.id == "bugfix")
    }
}
