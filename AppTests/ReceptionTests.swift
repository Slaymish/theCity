import Foundation
import Testing
import OfficeCore
@testable import TheCity

@MainActor
struct ReceptionTests {
    static func floor(_ name: String, hires: [String] = [], purpose: String? = nil, preset: String? = nil, last: String? = nil) -> CityStore.Floor {
        CityStore.Floor(name: name, hires: hires, budgetUSD: 1, lastRequest: last, presetID: preset, purpose: purpose)
    }

    @Test func atNameRoutesToTheLongestMatchingFloor() throws {
        let floors = [Self.floor("Login"), Self.floor("Login Page"), Self.floor("Docs")]
        let (floor, rest) = try #require(ReceptionDesk.directFloor(in: "@login page  make the button blue", floors: floors))
        #expect(floor.name == "Login Page")
        #expect(rest == "make the button blue")
        #expect(ReceptionDesk.directFloor(in: "@DOCS", floors: floors)?.1 == "")
        #expect(ReceptionDesk.directFloor(in: "login page fix", floors: floors) == nil)
        #expect(ReceptionDesk.directFloor(in: "@nobody here", floors: floors) == nil)
    }

    @Test func aSlashCommandRoutesOnItsArgumentsOrItsName() {
        let commands = [CommandInfo(name: "review", description: "Review a PR"), CommandInfo(name: "plugin:security-review", description: "")]
        #expect(ReceptionDesk.topic(of: "/review the login change", commands: commands) == "the login change")
        #expect(ReceptionDesk.topic(of: "/plugin:security-review", commands: commands) == "security review")
        #expect(ReceptionDesk.topic(of: "/unknown thing", commands: commands) == "/unknown thing")
        #expect(ReceptionDesk.topic(of: "plain request", commands: commands) == "plain request")
    }

    @Test func newFloorNamesComeFromTheRequestAndNeverRepeat() {
        #expect(CityStore.floorName(for: "fix the login page button colour please", existing: []) == "Fix the login page button")
        #expect(CityStore.floorName(for: "  ", existing: []) == "New floor")
        #expect(CityStore.floorName(for: "docs", existing: ["Docs", "Docs 2"]) == "Docs 3")
        #expect(CityStore.floorName(for: String(repeating: "a", count: 60), existing: []).count == 40)
    }

    @Test func proposedNamesMustBeShortSpecificAndNew() {
        let floors = [Self.floor("Payments")]
        #expect(ReceptionDesk.usableName(" slide decks. ", floors: floors) == "Slide decks")
        #expect(ReceptionDesk.usableName("payments", floors: floors) == nil)
        #expect(ReceptionDesk.usableName("Team", floors: floors) == nil)
        #expect(ReceptionDesk.usableName("new floor", floors: floors) == nil)
        #expect(ReceptionDesk.usableName("", floors: floors) == nil)
        #expect(ReceptionDesk.usableName("one two three four five", floors: floors) == nil)
        #expect(ReceptionDesk.usableName("one two three four", floors: floors) == "One two three four")
    }

    @Test func meaningfulWordsDropStopWordsAndShortOnes() {
        #expect(ReceptionDesk.words("Please fix the Login page for iOS 26 and add it") == ["login", "page", "ios"])
    }

    @Test func theModelsPickNeedsASharedWordOrAMatchingPreset() {
        let docs = Self.floor("Docs", purpose: "Writes the README")
        #expect(ReceptionDesk.supports(docs, request: "Update the README badges", preset: nil))
        #expect(!ReceptionDesk.supports(docs, request: "Speed up the database", preset: nil))
        let security = Self.floor("Audit", preset: "security")
        #expect(ReceptionDesk.supports(security, request: "anything", preset: FloorPreset.named("security")))
    }

    @Test func floorsFromBeforePresetsAreMatchedByNameAndPurpose() {
        #expect(ReceptionDesk.presetOf(Self.floor("Security Review"))?.id == "security")
        #expect(ReceptionDesk.presetOf(Self.floor("Anything", preset: "docs"))?.id == "docs")
        #expect(ReceptionDesk.presetOf(Self.floor("Payments")) == nil)
    }

    @Test func closestFloorByProposedNameOrTwoSharedWords() {
        let floors = [Self.floor("Payments", last: "refund stripe invoices"), Self.floor("Login Page")]
        #expect(ReceptionDesk.closest(to: "x", proposed: "Payments work", in: floors)?.name == "Payments")
        #expect(ReceptionDesk.closest(to: "handle stripe refund webhooks", proposed: "", in: floors)?.name == "Payments")
        #expect(ReceptionDesk.closest(to: "handle stripe webhooks", proposed: "", in: floors) == nil)
    }

