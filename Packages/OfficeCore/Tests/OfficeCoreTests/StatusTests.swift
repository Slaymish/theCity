import Foundation
import Testing
@testable import OfficeCore

struct StatusTests {
    @Test func parserReadsResultFigures() throws {
        let result = try #require(try Fixture.events("three-rooms.jsonl").compactMap { if case .result(let r) = $0 { r } else { nil } }.first)
        #expect(result.modelUsage["claude-sonnet-5"]?.costUSD == 0.0987512)
        #expect(result.modelUsage["claude-haiku-4-5-20251001"]?.contextWindow == 200_000)
        #expect(result.subagentStats == SubagentStats(spawned: 3, completed: 3, failed: 0, killed: 0))
        #expect(result.permissionDenials == 0)
        let denied = try #require(try Fixture.events("approval-requests.jsonl").compactMap { if case .result(let r) = $0 { r } else { nil } }.first)
        #expect(denied.permissionDenials == 1)
    }

    @Test func handoffKeepsModelTokensToolsAndOutcome() throws {
        var reducer = OfficeReducer()
        _ = reducer.runToExit(try Fixture.events("three-rooms.jsonl"))
        let research = try #require(reducer.state.handoffs[ReducerTests.research])
        #expect(research.model == "claude-haiku-4-5-20251001")
        #expect(research.tokens == 7676)
        #expect(research.toolCallCount == 3)
        #expect(research.outcome == .completed)
        #expect(research.step == nil)
    }

    @Test func stepFollowsProgressWhileWorking() throws {
        let wire = try Fixture.events("three-rooms.jsonl")
        let second = try #require(wire.indices.filter { if case .taskProgress = wire[$0] { true } else { false } }.dropFirst().first)
        var reducer = OfficeReducer()
        _ = reducer.run(Array(wire[...second]))
        let research = try #require(reducer.state.handoffs[ReducerTests.research])
        #expect(research.step == "Reading README.md")
        #expect(research.tokens == 6859)
        #expect(research.toolUses == 2)
        #expect(reducer.state.roomCounts(staff: ["research", "build", "review"]) == RoomCounts(working: 1, idle: 3))
    }

    @Test func runFiguresSnapToTheResult() throws {
        var reducer = OfficeReducer()
        _ = reducer.run(try Fixture.events("three-rooms.jsonl"))
        let state = reducer.state
        #expect(state.turns == 4)
        #expect(state.models["claude-haiku-4-5-20251001"]?.costUSD == 0.0406662)
        #expect(state.models.values.map(\.usage).reduce(.zero, +) == state.tally.usage)
        #expect(state.mainModel == "claude-sonnet-5")
        #expect(state.contextWindows["claude-sonnet-5"] == 1_000_000)
        let fraction = try #require(state.contextFraction())
        #expect(fraction > 0 && fraction < 0.1)
        #expect(state.subagentStats?.spawned == 3)
    }

    @Test func liveTurnsAndModelsCountMessagesOnce() throws {
        let wire = try Fixture.events("three-rooms.jsonl")
        let result = try #require(wire.firstIndex { if case .result = $0 { true } else { false } })
        var reducer = OfficeReducer()
        _ = reducer.run(Array(wire[..<result]))
        #expect(reducer.state.turns == 4)
        #expect(reducer.state.models.values.allSatisfy { $0.costUSD == nil })
        #expect(reducer.state.models.values.map(\.usage).reduce(.zero, +) == reducer.state.tally.usage)
        #expect(reducer.state.contextFraction() == nil)
        #expect(reducer.state.contextFraction(windows: ["claude-sonnet-5": 1_000_000]) != nil)
    }

    @Test func turnsAddUpAcrossResults() throws {
        var reducer = OfficeReducer()
        _ = reducer.runToExit(try Fixture.events("haiku-manager.jsonl"))
        #expect(reducer.state.turns == 7)
    }

    @Test func deniedRequestsAreCounted() throws {
        var reducer = OfficeReducer()
        _ = reducer.runToExit(try Fixture.events("approval-requests.jsonl"))
        #expect(reducer.state.permissionDenials == 1)
    }

    @Test func cancelledRoomIsKilled() throws {
        let wire = try Fixture.events("cancelled.jsonl")
        let startedAt = try #require(wire.firstIndex { if case .taskStarted = $0 { true } else { false } })
        var reducer = OfficeReducer()
        _ = reducer.run(Array(wire[...startedAt]))
        _ = reducer.apply(.cancelRequested)
        _ = reducer.apply(.processExited(code: 0, stderr: ""))
        #expect(reducer.state.handoffs.values.contains { $0.outcome == .killed })
        #expect(reducer.state.roomCounts(staff: []).working == 0)
    }

    @Test func waitingRoomsAreCountedOnce() throws {
        let wire = try Fixture.events("approval-requests.jsonl")
        let asked = try #require(wire.firstIndex { if case .permissionRequest = $0 { true } else { false } })
        var reducer = OfficeReducer()
        _ = reducer.run(Array(wire[...asked]))
        let counts = reducer.state.roomCounts(staff: ["build"])
        #expect(counts.waiting == 1)
        #expect(counts.working == 0)
        #expect(counts.working + counts.idle + counts.waiting == Set(["manager", "build"] + reducer.state.handoffs.values.map(\.room)).count)
    }

    @Test func modelNamesReadNaturally() {
        #expect(ModelName.display("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(ModelName.display("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelName.display("claude-opus-4-1") == "Opus 4.1")
        #expect(ModelName.display("claude-sonnet-5") == "Sonnet 5")
        #expect(ModelName.display("claude-opus-4-6[1m]") == "Opus 4.6")
    }
}
