import Foundation
import Testing
@testable import OfficeCore

struct ProjectPathTests {
    @Test func stripsTheProjectDirectory() {
        #expect(ProjectPath.relative("/Users/me/app/Sources/main.swift", to: URL(fileURLWithPath: "/Users/me/app")) == "Sources/main.swift")
    }

    @Test func leavesPathsOutsideTheProjectAlone() {
        #expect(ProjectPath.relative("/Users/me/other/main.swift", to: URL(fileURLWithPath: "/Users/me/app")) == "/Users/me/other/main.swift")
        #expect(ProjectPath.relative("/Users/me/application/main.swift", to: URL(fileURLWithPath: "/Users/me/app")) == "/Users/me/application/main.swift")
        #expect(ProjectPath.relative("/Users/me/app/main.swift", to: nil) == "/Users/me/app/main.swift")
    }

    @Test func matchesPrivateTmpAgainstTmp() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ProjectPathTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = directory.lastPathComponent
        #expect(ProjectPath.relative("/private/tmp/\(name)/notes.md", to: directory) == "notes.md")
        #expect(ProjectPath.relative("/tmp/\(name)/notes.md", to: URL(fileURLWithPath: "/private/tmp/\(name)")) == "notes.md")
        #expect(ProjectPath.relative("/private/tmp/\(name)/notes.md", to: directory.standardizedFileURL) == "notes.md")
    }

    @Test func matchesMissingPrivateTmpPaths() {
        #expect(ProjectPath.relative("/private/tmp/no-such-project/gone.swift", to: URL(fileURLWithPath: "/tmp/no-such-project")) == "gone.swift")
    }
}
