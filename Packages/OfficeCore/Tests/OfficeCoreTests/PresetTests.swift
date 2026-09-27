import Testing
@testable import OfficeCore

struct PresetTests {
    @Test func everyRoleIsABuiltInDepartment() {
        let names = Set(AgentCatalogue.builtIn.map(\.name))
        for preset in FloorPreset.builtIn {
            #expect(preset.roles.allSatisfy(names.contains), "\(preset.id) hires a role that isn't built in")
        }
    }

    @Test(arguments: [
        ("Review the auth code for vulnerabilities", "security"),
        ("The app crashes when I open settings", "bugfix"),
        ("Build a settings screen with a dark mode toggle", "frontend"),
        ("Review my changes before I merge", "review"),
        ("Implement an endpoint for exporting invoices", "feature"),
        ("Fix the typo in the header", "quickfix"),
        ("Update the README and changelog", "docs"),
        ("Compare three options for caching and recommend one", "research"),
    ])
    func requestsMatchTheirPreset(request: String, preset: String) {
        #expect(FloorPreset.match(request)?.id == preset)
    }

    @Test func vagueRequestsMatchNothing() {
        #expect(FloorPreset.match("Sort out the thing we talked about") == nil)
    }

    @Test func reviewerCanNoLongerRunCommands() {
        #expect(AgentCatalogue.builtIn.first { $0.name == "reviewer" }?.tools?.contains("Bash") == false)
    }
}
