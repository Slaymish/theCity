import Foundation
import Testing
@testable import OfficeCore

struct ReducerTests {
    static let research = "toolu_01VwQhAryoNLmHpaRsYHAvPy"
    static let build = "toolu_01LMNZAGbhqqRyWz8fMJcK5N"
    static let review = "toolu_01Kkz9DkXbncAtCU9dMBujMB"

    @Test func threeRoomsProducesTheOfficeStory() throws {
        var reducer = OfficeReducer()
        let events = reducer.runToExit(try Fixture.events("three-rooms.jsonl")).withoutTally.withoutCaptions
        guard case .runEnded(.completed(let summary, let cost)) = events.dropLast().last else {
            Issue.record("run did not complete: \(String(describing: events.suffix(2)))")
            return
        }
        #expect(summary?.contains("hello.txt") == true)
        #expect(cost == 0.1394174)
        #expect(Array(events.dropLast(2)) == [
            .runStarted, .managerActive(true),
            .handoff(toolUseID: Self.research, room: "research", description: "Research greeting brief"),
            .roomStarted(toolUseID: Self.research, room: "research"), .managerActive(false),
            .roomActivity(room: "research", toolName: "Glob", step: "Finding **/*"),
            .roomActivity(room: "research", toolName: "Read", step: "Reading README.md"),
            .roomActivity(room: "research", toolName: "Read", step: "Reading .claude/agents/research.md"),
            .roomFinished(toolUseID: Self.research, room: "research", outcome: .completed), .managerActive(true),
            .handback(toolUseID: Self.research, room: "research", isError: false),
            .handoff(toolUseID: Self.build, room: "build", description: "Build hello.txt"),
            .roomStarted(toolUseID: Self.build, room: "build"), .managerActive(false),
            .roomActivity(room: "build", toolName: "Write", step: "Writing hello.txt"),
            .roomFinished(toolUseID: Self.build, room: "build", outcome: .completed), .managerActive(true),
            .handback(toolUseID: Self.build, room: "build", isError: false),
            .handoff(toolUseID: Self.review, room: "review", description: "Review hello.txt"),
            .roomStarted(toolUseID: Self.review, room: "review"), .managerActive(false),
            .roomActivity(room: "review", toolName: "Read", step: "Reading hello.txt"),
            .roomFinished(toolUseID: Self.review, room: "review", outcome: .completed), .managerActive(true),
            .handback(toolUseID: Self.review, room: "review", isError: false),
        ])
        #expect(events.last == .managerActive(false))
    }

    @Test func liveTallyCountsEachApiMessageOnce() throws {
        let wire = try Fixture.events("cancelled.jsonl")
        var reducer = OfficeReducer()
        _ = reducer.run(Array(wire.prefix(5)))
        guard case .assistant(let first) = wire[2] else { Issue.record("line 2 is not assistant"); return }
        #expect(reducer.state.tally.usage == first.usage)
        #expect(!reducer.state.tally.isFinal)
    }

    @Test func tallySnapsToResultTotals() throws {
        var reducer = OfficeReducer()
        _ = reducer.run(try Fixture.events("three-rooms.jsonl"))
        #expect(reducer.state.tally.isFinal)
        #expect(reducer.state.tally.usage.output == 1037 + 2529)
        #expect(reducer.state.tally.total == reducer.state.tally.usage.total)
    }

    @Test func notLoggedInFailsWithReason() throws {
        var reducer = OfficeReducer()
        let events = reducer.runToExit(try Fixture.events("not-logged-in.jsonl"), code: 1)
        #expect(events.contains(.runEnded(.failed(.notLoggedIn, message: "Not logged in · Please run /login"))))
    }

    @Test func cancelKillsTheRoomAndEndsCancelled() throws {
        let wire = try Fixture.events("cancelled.jsonl")
        let startedAt = try #require(wire.firstIndex { if case .taskStarted = $0 { true } else { false } })
        var reducer = OfficeReducer()
        var events = reducer.run(Array(wire[...startedAt]))
        events += reducer.apply(.cancelRequested)
        events += reducer.run(Array(wire[(startedAt + 1)...]))
        events += reducer.apply(.processExited(code: 0, stderr: ""))
        let story = events.withoutTally.withoutCaptions
        #expect(story.contains { if case .roomFinished(_, "research", .killed) = $0 { true } else { false } })
        #expect(story.contains { if case .runEnded(.cancelled) = $0 { true } else { false } })
        #expect(story.filter { if case .runEnded = $0 { true } else { false } }.count == 1)
    }

    @Test func malformedLinesDoNotBreakTheStory() throws {
        var clean = OfficeReducer()
        var noisy = OfficeReducer()
        #expect(noisy.runToExit(try Fixture.events("malformed.jsonl")) == clean.runToExit(try Fixture.events("three-rooms.jsonl")))
    }

    @Test func resultDoesNotEndTheRunUntilTheProcessExits() throws {
        var reducer = OfficeReducer()
        let events = reducer.run(try Fixture.events("three-rooms.jsonl"))
        #expect(!events.contains { if case .runEnded = $0 { true } else { false } })
        #expect(reducer.state.phase == .running)
    }

    @Test func backgroundRoomsStayLitUntilTheirTaskCompletes() throws {
        var reducer = OfficeReducer()
        let story = reducer.runToExit(try Fixture.events("haiku-manager.jsonl")).filter {
            switch $0 {
            case .handoff, .roomStarted, .roomFinished, .handback, .runEnded: true
            default: false
            }
        }
        let ids = ["toolu_01QUZTF2EDkwwQNkwoJRBXna", "toolu_01XabuT6tNQRC5EPfuCmkCCA", "toolu_01EuuQehyU8QfsP1GUEhYfHX"]
        var expected: [OfficeEvent] = []
        for (id, room) in zip(ids, ["research", "build", "review"]) {
            expected += [
                .roomStarted(toolUseID: id, room: room),
                .roomFinished(toolUseID: id, room: room, outcome: .completed),
                .handback(toolUseID: id, room: room, isError: false),
            ]
        }
        let withoutHandoffs = story.filter { if case .handoff = $0 { false } else { true } }
        #expect(Array(withoutHandoffs.dropLast()) == expected)
        guard case .runEnded(.completed(let summary, _)) = story.last else {
            Issue.record("run did not complete")
            return
        }
        #expect(summary?.hasPrefix("Workflow complete.") == true)
    }

    @Test func thinkingEstimatesCountUntilTheResult() throws {
        let wire = try Fixture.events("haiku-manager.jsonl")
        var reducer = OfficeReducer()
        _ = reducer.run(Array(wire.prefix(3)))
        #expect(reducer.state.tally.estimatedThinking == 100)
        #expect(reducer.state.tally.total == 100)
    }

    @Test func aLaterTurnMakesTheTallyLiveAgainOnTopOfTheResult() throws {
        let wire = try Fixture.events("haiku-manager.jsonl")
        let secondInit = try #require(wire.indices.dropFirst().first { if case .sessionStarted = wire[$0] { true } else { false } })
        let result = try #require(Fixture.events("three-rooms.jsonl").last)
        var reducer = OfficeReducer()
        _ = reducer.run(Array(wire[..<secondInit]) + [result])
        let settled = reducer.state.tally.usage
        #expect(reducer.state.tally.isFinal)
        _ = reducer.run(Array(wire[secondInit...].prefix(8)))
        #expect(!reducer.state.tally.isFinal)
        #expect(reducer.state.tally.usage.total > settled.total)
    }

    @Test func cancelWinsOverASuccessfulResult() throws {
        var reducer = OfficeReducer()
        _ = reducer.run(try Fixture.events("three-rooms.jsonl"))
        _ = reducer.apply(.cancelRequested)
        let events = reducer.apply(.processExited(code: 0, stderr: ""))
        #expect(events.contains(.runEnded(.cancelled(costUSD: 0.1394174))))
    }

    @Test func exitWithoutResultIsACrash() {
        var reducer = OfficeReducer()
        _ = reducer.apply(.launched)
        let events = reducer.apply(.processExited(code: 1, stderr: "boom\n"))
        #expect(events.contains(.runEnded(.failed(.processCrashed(code: 1), message: "boom"))))
    }

    @Test func handoffWithoutTaskStartedStaysRequestedAndIsClosedAtTheEnd() throws {
        let wire = try Fixture.events("three-rooms.jsonl")
        var reducer = OfficeReducer()
        _ = reducer.run(Array(wire.prefix(2)))
        #expect(reducer.state.handoffs[Self.research]?.phase == .requested)
        #expect(reducer.state.managerActive)
        let events = reducer.apply(.processExited(code: 1, stderr: ""))
        #expect(events.contains(.roomFinished(toolUseID: Self.research, room: "research", outcome: .killed)))
    }

    @Test func launchFailuresEndTheRun() {
        var reducer = OfficeReducer()
        #expect(reducer.apply(.launchFailed(.cliNotFound)).contains(.runEnded(.failed(.cliNotFound, message: nil))))
        #expect(reducer.apply(.launched).isEmpty)
    }
}
