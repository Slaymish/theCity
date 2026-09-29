import Foundation
import Testing
@testable import OfficeCore

/// Properties that must hold at every line of every recorded run, checked against sums worked out independently.
struct InvariantTests {
    static let runs = ["three-rooms.jsonl", "haiku-manager.jsonl", "cancelled.jsonl", "skill-and-mcp.jsonl", "approval-requests.jsonl",
                       "follow-up-resume.jsonl", "budget-exceeded.jsonl"]

    /// The tally is the latest `result`'s totals plus every API message since, each counted once, overall and per model.
    @Test(arguments: runs)
    func theTallyIsTheLastResultPlusFreshMessages(_ fixture: String) throws {
        var reducer = OfficeReducer()
        var baseline = TokenUsage.zero, baselineModels: [String: TokenUsage] = [:]
        var fresh: [String: TokenUsage] = [:], freshModel: [String: String] = [:]
        var turnsBaseline = 0
        var mainMessages: Set<String> = []
        var results = 0
        for event in try Fixture.events(fixture) {
            let wasFinal = reducer.state.tally.isFinal
            _ = reducer.apply(.wire(event))
            switch event {
            case .assistant(let message):
                if let id = message.messageID, message.parentToolUseID == nil { mainMessages.insert(id) }
                if let id = message.messageID, let usage = message.usage, !wasFinal {
                    fresh[id] = usage
                    if let model = message.model, model != "<synthetic>" { freshModel[id] = model }
                }
            case .result(let result):
                results += 1
                turnsBaseline += result.numTurns ?? mainMessages.count
                mainMessages = []
                if !result.modelUsage.isEmpty {
                    baseline = result.totalUsage
                    baselineModels = result.modelUsage.mapValues(\.usage)
                    fresh = [:]
                    freshModel = [:]
                }
                #expect(reducer.state.tally.isFinal)
                #expect(reducer.state.tally.costUSD == result.totalCostUSD)
                #expect(reducer.state.tally.estimatedThinking == 0)
            default:
                break
            }
            var models = baselineModels
            for (id, usage) in fresh { if let model = freshModel[id] { models[model, default: .zero] = models[model, default: .zero] + usage } }
            #expect(reducer.state.tally.usage == baseline + fresh.values.reduce(.zero, +), "\(fixture): \(event)")
            #expect(reducer.state.models.mapValues(\.usage) == models, "\(fixture): \(event)")
            #expect(reducer.state.turns == turnsBaseline + mainMessages.count, "\(fixture): \(event)")
        }
        #expect(results > 0)
    }

    @Test func turnsAfterASecondResultBuildOnTheFirst() throws {
        let wire = try Fixture.events("haiku-manager.jsonl")
        let results = wire.indices.filter { if case .result = wire[$0] { true } else { false } }
        #expect(results.count > 1)
        var reducer = OfficeReducer()
        _ = reducer.run(Array(wire[...results[1]]))
        let expected = results.prefix(2).compactMap { if case .result(let r) = wire[$0] { r.numTurns } else { nil } }.reduce(0, +)
        #expect(reducer.state.turns == expected)
    }

    @Test func aRoomFinishesOnItsHandBackEvenWithoutATaskUpdate() throws {
        let wire = try Fixture.events("three-rooms.jsonl").filter {
            switch $0 {
            case .taskUpdated, .taskNotification: false
            default: true
            }
        }
        var reducer = OfficeReducer()
        let finished = reducer.runToExit(wire).compactMap { if case .roomFinished(_, let room, let outcome) = $0 { "\(room) \(outcome)" } else { nil } }
        #expect(finished == ["research completed", "build completed", "review completed"])
    }

    @Test func serviceCallsInFlightEndWithTheRun() throws {
        let wire = try Fixture.events("skill-and-mcp.jsonl")
        var reducer = OfficeReducer()
        var open: [String] = []
        for event in wire {
            let events = reducer.apply(.wire(event))
            open += events.compactMap { if case .serviceCall(let id, _, _, true) = $0 { id } else { nil } }
            if !open.isEmpty { break }
        }
        let id = try #require(open.first)
        let ended = reducer.apply(.processExited(code: 1, stderr: ""))
        #expect(ended.contains { if case .serviceCall(id, _, _, false) = $0 { true } else { false } })
        #expect(reducer.apply(.processExited(code: 1, stderr: "")).isEmpty)
    }

