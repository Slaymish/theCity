import Foundation
import Testing
@testable import OfficeCore

struct ParserTests {
    @Test func everyRealLineParses() throws {
        for name in ["three-rooms.jsonl", "not-logged-in.jsonl", "cancelled.jsonl", "haiku-manager.jsonl", "ask-question.jsonl", "approval-requests.jsonl", "always-allow.jsonl", "follow-up-resume.jsonl", "budget-exceeded.jsonl", "skill-and-mcp.jsonl", "inventory.jsonl"] {
            for raw in try Fixture.rawLines(name) {
                guard case .event(let event) = StreamParser.parse(raw) else {
                    Issue.record("\(name): malformed line \(raw.prefix(80))")
                    continue
                }
                if case .unknown(let type, let subtype) = event {
                    Issue.record("\(name): unmodelled \(type)/\(subtype ?? "-")")
                }
            }
        }
    }

    @Test func subagentStartCarriesTheSpawningToolUseID() throws {
        let events = try Fixture.events("three-rooms.jsonl")
        guard case .assistant(let spawn) = events[1],
              case .toolUse(let id, "Agent", "research", _, _) = spawn.blocks.first else {
            Issue.record("line 1 is not the research handoff")
            return
        }
        guard case .taskStarted(let started) = events[2] else {
            Issue.record("line 2 is not task_started")
            return
        }
        #expect(started.toolUseID == id)
        #expect(started.subagentType == "research")
        guard case .assistant(let inner) = events[6] else { Issue.record("line 6 is not assistant"); return }
        #expect(inner.parentToolUseID == id)
    }

    @Test func notLoggedInIsAnErrorDespiteSuccessSubtype() throws {
        let events = try Fixture.events("not-logged-in.jsonl")
        guard case .result(let result) = events.last else { Issue.record("no result"); return }
        #expect(result.subtype == "success")
        #expect(result.isError)
        guard case .assistant(let message) = events[1] else { Issue.record("no assistant"); return }
        #expect(message.error == "authentication_failed")
    }

    @Test func resultTotalsIncludeSubagentModels() throws {
        let events = try Fixture.events("three-rooms.jsonl")
        guard case .result(let result) = events.last else { Issue.record("no result"); return }
        #expect(Set(result.modelUsage.keys) == ["claude-sonnet-5", "claude-haiku-4-5-20251001"])
        #expect(result.totalUsage.output == 1037 + 2529)
        #expect(result.totalCostUSD == 0.1394174)
    }

    @Test func malformedLinesAreReportedNotDropped() throws {
        let parsed = try Fixture.rawLines("malformed.jsonl").map(StreamParser.parse)
        let reasons = parsed.compactMap { if case .malformed(let reason) = $0 { reason } else { nil } }
        #expect(reasons == ["Not JSON", "Not JSON", "Not a JSON object", "Missing \"type\"", "Empty line"])
        #expect(parsed.contains(.event(.unknown(type: "system", subtype: "brand_new_event"))))
    }
}
