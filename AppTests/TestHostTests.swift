import Foundation
import Testing
import OfficeCore
@testable import TheCity

/// Guards the guard: if these fail, the other suites would be running against the user's real city and settings.
@MainActor
struct TestHostTests {
    @Test func theHostKnowsItIsUnderTest() {
        #expect(TestHost.isActive)
    }

    @Test func dataAndSettingsAreScratch() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(!DataFiles.directory.path.hasPrefix(support.path))
        #expect(DataFiles.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(UserDefaults.app !== UserDefaults.standard)
    }
}

extension WithFakeCLI {
    @Suite
    @MainActor
    struct NoRealCLITests {
        @Test func withNoCLIChosenTheRealOneIsNeverFound() {
            let chosen = Preferences.shared.cliPath
            defer { Preferences.shared.cliPath = chosen }
            Preferences.shared.cliPath = nil
            let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: nil)
            let found = RunController.executable(environment: environment)
            #expect(found?.path == "/nonexistent/claude")
            #expect(found.map { !FileManager.default.isExecutableFile(atPath: $0.path) } == true)
        }
    }
}