    @Test func backgroundTaskCountFollowsTheStream() throws {
        var reducer = OfficeReducer()
        var seen: [Int] = []
        for event in try Fixture.events("haiku-manager.jsonl") {
            _ = reducer.apply(.wire(event))
            if case .backgroundTasksChanged(let count) = event { seen.append(count); #expect(reducer.state.backgroundTasks == count) }
        }
        #expect(seen.contains { $0 > 0 })
    }
}

struct ParserEdgeTests {
    static func event(_ raw: String) -> WireEvent? {
        if case .event(let event) = StreamParser.parse(raw) { event } else { nil }
    }

    @Test func whitespaceOnlyLinesAreEmptyNotBrokenJSON() {
        #expect(StreamParser.parse("   ") == .malformed(reason: "Empty line"))
        #expect(StreamParser.parse("\t\r") == .malformed(reason: "Empty line"))
        #expect(Self.event("\u{2028}{\"type\":\"x\"}") == .unknown(type: "x", subtype: nil))
        #expect(Self.event("{\"type\":\"x\"}\u{2028}") == .unknown(type: "x", subtype: nil))
    }

    @Test func missingFlagsDefaultToFalse() {
        guard case .taskStarted(let task) = Self.event(#"{"type":"system","subtype":"task_started","task_id":"t","tool_use_id":"u"}"#) else {
            Issue.record("not task_started")
            return
        }
        #expect(!task.isBackgrounded)
        guard case .result(let result) = Self.event(#"{"type":"result","subtype":"success","result":"ok"}"#) else {
            Issue.record("not result")
            return
        }
        #expect(!result.isError)
    }

    @Test func anAgentReportNeedsAnAgentTypeOrID() {
        func report(_ fields: String) -> AgentReport? {
            let raw = #"{"type":"user","message":{"role":"user","content":[]},"tool_use_result":{\#(fields)}}"#
            if case .user(let message) = Self.event(raw) { return message.agentReport }
            return nil
        }
        #expect(report(#""agentType":"research","status":"completed""#)?.agentType == "research")
        #expect(report(#""agentId":"a1","status":"async_launched""#)?.status == "async_launched")
        #expect(report(#""status":"completed""#) == nil)
    }

    @Test func onlyARejectedLimitIsRejected() {
        var limit = RateLimit(status: "rejected")
        #expect(limit.isRejected)
        limit.status = "allowed"
        #expect(!limit.isRejected)
        #expect(McpServer(name: "a", status: "connected", source: "project").source == "project")
    }

    @Test func transcriptTurnsKeepTheirReply() throws {
        #expect(SessionTranscript.Turn(date: .distantPast, prompt: "p", reply: "r").reply == "r")
        let since = try Date("2026-09-28T10:00:00Z", strategy: .iso8601)
        let lines = [
            #"{"type":"user","isSidechain":false,"isMeta":false,"message":{"role":"user","content":"On the dot"},"timestamp":"2026-09-28T10:00:00.000Z"}"#,
            #"{"type":"user","message":{"role":"user","content":"No fraction"},"timestamp":"2026-09-28T10:00:05Z"}"#,
        ]
        let turns = SessionTranscript.turns(in: Data(lines.joined(separator: "\n").utf8), since: since)
        #expect(turns.map(\.prompt) == ["On the dot", "No fraction"])
    }
}

#if os(macOS)
struct KitLoaderTests {
    @Test func theInventoryRunGetsItsHandshakeOnAnOpenInput() async throws {
        let cli = try CLICallTests.script(#"""
        [ "$MARK" = yes ] || exit 1
        case "$*" in *"--model office-inventory-no-such-model"*) ;; *) exit 1 ;; esac
        read -r first; read -r second
        printf '%s\n' "$first" "$second"
        """#)
        let lines = await KitLoader.inventoryLines(executable: cli, environment: ["MARK": "yes"], workingDirectory: FileManager.default.temporaryDirectory)
        #expect(lines.count == 2)
        #expect(lines.first?.contains(#""subtype":"initialize""#) == true)
        #expect(lines.last?.contains("inventory") == true)
    }

    @Test func mcpListRunsInTheProjectWithTheAccountsEnvironment() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cli = try CLICallTests.script(#"[ "$*" = "mcp list" ] && [ "$MARK" = yes ] && echo "here: $(pwd -P) - ✔ Connected""#)
        let text = await KitLoader.mcpList(executable: cli, environment: ["MARK": "yes"], workingDirectory: dir)
        let physical = try #require(realpath(dir.path, nil).map { String(cString: $0) })
        #expect(text == "here: \(physical) - ✔ Connected\n")
        #expect(await KitLoader.mcpList(executable: cli, environment: [:], workingDirectory: dir) == "")
    }
}
#endif
