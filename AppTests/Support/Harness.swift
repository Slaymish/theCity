import Foundation
import Testing
import OfficeCore
@testable import TheCity

enum Repo {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = root.appendingPathComponent("fixtures")

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    }
}

enum Scratch {
    static func folder(_ name: String = "scratch") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TheCityTests-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    /// A copy of SampleWorkspace, so a job's files land somewhere disposable.
    static func workspace() throws -> URL {
        let url = folder("workspace").appendingPathComponent("Sample")
        try FileManager.default.copyItem(at: Repo.root.appendingPathComponent("SampleWorkspace"), to: url)
        return url
    }
}

/// The `claude` the app runs under test: `AppTests/Support/fake-claude`, copied somewhere of its own.
@MainActor
final class FakeCLI {
    let directory: URL
    let executable: URL

    init() throws {
        directory = Scratch.folder("cli")
        executable = directory.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: Repo.root.appendingPathComponent("AppTests/Support/fake-claude"), to: executable)
        try Repo.fixtures.path.write(to: directory.appendingPathComponent("fixtures-path"), atomically: true, encoding: .utf8)
        Preferences.shared.cliPath = executable.path
    }

    var calls: [String] {
        ((try? String(contentsOf: directory.appendingPathComponent("claude.calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// The fixture each job replayed, in order.
    var jobs: [String] { calls.filter { $0.hasPrefix("request ") }.map { String($0.dropFirst("request ".count)) } }

    /// The argument lines of the jobs themselves, not the version, sign-in, inventory or Haiku calls.
    var jobArguments: [String] {
        calls.filter { $0.hasPrefix("-p --input-format") && !$0.contains("office-inventory-no-such-model") }
    }

    func hold() { flag("hold", true) }
    func release() { flag("release", true) }
    func unhold() { flag("hold", false) }
    func signOut() { flag("logged-out", true) }

    func haiku(_ kind: String, replies text: String) {
        try? text.write(to: directory.appendingPathComponent("haiku-\(kind)"), atomically: true, encoding: .utf8)
    }

    private func flag(_ name: String, _ on: Bool) {
        let url = directory.appendingPathComponent(name)
        if on { FileManager.default.createFile(atPath: url.path, contents: Data()) } else { try? FileManager.default.removeItem(at: url) }
    }
}

/// Waits for something the app does asynchronously, failing the test if it never happens.
@MainActor
@discardableResult
func eventually(_ what: String, within seconds: Double = 15, sourceLocation: SourceLocation = #_sourceLocation,
                _ condition: () -> Bool) async -> Bool {
    let deadline = Date.now.addingTimeInterval(seconds)
    while !condition() {
        guard Date.now < deadline else {
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
            return false
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

/// Holds for a while and checks something never happens, for things that must not start on their own.
@MainActor
func stays(_ what: String, for seconds: Double, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    let deadline = Date.now.addingTimeInterval(seconds)
    while Date.now < deadline {
        guard condition() else {
            Issue.record("Expected \(what) to hold", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

extension OfficeState.Phase {
    var outcome: RunOutcome? { if case .ended(let outcome) = self { outcome } else { nil } }
}

/// A building on a fresh copy of SampleWorkspace, with a floor opened the way "Pick the team yourself" does, which starts its first job.
@MainActor
struct TestFloor {
    let city = CityStore.shared
    let building: CityStore.Building
    let floorID: UUID
    let session: RunController

    init(request: String, hires: [String] = ["research", "build", "review"], name: String? = nil) throws {
        building = city.addBuilding(at: try Scratch.workspace())
        let session = RunController(building: building, floor: nil)
        session.pendingFloorName = name
        session.request = request
        session.pickTeamYourself()
        for candidate in session.candidates where hires.contains(candidate.id) { session.toggle(candidate) }
        session.openOffice()
        self.session = session
        floorID = try #require(session.floorID)
    }

    var floor: CityStore.Floor? { city.floor(floorID, in: building.id) }

    var records: [JobRecord] { city.journal.filter { $0.floorID == floorID } }

    func finished() async -> Bool {
        await eventually("the job to end") { !session.isRunning && session.state.phase.outcome != nil }
    }
}
