import Foundation
import Testing
@testable import TheCity

struct FloorSignalTests {
    private func signal(pending: Int = 0, unseen: Bool = false, outcome: String? = nil, running: Bool = false, queued: Int = 0) -> FloorSignal {
        .of(pending: pending, unseen: unseen, outcome: outcome, running: running, queued: queued)
    }

    @Test func aBlockedRobotOutranksEverythingElse() {
        #expect(signal(pending: 1, unseen: true, outcome: "failed", running: true, queued: 2) == .blocked)
    }

    @Test func anUnseenResultIsFailedOrReadyByOutcome() {
        #expect(signal(unseen: true, outcome: "failed") == .failed)
        #expect(signal(unseen: true, outcome: "completed") == .ready)
        #expect(signal(unseen: true, outcome: nil) == .ready)
    }

    @Test func aSeenFailureIsNoLongerFailed() {
        #expect(signal(unseen: false, outcome: "failed") == .quiet)
    }

    @Test func runningBeatsQueuedBeatsQuiet() {
        #expect(signal(running: true, queued: 1) == .working)
        #expect(signal(queued: 1) == .queued)
        #expect(signal() == .quiet)
    }

    @Test func onlyBlockedFailedAndReadyNeedAPerson() {
        #expect(FloorSignal.allCases.filter(\.needsAPerson) == [.blocked, .failed, .ready])
    }

    @Test func urgencySortsBlockedFirst() {
        #expect([FloorSignal.ready, .blocked, .failed].sorted() == [.blocked, .failed, .ready])
    }

    @Test func labelsCountOnlyBlocked() {
        #expect(FloorSignal.blocked.label(count: 3) == "3 waiting")
        #expect(FloorSignal.blocked.label() == "Waiting")
        #expect(FloorSignal.ready.label(count: 3) == "Ready")
    }
}
