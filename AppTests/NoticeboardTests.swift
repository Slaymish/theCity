import Foundation
import Testing
@testable import TheCity

@MainActor
struct NoticeboardTests {
    @Test func aResearchWorkspaceNeedsNoGitRepository() async throws {
        let folder = Scratch.folder("research-board")
        try "# Competitor analysis\nA research brief.".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "Company,Price\nExample,10".write(to: folder.appendingPathComponent("competitors.csv"), atomically: true, encoding: .utf8)
        let snapshot = await WorkspaceSnapshot.read(at: folder)
        #expect(snapshot.available)
        #expect(snapshot.branch == nil && snapshot.head == nil && snapshot.changes == nil)
        #expect(snapshot.brief.contains("A research brief."))
        #expect(Set(snapshot.documents.map { $0.url.lastPathComponent }) == ["README.md", "competitors.csv"])
    }

    @Test func aMissingWorkspaceIsReportedAsUnavailable() async {
        let snapshot = await WorkspaceSnapshot.read(at: URL(fileURLWithPath: "/tmp/missing-city-workspace-\(UUID())"))
        #expect(!snapshot.available)
        #expect(snapshot.documents.isEmpty)
    }

    @Test func pinnedSitesRequireWebAddresses() {
        #expect(ProjectNoticeboard.webURL("https://example.com/product") != nil)
        #expect(ProjectNoticeboard.webURL("file:///tmp/private.txt") == nil)
        #expect(ProjectNoticeboard.webURL("example.com") == nil)
    }
}
