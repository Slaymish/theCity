import Foundation
import Testing
import OfficeCore
@testable import TheCity

/// Suites that run real jobs through the fake `claude`. They share `Preferences.cliPath`, so they run one at a time.
@Suite(.serialized)
@MainActor
struct WithFakeCLI {}

extension WithFakeCLI {
    @Suite
    @MainActor
    struct JobFlowTests {
        static let firstSession = "7e3ba2bb-10c0-4853-a62b-c6d8a0ddd7bd"
        static let followUpSession = "d6dac005-4b6b-499e-8fdf-d9d11e4997c9"

        static func cost(of fixture: String) throws -> Double {
            let last = try #require(try Repo.fixture("\(fixture).jsonl").split(separator: "\n").last)
            let json = try #require(try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
            return try #require(json["total_cost_usd"] as? Double)
        }

        @Test func aJobRunsToTheEndAndEverythingIsRecorded() async throws {
            let fake = try FakeCLI()
            let floor = try TestFloor(request: "Write hello.txt with a one-line greeting.")
            floor.city.route = .city
            #expect(await floor.finished())

            guard case .completed(let summary, let cost) = floor.session.state.phase.outcome else {
                Issue.record("job did not complete: \(String(describing: floor.session.state.phase))")
                return
            }
            #expect(summary?.contains("hello.txt") == true)
            #expect(cost == 0.1394174)
            #expect(floor.session.steps.map(\.status) == [.done, .done, .done])

            let arguments = try #require(fake.jobArguments.first)
            #expect(fake.jobArguments.count == 1)
            #expect(arguments.contains("--max-budget-usd 5.0"))
            #expect(arguments.contains("--append-system-prompt Hired\\ subagents"))
            #expect(!arguments.contains("--agents"), "SampleWorkspace's departments are project files, so none travel as built-ins")
            #expect(!arguments.contains("--resume"))

            let record = try #require(floor.records.first)
            #expect(floor.records.count == 1)
            #expect(record.outcome == "completed")
            #expect(record.costUSD == 0.1394174)
            #expect(record.sessionID == Self.firstSession)
            #expect(record.buildingID == floor.building.id)
            #expect(record.workingDirectory == floor.building.path)
            #expect(Set(record.hires) == ["research", "build", "review"])
            #expect(record.request == "Write hello.txt with a one-line greeting.")

            let saved = try #require(floor.floor)
            #expect(saved.sessionID == Self.firstSession)
            #expect(saved.lastOutcome == "completed")
            #expect(saved.lastRequest == "Write hello.txt with a one-line greeting.")
            await eventually("the job's folder to be saved") { floor.floor?.jobDirectory != nil }
            #expect(floor.floor?.jobDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == floor.building.url.resolvingSymlinksInPath())

            let totals = try #require(floor.city.totals[floor.floorID])
            #expect(totals.jobs == 1)
            #expect(totals.succeeded == 1)
            #expect(totals.spendUSD == 0.1394174)

            #expect(floor.session.history.map(\.kind) == [.request, .outcome])
            #expect(floor.session.history.last?.title == "Delivered")
            #expect(FloorHistory.load(floor.floorID) == floor.session.history)

            let onDisk = try #require(DataFiles.load([CityStore.Building].self, from: CityStore.fileURL))
            #expect(onDisk.first { $0.id == floor.building.id }?.floors.first?.sessionID == Self.firstSession)
            #expect(JobJournal.load().contains(record))
        }

        @Test func aFinishedJobNeedsYouUntilYouLookAtIt() async throws {
            _ = try FakeCLI()
            let floor = try TestFloor(request: "Write hello.txt")
            floor.city.route = .city
            #expect(await floor.finished())
            await eventually("the floor to be marked unseen") { floor.floor?.unseen == true }
            #expect(floor.floor?.unseenSince != nil)
            #expect(floor.city.floorsNeedingYou().first { $0.floor.id == floor.floorID }?.since == floor.floor?.unseenSince)
            #expect(floor.city.needsYou(try #require(floor.floor)) == 1)
            #expect(floor.city.statusLine(for: try #require(floor.city.building(floor.building.id))) == "Needs you")
            floor.city.route = .floor(building: floor.building.id, floor: floor.floorID)
            #expect(floor.floor?.unseen == nil && floor.floor?.unseenSince == nil)
            #expect(floor.city.needsYou(try #require(floor.floor)) == 0)
        }

