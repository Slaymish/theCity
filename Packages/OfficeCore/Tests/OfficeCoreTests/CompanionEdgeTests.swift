import Foundation
import Testing
@testable import OfficeCore

/// The companion's boundaries and bookkeeping, which the recorded runs pass through without pinning.
struct CompanionEdgeTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let floor = UUID()

    static func snapshot(phase: FloorSnapshot.Phase = .running, startedAt: Date? = now, managerActive: Bool = false,
                         handoffs: [HandoffSnapshot] = [], captions: [String: String] = [:], skills: [String: [String]] = [:],
                         calls: [ServiceCallSnapshot] = [], tokens: Int = 0, cost: Double? = nil) -> FloorSnapshot {
        FloorSnapshot(id: floor, name: "F", hires: ["build"], request: "r", phase: phase, startedAt: startedAt, managerActive: managerActive,
                      handoffs: handoffs, captions: captions, skills: skills, serviceCalls: calls, tokens: tokens, costUSD: cost)
    }

    static func handoff(_ id: String = "t1", phase: Handoff.Phase = .working, step: String? = nil, tool: String? = nil) -> HandoffSnapshot {
        HandoffSnapshot(toolUseID: id, room: "build", brief: "b", phase: phase, step: step, lastTool: tool, outcome: nil, handedBack: false)
    }

    @Test func snapshotsKeepEveryFieldTheyAreGiven() throws {
        let building = BuildingSnapshot(id: UUID(), name: "theCity", title: "The City", style: 2, floors: [])
        #expect(building.displayName == "The City")
        #expect(BuildingSnapshot(id: UUID(), name: "theCity", title: nil, style: 0, floors: []).displayName == "theCity")
        let floor = Self.snapshot(tokens: 12, cost: 0.5)
        #expect(floor.startedAt == Self.now)
        #expect(floor.costUSD == 0.5)
        #expect(floor.tokens == 12)
        let question = QuestionSnapshot(requestID: "r", room: "build", toolName: "Bash", questions: [], summary: "ls")
        #expect(question.questions == [])
        #expect(question.summary == "ls")
    }

    @Test func approvalsBecomeSummariesAndQuestionsStayWhole() {
        let approval = QuestionSnapshot(PendingRequest(request: PermissionRequest(requestID: "a", toolName: "Bash", kind: .approval(summary: "rm -rf build")), room: "build"))
        #expect(approval.summary == "rm -rf build")
        #expect(approval.questions == nil)
        let asked = [AskedQuestion(question: "Colour?", header: "C", options: [], multiSelect: false)]
        let question = QuestionSnapshot(PendingRequest(request: PermissionRequest(requestID: "q", toolName: "AskUserQuestion", kind: .question(asked)), room: "manager"))
        #expect(question.questions == asked)
        #expect(question.summary == nil)
    }

    @Test func clippingStopsExactlyAtTheLimit() {
        #expect(Clip.text("abc", to: 3) == "abc")
        #expect(Clip.text("abcd", to: 3) == "ab…")
    }

    @Test func roomsWaitingOnYouCountOnceEvenWhileWorking() {
        var floor = Self.snapshot(managerActive: true, handoffs: [Self.handoff()])
        floor.questions = [QuestionSnapshot(requestID: "r", room: "build", toolName: "Bash", questions: nil, summary: "ls")]
        #expect(floor.roomCounts == RoomCounts(working: 1, idle: 0, waiting: 1))
        let city = CitySnapshot(host: "Mac", takenAt: Self.now, buildings: [
            BuildingSnapshot(id: UUID(), name: "a", title: nil, style: 0, floors: [floor, floor]),
        ])
        #expect(city.waitingCount == 2)
        #expect(city.buildings[0].workingCount == 2)
    }

    @Test func aCommandExactlyAtItsLimitsIsStillAdmitted() throws {
        var gate = CommandGate(lifetime: 60, skew: 10)
        let signer = CommandGateTests.Signer()
        let oldest = try CommandGateTests.sealed(at: Self.now.addingTimeInterval(-60))
        #expect(gate.admit(oldest, now: Self.now, signer: signer).isSuccess)
        let newest = try CommandGateTests.sealed(at: Self.now.addingTimeInterval(10))
        #expect(gate.admit(newest, now: Self.now, signer: signer).isSuccess)
    }

    @Test func theGateForgetsCommandsOnlyOnceTheyWouldExpireAnyway() throws {
        var gate = CommandGate(lifetime: 60, skew: 10)
        let signer = CommandGateTests.Signer()
        let id = UUID()
        let first = try CommandGateTests.sealed(at: Self.now, id: id)
        #expect(gate.admit(first, now: Self.now, signer: signer).isSuccess)
        let again = try CommandGateTests.sealed(at: Self.now.addingTimeInterval(55), id: id)
        #expect(gate.admit(again, now: Self.now.addingTimeInterval(70), signer: signer) == .failure(.replayed))
    }

    @Test func commandsAreSignedOverSortedKeys() throws {
        let command = CompanionCommand(id: UUID(), issuedAt: Self.now, device: "Phone", action: .cancel(floor: Self.floor))
        let text = String(decoding: try CompanionCoding.encoder.encode(command), as: UTF8.self)
        let keys = ["action", "device", "id", "issuedAt"].map { text.range(of: "\"\($0)\"")!.lowerBound }
        #expect(keys == keys.sorted())
    }

    @Test func aMessageAtTheMaximumLengthIsWaitedForNotRefused() throws {
        var framer = LinkFramer()
        let length = UInt32(LinkFramer.maximumLength).bigEndian
        #expect(try framer.feed(withUnsafeBytes(of: length) { Data($0) }) == [])
        var over = LinkFramer()
        let tooLong = UInt32(LinkFramer.maximumLength + 1).bigEndian
        #expect(throws: LinkFramer.Failure.tooLong(LinkFramer.maximumLength + 1)) { try over.feed(withUnsafeBytes(of: tooLong) { Data($0) }) }
    }

    @Test func aNewRunClearsTheMirror() {
        var mirror = FloorMirror()
        mirror.record([.roomCaption(room: "build", caption: "Reading"), .roomActivity(room: "build", toolName: "Read", step: nil),
                       .serviceCall(callID: "c", room: "build", server: "github", active: true)])
        #expect(!mirror.captions.isEmpty && !mirror.lastTools.isEmpty && !mirror.serviceCalls.isEmpty)
        mirror.record([.runStarted])
        #expect(mirror.captions.isEmpty && mirror.lastTools.isEmpty && mirror.serviceCalls.isEmpty)
    }

    @Test func serviceCallsEndOneAtATimeAndAllAtTheEndOfTheRun() {
        var mirror = FloorMirror()
        mirror.record([.serviceCall(callID: "a", room: "build", server: "github", active: true),
                       .serviceCall(callID: "b", room: "build", server: "slack", active: true),
                       .serviceCall(callID: "a", room: "build", server: "github", active: true)])
        #expect(mirror.serviceCalls.map(\.callID) == ["b", "a"])
        mirror.record([.serviceCall(callID: "b", room: "build", server: "slack", active: false)])
        #expect(mirror.serviceCalls.map(\.callID) == ["a"])
        mirror.record([.runEnded(.cancelled(costUSD: nil))])
        #expect(mirror.serviceCalls.isEmpty)
    }

    @Test func aRoomsLastToolFallsBackToItsRecordedTools() throws {
        var reducer = OfficeReducer()
        _ = reducer.run(try Fixture.events("three-rooms.jsonl"))
        let snapshot = FloorMirror().snapshot(id: Self.floor, name: "F", hires: [], request: nil, state: reducer.state, startedAt: nil)
        let research = try #require(snapshot.handoffs.first { $0.room == "research" })
        #expect(research.lastTool == reducer.state.handoffs(in: "research").last?.tools.last?.name)
        #expect(snapshot.handoffs.map(\.toolUseID) == snapshot.handoffs.map(\.toolUseID).sorted())
    }

    @Test func aNewStepOnAWorkingRoomIsShown() {
        let old = Self.snapshot(handoffs: [Self.handoff(step: "Reading a")])
        let same = old.events(since: old)
        #expect(!same.contains { if case .roomActivity = $0 { true } else { false } })
        let next = Self.snapshot(handoffs: [Self.handoff(step: "Reading b", tool: "Read")])
        #expect(next.events(since: old).contains(.roomActivity(room: "build", toolName: "Read", step: "Reading b")))
    }

    @Test func captionsSkillsAndServiceCallsAreDiffed() {
        let old = Self.snapshot(captions: ["build": "a"], skills: ["build": ["pdf"]], calls: [ServiceCallSnapshot(callID: "x", room: "build", server: "github")])
        let new = Self.snapshot(captions: ["build": "b", "manager": "m"], skills: ["build": ["pdf", "docx"]],
                                calls: [ServiceCallSnapshot(callID: "y", room: "build", server: "slack")])
        let events = new.events(since: old)
        #expect(events.filter { if case .roomCaption = $0 { true } else { false } } == [
            .roomCaption(room: "build", caption: "b"), .roomCaption(room: "manager", caption: "m"),
        ])
        #expect(events.filter { if case .skillLoaded = $0 { true } else { false } } == [.skillLoaded(room: "build", skill: "docx")])
        #expect(events.filter { if case .serviceCall = $0 { true } else { false } } == [
            .serviceCall(callID: "x", room: "build", server: "github", active: false),
            .serviceCall(callID: "y", room: "build", server: "slack", active: true),
        ])
        #expect(!events.contains(.runStarted))
    }

    @Test func tallyAndManagerChangesAreSentOnlyWhenTheyChange() {
        let old = Self.snapshot(tokens: 10, cost: 0.1)
        #expect(old.events(since: old).isEmpty)
        let more = Self.snapshot(managerActive: true, tokens: 20, cost: 0.1)
        let events = more.events(since: old)
        guard case .tallyChanged(let tally) = events.first(where: { if case .tallyChanged = $0 { true } else { false } }) else {
            Issue.record("no tally")
            return
        }
        #expect(tally.usage.output == 20 && tally.costUSD == 0.1 && !tally.isFinal)
        #expect(events.contains(.managerActive(true)))
        #expect(Self.snapshot(tokens: 10, cost: 0.2).events(since: old).contains { if case .tallyChanged = $0 { true } else { false } })
        let done = Self.snapshot(phase: .completed(summary: nil), tokens: 20, cost: 0.1)
        guard case .tallyChanged(let final) = done.events(since: old).first(where: { if case .tallyChanged = $0 { true } else { false } }) else {
            Issue.record("no final tally")
            return
        }
        #expect(final.isFinal)
    }

    @Test func runStartsOnlyForANewRunOrAResumedOne() {
        let idle = Self.snapshot(phase: .completed(summary: nil))
        let resumed = Self.snapshot(phase: .running)
        #expect(resumed.events(since: idle).first == .runStarted)
        let stillRunning = Self.snapshot(phase: .running)
        #expect(!stillRunning.events(since: resumed).contains(.runStarted))
        let finishing = Self.snapshot(phase: .cancelled)
        #expect(!finishing.events(since: resumed).contains(.runStarted))
        #expect(finishing.events(since: resumed).last == .runEnded(.cancelled(costUSD: nil)))
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
