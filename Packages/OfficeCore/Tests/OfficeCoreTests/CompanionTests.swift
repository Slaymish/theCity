import Foundation
import Testing
@testable import OfficeCore

struct CompanionTests {
    static let floor = UUID()
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Every snapshot the Mac would publish over a recorded run, one per stream line, each through JSON as it would travel.
    static func snapshots(_ fixture: String, resolving: Bool = false) throws -> [FloorSnapshot] {
        var reducer = OfficeReducer()
        var mirror = FloorMirror()
        var out: [FloorSnapshot] = []
        func take(_ events: [OfficeEvent]) throws {
            mirror.record(events)
            let snapshot = mirror.snapshot(id: floor, name: "Floor", hires: ["research"], request: "Write hello.txt",
                                           state: reducer.state, startedAt: start)
            let data = try CompanionCoding.encoder.encode(snapshot)
            out.append(try CompanionCoding.decoder.decode(FloorSnapshot.self, from: data))
        }
        try take(reducer.apply(.launched))
        for event in try Fixture.events(fixture) {
            try take(reducer.apply(.wire(event)))
            if resolving, case .permissionRequest(let request) = event {
                try take(reducer.apply(.requestResolved(requestID: request.requestID)))
            }
        }
        try take(reducer.apply(.processExited(code: 0, stderr: "")))
        return out
    }

    static func replayed(_ snapshots: [FloorSnapshot]) -> [OfficeEvent] {
        zip([nil] + snapshots.map(Optional.some), snapshots).flatMap { old, new in new.events(since: old) }
    }

    static func story(_ events: [OfficeEvent]) -> [OfficeEvent] {
        events.filter {
            switch $0 {
            case .handoff, .roomStarted, .roomFinished, .handback, .runStarted, .handRaised, .handLowered: true
            default: false
            }
        }
    }

    @Test func thePhoneRetellsTheOfficeStoryFromSnapshots() throws {
        var reducer = OfficeReducer()
        let live = reducer.runToExit(try Fixture.events("three-rooms.jsonl"))
        let phone = Self.replayed(try Self.snapshots("three-rooms.jsonl"))
        #expect(Self.story(phone) == Self.story(live))
        guard case .runEnded(.completed(let summary, _)) = phone.last else {
            Issue.record("run did not end completed: \(String(describing: phone.last))")
            return
        }
        #expect(summary?.contains("hello.txt") == true)
        #expect(phone.contains(.roomActivity(room: "research", toolName: "Read", step: "Reading README.md")))
    }

    @Test func aPhoneThatJoinsAfterTheJobSeesAnIdleOffice() throws {
        let last = try #require(try Self.snapshots("three-rooms.jsonl").last)
        #expect(last.events(since: nil).isEmpty)
    }

    @Test func aPhoneThatJoinsMidRunCatchesUpWithoutReplayingFinishedRooms() throws {
        let snapshots = try Self.snapshots("three-rooms.jsonl")
        let midway = try #require(snapshots.last { snapshot in
            snapshot.isRunning && snapshot.handoffs.contains { $0.handedBack } && snapshot.handoffs.contains { $0.phase == .working }
        })
        let events = midway.events(since: nil)
        #expect(events.first == .runStarted)
        let handedBack = Set(midway.handoffs.filter(\.handedBack).map(\.toolUseID))
        #expect(!events.contains { if case .handoff(let id, _, _) = $0 { handedBack.contains(id) } else { false } })
        #expect(events.contains { if case .roomStarted = $0 { true } else { false } })
    }

    @Test func questionsTravelWholeAndLowerWhenAnswered() throws {
        let snapshots = try Self.snapshots("ask-question.jsonl", resolving: true)
        let asked = try #require(snapshots.first { !$0.questions.isEmpty }?.questions.first)
        let questions = try #require(asked.questions)
        #expect(!questions.isEmpty)
        #expect(questions.allSatisfy { !$0.options.isEmpty })
        let events = Self.replayed(snapshots)
        #expect(events.contains { if case .handRaised(let request, _) = $0 { request.requestID == asked.requestID } else { false } })
        #expect(events.contains(.handLowered(requestID: asked.requestID, room: asked.room)))
    }

    @Test func approvalsCarryTheirSummary() throws {
        let asked = try #require(try Self.snapshots("approval-requests.jsonl").first { !$0.questions.isEmpty }?.questions.first)
        #expect(asked.questions == nil)
        #expect(asked.summary?.isEmpty == false)
        guard case .approval = asked.request.kind else {
            Issue.record("expected an approval")
            return
        }
    }

    @Test func aNewRunResetsTheOffice() throws {
        let last = try #require(try Self.snapshots("three-rooms.jsonl").last)
        var next = FloorSnapshot.empty(like: last)
        next.startedAt = Self.start.addingTimeInterval(60)
        #expect(next.events(since: last).first == .runStarted)
    }

    @Test func longTextIsClipped() {
        let long = String(repeating: "a", count: 5000)
        var mirror = FloorMirror()
        mirror.record([.roomCaption(room: "build", caption: long)])
        let snapshot = mirror.snapshot(id: Self.floor, name: "F", hires: [], request: long, state: OfficeState(), startedAt: nil)
        #expect(snapshot.captions["build"]?.count == Clip.caption)
        #expect(snapshot.request?.count == Clip.request)
    }
}