        @Test func aFollowUpResumesTheSessionAndAddsToTheSameJob() async throws {
            let fake = try FakeCLI()
            let floor = try TestFloor(request: "Write hello.txt")
            #expect(await floor.finished())
            #expect(floor.session.canContinue)

            floor.session.followUp("Now make it friendlier. fixture:follow-up-resume")
            #expect(await eventually("the follow-up to start") { fake.jobs.count == 2 })
            #expect(await floor.finished())

            #expect(fake.jobArguments.last?.contains("--resume \(Self.firstSession)") == true)
            let record = try #require(floor.records.first)
            #expect(floor.records.count == 1)
            #expect(abs((record.costUSD ?? 0) - (0.1394174 + (try Self.cost(of: "follow-up-resume")))) < 1e-9)
            #expect(record.sessionID == Self.followUpSession)
            #expect(floor.floor?.sessionID == Self.followUpSession)
            #expect(floor.city.totals[floor.floorID]?.jobs == 1)
            #expect(floor.session.history.map(\.kind) == [.request, .outcome, .followUp, .outcome])
            #expect(floor.session.followUps == ["Now make it friendlier. fixture:follow-up-resume"])
        }

        @Test func requestsWhileBusyQueueAndRunInTurn() async throws {
            let fake = try FakeCLI()
            fake.hold()
            let floor = try TestFloor(request: "first")
            #expect(await eventually("the first job to start") { floor.session.isRunning && floor.session.state.sessionID != nil })

            floor.city.send("second", toFloor: floor.floorID, in: floor.building.id, navigate: false)
            #expect(floor.session.queued == [QueuedJob(text: "second", continues: false, place: nil)])
            #expect(floor.floor?.queued == [QueuedJob(text: "second", continues: false, place: nil)])
            #expect(fake.jobs.count == 1)

            fake.unhold()
            fake.release()
            #expect(await eventually("the queued job to run") { fake.jobs.count == 2 })
            #expect(await floor.finished())
            #expect(floor.session.request == "second")
            #expect(floor.session.queued.isEmpty)
            #expect(floor.floor?.queued == nil)
            #expect(floor.records.map(\.request) == ["first", "second"])
            #expect(floor.city.totals[floor.floorID]?.jobs == 2)
        }

        @Test func aJobThatFailsHoldsTheQueueUntilResumed() async throws {
            let fake = try FakeCLI()
            fake.hold()
            let floor = try TestFloor(request: "Spend it all. fixture:budget-exceeded")
            #expect(await eventually("the job to start") { floor.session.isRunning && floor.session.state.sessionID != nil })
            floor.session.queue("next")

            fake.unhold()
            fake.release()
            #expect(await floor.finished())
            guard case .failed(.budgetExhausted, _) = floor.session.state.phase.outcome else {
                Issue.record("expected a budget failure, got \(String(describing: floor.session.state.phase))")
                return
            }
            #expect(floor.session.history.last?.title == "Budget reached")
            #expect(floor.records.last?.outcome == "failed")
            #expect(floor.city.totals[floor.floorID]?.succeeded == 0)
            #expect(floor.session.queueHeld)
            await stays("the queue held", for: 1.5) { fake.jobs.count == 1 }

            floor.session.resumeQueue()
            #expect(await eventually("the held job to run") { fake.jobs.count == 2 })
            #expect(await floor.finished())
            #expect(!floor.session.queueHeld)
        }

        @Test func cancellingEndsTheJobCancelledAndHoldsTheQueue() async throws {
            let fake = try FakeCLI()
            fake.hold()
            let floor = try TestFloor(request: "first")
            #expect(await eventually("the job to start") { floor.session.isRunning && floor.session.state.sessionID != nil })
            floor.session.queue("next")

            floor.session.cancel()
            #expect(await floor.finished())
            guard case .cancelled = floor.session.state.phase.outcome else {
                Issue.record("expected a cancel, got \(String(describing: floor.session.state.phase))")
                return
            }
            #expect(floor.records.last?.outcome == "cancelled")
            #expect(floor.floor?.lastOutcome == "cancelled")
            #expect(floor.floor?.unseen == nil)
            let totals = try #require(floor.city.totals[floor.floorID])
            #expect(totals.cancelled == 1)
            #expect(totals.successRate == nil)
            #expect(floor.session.history.last?.title == "Cancelled")
            #expect(floor.session.queueHeld)
            await stays("the queue held", for: 1.5) { fake.jobs.count == 1 }
            floor.session.discardQueue()
            #expect(floor.floor?.queued == nil)
        }