    @Test func aPresetsStandingFloorTakesTheWork() {
        let security = Self.floor("Security Review", preset: "security")
        let preset = FloorPreset.named("security")
        let standing = ReceptionDesk.newFloor(for: "audit the auth code", preset: preset, proposed: "", floors: [security], reason: "r")
        #expect(standing.floorID == security.id)

        let fresh = ReceptionDesk.newFloor(for: "audit the auth code", preset: preset, proposed: "Auth Audit", floors: [], reason: "Because.")
        #expect(fresh.floorID == nil)
        #expect(fresh.presetID == "security")
        #expect(fresh.newFloorName == "Security Review")
        #expect(fresh.reason == "Because. It suits a Security Review team: security-reviewer.")

        let plain = ReceptionDesk.newFloor(for: "speed up the database", preset: nil, proposed: "Performance", floors: [], reason: "r")
        #expect(plain == RoutingSuggestion(floorID: nil, newFloorName: "Performance", reason: "r"))
        let vague = ReceptionDesk.newFloor(for: "speed up the database", preset: nil, proposed: "Team", floors: [], reason: "r")
        #expect(vague.newFloorName == "Speed up the database")
    }

    @Test func aLongPresetFloorOnlyTakesRelatedWork() {
        let feature = Self.floor("Exports", preset: "feature", last: "implement the export endpoint")
        let preset = FloorPreset.named("feature")
        #expect(ReceptionDesk.newFloor(for: "build the export feature", preset: preset, proposed: "", floors: [feature], reason: "r").floorID == feature.id)
        let other = ReceptionDesk.newFloor(for: "build a billing feature", preset: preset, proposed: "Billing", floors: [feature], reason: "r")
        #expect(other.floorID == nil)
        #expect(other.newFloorName == "Billing")
    }

    @Test func withNoFloorsReceptionAlwaysProposesANewOne() async {
        let suggestion = await ReceptionDesk.route(request: "fix a typo in the readme", floors: [])
        #expect(suggestion.floorID == nil)
        #expect(suggestion.presetID == "quickfix")
        #expect(suggestion.newFloorName == "Quick Fix")
    }
}

struct HiringTests {
    static let catalogue = [
        Department(name: "researcher", description: "Finds out how things work"),
        Department(name: "builder", description: "Writes and changes code"),
        Department(name: "tester", description: "Runs the tests"),
    ]

    @Test func reasonsThatRestateTheDescriptionAreDropped() {
        #expect(HiringDesk.repeats("Writes and changes the code", "Writes and changes code"))
        #expect(!HiringDesk.repeats("Needs the login form rebuilt", "Writes and changes code"))
        #expect(HiringDesk.repeats("", "anything"))
        #expect(HiringDesk.repeats("to do it", "anything"))
    }

    @Test func aPresetHiresItsTeamInOrderAndKeepsTheRestOffered() throws {
        let preset = try #require(FloorPreset.named("bugfix"))
        let outcome = HiringDesk.staff(.unavailable("no model", []), with: preset, catalogue: Self.catalogue)
        guard case .proposed(let candidates, let kit) = outcome else { Issue.record("not proposed"); return }
        #expect(candidates.map(\.id) == ["builder", "tester", "researcher"])
        #expect(candidates.map(\.hired) == [true, true, false])
        #expect(candidates.first?.reason == "Part of the Bug Fix team")
        #expect(kit == nil)
    }

    @Test func aPresetWithNoneOfItsRolesHereChangesNothing() throws {
        let preset = try #require(FloorPreset.named("security"))
        let outcome = HiringDesk.staff(.unavailable("no model", []), with: preset, catalogue: Self.catalogue)
        guard case .unavailable(let note, _) = outcome else { Issue.record("should be unchanged"); return }
        #expect(note == "no model")
    }
}

extension WithFakeCLI {
    /// Reception on Claude runs the whole route with a scripted Haiku answer, so the checks on the model's pick are tested end to end.
    @Suite
    @MainActor
    struct RoutingTests {
        static let floors = [
            ReceptionTests.floor("Payments", last: "refund stripe invoices"),
            ReceptionTests.floor("Docs", purpose: "Writes the README"),
        ]

        func route(_ request: String, reply: String?) async throws -> RoutingSuggestion {
            let fake = try FakeCLI()
            if let reply { fake.haiku("routing", replies: reply) }
            let before = Preferences.shared.receptionist
            Preferences.shared.receptionist = .claude
            defer { Preferences.shared.receptionist = before }
            return await ReceptionDesk.route(request: request, floors: Self.floors)
        }

        @Test func theModelsFloorIsTakenWhenTheRequestFitsIt() async throws {
            let suggestion = try await route("add stripe refunds to invoices", reply: #"{"floor":"payments","newFloorName":""}"#)
            #expect(suggestion.floorID == Self.floors[0].id)
            #expect(suggestion.reason.hasPrefix("Payments looks like the right team."))
        }

        @Test func anUnrelatedPickIsOverruled() async throws {
            let suggestion = try await route("speed up the database", reply: #"{"floor":"Docs","newFloorName":"Performance"}"#)
            #expect(suggestion.floorID == nil)
            #expect(suggestion.newFloorName == "Performance")
        }

        @Test func aProposedNameMatchingAFloorSendsItThere() async throws {
            let suggestion = try await route("update the readme badges", reply: #"{"floor":"","newFloorName":"Docs"}"#)
            #expect(suggestion.floorID == Self.floors[1].id)
        }

        @Test func noAnswerFallsBackToANewFloor() async throws {
            let suggestion = try await route("speed up the database", reply: nil)
            #expect(suggestion.floorID == nil)
            #expect(suggestion.reason.contains("couldn’t reach Claude"))
            #expect(suggestion.newFloorName == "Speed up the database")
        }
    }
}
