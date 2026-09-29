import Foundation

/// Set while the app hosts its unit tests, which must never touch the user's city, settings, notifications or `claude`.
enum TestHost {
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static let defaultsSuite = "nz.hamish.thecity.tests"
}

extension UserDefaults {
    /// The app's settings; under tests, a scratch suite emptied at launch.
    nonisolated(unsafe) static let app: UserDefaults = {
        guard TestHost.isActive, let scratch = UserDefaults(suiteName: TestHost.defaultsSuite) else { return .standard }
        scratch.removePersistentDomain(forName: TestHost.defaultsSuite)
        return scratch
    }()
}