        @Test func aSavedQueueStartsHeldAfterARelaunchAndCanContinueTheSession() async throws {
            let fake = try FakeCLI()
            let floor = try TestFloor(request: "first")
            #expect(await floor.finished())
            var saved = try #require(floor.floor)
            saved.queued = [QueuedJob(text: "carry on", continues: true, place: nil)]

            let relaunched = RunController(building: floor.building, floor: saved)
            #expect(relaunched.queueHeld)
            #expect(relaunched.queued == saved.queued)
            #expect(relaunched.canContinue)
            await stays("the restored queue held", for: 1.5) { fake.jobs.count == 1 }

            relaunched.resumeQueue()
            #expect(await eventually("the restored job to run") { fake.jobs.count == 2 })
            #expect(fake.jobArguments.last?.contains("--resume \(Self.firstSession)") == true)
        }

        @Test func aSignedOutAccountFailsBeforeAnyJobRuns() async throws {
            let fake = try FakeCLI()
            fake.signOut()
            let floor = try TestFloor(request: "first")
            #expect(await floor.finished())
            #expect(floor.session.state.phase.outcome == .failed(.notLoggedIn, message: nil))
            #expect(fake.jobs.isEmpty)
            #expect(floor.session.readiness == .notLoggedIn)
            #expect(floor.session.isAccountFailure)
        }

        @Test func aMissingCliFailsAndSaysSo() async throws {
            Preferences.shared.cliPath = "/nonexistent/claude"
            let floor = try TestFloor(request: "first")
            #expect(await floor.finished())
            #expect(floor.session.state.phase.outcome == .failed(.cliNotFound, message: nil))
            #expect(floor.session.readiness == .cliMissing)
            #expect(floor.session.history.last?.text == RunController.message(for: .failed(.cliNotFound, message: nil), budget: 5))
        }

        @Test func aFollowUpWhoseFolderIsGoneFailsWithAReason() async throws {
            let fake = try FakeCLI()
            let floor = try TestFloor(request: "first")
            #expect(await floor.finished())
            try FileManager.default.removeItem(at: floor.building.url)

            floor.session.followUp("more")
            #expect(await floor.finished())
            guard case .failed(.couldNotStart, let message) = floor.session.state.phase.outcome else {
                Issue.record("expected couldNotStart, got \(String(describing: floor.session.state.phase))")
                return
            }
            #expect(message?.contains("is gone") == true)
            #expect(fake.jobs.count == 1)
        }

        @Test func receptionSendsAnAtNameStraightToThatFloor() async throws {
            let fake = try FakeCLI()
            let floor = try TestFloor(request: "first", name: "Payments")
            #expect(await floor.finished())
            #expect(floor.floor?.name == "Payments")

            #expect(floor.city.askReception("@payments   refund flow", in: floor.building.id))
            #expect(await eventually("the second job to run") { fake.jobs.count == 2 })
            #expect(await floor.finished())
            #expect(floor.floor?.lastRequest == "refund flow")
        }

        @Test func haikuNamesTheProjectAndTheFloor() async throws {
            let fake = try FakeCLI()
            fake.haiku("project", replies: "“Sample Greeter.”\nIt greets people.")
            fake.haiku("label", replies: "Greeting Copy")
            let floor = try TestFloor(request: "Write hello.txt")
            #expect(await eventually("the building's title") { floor.city.building(floor.building.id)?.title == "Sample Greeter" })
            #expect(await eventually("the floor's label") { floor.floor?.name == "Greeting Copy" })
            #expect(await floor.finished())

            floor.city.renameFloor(floor.floorID, in: floor.building.id, to: "Mine")
            #expect(floor.floor?.name == "Mine")
            #expect(floor.floor?.nameIsCustom == true)
        }

        @Test func removingAFloorForgetsItsHistory() async throws {
            _ = try FakeCLI()
            let floor = try TestFloor(request: "first")
            #expect(await floor.finished())
            #expect(!FloorHistory.load(floor.floorID).isEmpty)
            floor.city.removeFloor(floor.floorID, in: floor.building.id)
            #expect(floor.floor == nil)
            #expect(FloorHistory.load(floor.floorID).isEmpty)
            #expect(floor.city.sessions[floor.floorID] == nil)
        }
    }
}