struct CommandGateTests {
    struct Signer: CommandSigner {
        var secret: UInt8 = 7
        func tag(for payload: Data) -> Data { Data(payload.map { $0 ^ secret }.prefix(16)) }
        func isValid(_ tag: Data, for payload: Data) -> Bool { tag == self.tag(for: payload) }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func sealed(at date: Date = now, id: UUID = UUID()) throws -> SealedCommand {
        try SealedCommand.seal(CompanionCommand(id: id, issuedAt: date, device: "Phone",
                                                action: .newJob(building: UUID(), request: "Tidy the README")), with: Signer())
    }

    @Test func aFreshSignedCommandIsAdmitted() throws {
        var gate = CommandGate()
        let result = gate.admit(try Self.sealed(), now: Self.now, signer: Signer())
        guard case .success(let command) = result else {
            Issue.record("rejected: \(result)")
            return
        }
        guard case .newJob(_, let request) = command.action else {
            Issue.record("wrong action")
            return
        }
        #expect(request == "Tidy the README")
    }

    @Test func aCommandSignedWithAnotherKeyIsRefused() throws {
        var gate = CommandGate()
        #expect(gate.admit(try Self.sealed(), now: Self.now, signer: Signer(secret: 9)) == .failure(.badSignature))
    }

    @Test func tamperingBreaksTheSignature() throws {
        var gate = CommandGate()
        var sealed = try Self.sealed()
        sealed.payload[sealed.payload.startIndex] ^= 1
        #expect(gate.admit(sealed, now: Self.now, signer: Signer()) == .failure(.badSignature))
    }

    @Test func oldCommandsExpire() throws {
        var gate = CommandGate()
        let old = try Self.sealed(at: Self.now.addingTimeInterval(-gate.lifetime - 1))
        #expect(gate.admit(old, now: Self.now, signer: Signer()) == .failure(.expired))
    }

    @Test func commandsFromTooFarAheadAreRefused() throws {
        var gate = CommandGate()
        let ahead = try Self.sealed(at: Self.now.addingTimeInterval(gate.skew + 5))
        #expect(gate.admit(ahead, now: Self.now, signer: Signer()) == .failure(.fromTheFuture))
    }

    @Test func aCommandRunsOnce() throws {
        var gate = CommandGate()
        let sealed = try Self.sealed()
        _ = gate.admit(sealed, now: Self.now, signer: Signer())
        #expect(gate.admit(sealed, now: Self.now.addingTimeInterval(1), signer: Signer()) == .failure(.replayed))
    }

    @Test func signedGarbageIsUnreadable() {
        var gate = CommandGate()
        let payload = Data("not json".utf8)
        let sealed = SealedCommand(payload: payload, tag: Signer().tag(for: payload))
        #expect(gate.admit(sealed, now: Self.now, signer: Signer()) == .failure(.unreadable))
    }

    @Test func everyActionRoundTrips() throws {
        let floor = UUID()
        let actions: [CompanionCommand.Action] = [
            .answer(floor: floor, requestID: "r1", answers: ["Which colour?": "Blue"]),
            .allow(floor: floor, requestID: "r2"), .deny(floor: floor, requestID: "r3"),
            .newJob(building: UUID(), request: "Hi"), .cancel(floor: floor),
        ]
        for action in actions {
            let command = CompanionCommand(issuedAt: Self.now, device: "Phone", action: action)
            let data = try CompanionCoding.encoder.encode(command)
            #expect(try CompanionCoding.decoder.decode(CompanionCommand.self, from: data) == command)
        }
    }
}

struct PairingTests {
    @Test func theCodeSurvivesItsURL() throws {
        let key = Data((0..<32).map { UInt8($0 * 7 % 256) })
        let code = PairingCode(hostID: UUID(), host: "Hamish's MacBook Pro", key: key)
        #expect(PairingCode(url: code.url) == code)
    }

    @Test func aShortKeyIsRefused() throws {
        let code = PairingCode(hostID: UUID(), host: "Mac", key: Data(repeating: 1, count: 16))
        #expect(PairingCode(url: code.url) == nil)
    }

    @Test func otherLinksAreRefused() throws {
        #expect(PairingCode(url: try #require(URL(string: "https://example.com/pair?id=x"))) == nil)
    }
}

struct LinkFramerTests {
    static let snapshot = CitySnapshot(host: "Mac", takenAt: Date(timeIntervalSince1970: 1_800_000_000), buildings: [
        BuildingSnapshot(id: UUID(), name: "theCity", title: "The City", style: 2, floors: [
            FloorSnapshot(id: UUID(), name: "Docs", hires: ["research"], request: "Tidy", phase: .running, startedAt: nil),
        ]),
    ])

    @Test func messagesSurviveBeingSplitAnywhere() throws {
        let messages: [LinkMessage] = [
            .hello(version: CitySnapshot.protocolVersion, device: "Phone"), .snapshot(Self.snapshot),
            .receipt(CommandReceipt(commandID: UUID(), outcome: .refused("Already answered on the Mac"))),
        ]
        let stream = try messages.reduce(Data()) { $0 + (try LinkFramer.frame($1)) }
        for chunk in [1, 3, 7, 64, stream.count] {
            var framer = LinkFramer()
            var received: [LinkMessage] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunk, stream.count)
                received += try framer.feed(stream.subdata(in: offset..<end))
                offset = end
            }
            #expect(received == messages)
        }
    }

    @Test func anAbsurdLengthClosesTheConnection() {
        var framer = LinkFramer()
        #expect(throws: LinkFramer.Failure.tooLong(0x7fff_ffff)) { try framer.feed(Data([0x7f, 0xff, 0xff, 0xff])) }
    }

    @Test func garbageClosesTheConnection() {
        var framer = LinkFramer()
        #expect(throws: LinkFramer.Failure.unreadable) { try framer.feed(Data([0, 0, 0, 2, 0x7b, 0x7b])) }
    }
}
