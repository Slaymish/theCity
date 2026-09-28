import Foundation
import Testing
@testable import OfficeCore

struct KitTests {
    static func kit() throws -> Kit {
        let lines = try Fixture.rawLines("inventory.jsonl")
        let mcpList = try String(contentsOf: Fixture.url("mcp-list.txt"), encoding: .utf8)
        return Kit.from(lines: lines, mcpList: mcpList)
    }

    @Test func inventoryListsSkillsWithDescriptionsAndHealthCheckedServers() throws {
        let kit = try Self.kit()
        #expect(kit.skills.count == 54)
        #expect(kit.skills.first { $0.name == "office-house-style" }?.description.hasPrefix("The Office's house style") == true)
        #expect(kit.commands.count > kit.skills.count)
        let status = Dictionary(uniqueKeysWithValues: kit.servers.map { ($0.name, $0.status) })
        #expect(status["claude.ai Claude Docs"] == "connected")
        #expect(status["shadcn"] == "pending")
        #expect(status["plugin:chrome-devtools-mcp:chrome-devtools"] == "connected")
    }

    @Test func modelsComeFromTheCLIWithoutTheInventoryModel() throws {
        let kit = try Self.kit()
        #expect(kit.models.prefix(5).map(\.displayName) == ["Default (recommended)", "Opus 5.5", "Sonnet 5", "Fable 5.1", "Haiku 4.5"])
        #expect(!kit.models.contains { $0.value == KitLoader.inventoryModel })
    }

    @Test func commandsKeepTheirArgumentHints() throws {
        let kit = try Self.kit()
        #expect(kit.commands.first { $0.name == "grok" }?.argumentHint == "[branch | commit | PR# | feature or path]")
        #expect(kit.commands.first { $0.name == "office-house-style" }?.argumentHint == "")
    }

    @Test func slashCompletionListsPrefixMatchesFirstUntilASpace() {
        let commands = [CommandInfo(name: "review", description: ""), CommandInfo(name: "code-review", description: ""),
                        CommandInfo(name: "grok", description: ""), CommandInfo(name: "Revert", description: "")]
        #expect(SlashCommand.matches(for: "/rev", in: commands).map(\.name) == ["review", "Revert", "code-review"])
        #expect(SlashCommand.matches(for: "/", in: commands).count == 4)
        #expect(SlashCommand.matches(for: "/", in: commands, limit: 2).count == 2)
        #expect(SlashCommand.matches(for: "/review now", in: commands).isEmpty)
        #expect(SlashCommand.matches(for: "please /rev", in: commands).isEmpty)
        #expect(SlashCommand.matches(for: "/rev\n", in: commands).isEmpty)
    }

    @Test func slashTextSplitsIntoAKnownCommandAndArguments() {
        let commands = [CommandInfo(name: "grok", description: ""), CommandInfo(name: "alphero-web:add-tsdoc", description: "")]
        let parsed = SlashCommand.parse("  /grok  the parser change \n", commands: commands)
        #expect(parsed?.command.name == "grok")
        #expect(parsed?.arguments == "the parser change")
        #expect(SlashCommand.parse("/alphero-web:add-tsdoc", commands: commands)?.arguments == "")
        #expect(SlashCommand.parse("/gro", commands: commands) == nil)
        #expect(SlashCommand.parse("/ grok", commands: commands) == nil)
        #expect(SlashCommand.parse("grok it", commands: commands) == nil)
    }

    @Test func handBackPreambleIsStripped() throws {
        var reducer = OfficeReducer()
        _ = reducer.run(try Fixture.events("three-rooms.jsonl"))
        let report = try #require(reducer.state.handoffs(in: "research").first?.report)
        #expect(report.hasPrefix("## Brief"))
        #expect(!report.contains("Subagent hand-back"))
        #expect(!report.contains("agentId:"))
        #expect(!report.contains("<usage>"))
    }

    @Test func rateLimitStatusIsKept() throws {
        var reducer = OfficeReducer()
        _ = reducer.run(try Fixture.events("three-rooms.jsonl"))
        #expect(reducer.state.rateLimit?.status == "allowed")
        #expect(reducer.state.rateLimit?.resetsAt == Date(timeIntervalSince1970: 1790415600))
        #expect(reducer.state.rateLimit?.windows["seven_day"]?.utilization == 0.29)
        #expect(reducer.state.rateLimit?.windows["five_hour"]?.resetsAt == Date(timeIntervalSince1970: 1790415600))
    }

    @Test func toolPrefixesMatchTheCLIsOwnToolNames() throws {
        let tools = try #require({ () -> [String]? in
            for line in try Fixture.rawLines("three-rooms.jsonl") {
                if let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], json["subtype"] as? String == "init" {
                    return json["tools"] as? [String]
                }
            }
            return nil
        }())
        for server in ["claude.ai Claude Docs", "plugin:chrome-devtools-mcp:chrome-devtools", "specification-website"] {
            #expect(tools.contains { $0.hasPrefix(McpNaming.toolPrefix(forServer: server)) }, "no tools for \(server)")
        }
        #expect(McpNaming.friendly("mcp__claude_ai_Google_Drive__search_files", servers: ["claude.ai Google Drive"]) == "claude.ai Google Drive › search_files")
        #expect(McpNaming.split("Read", servers: []) == nil)
    }

    @Test func skillAndServiceUseAreTiedToRooms() throws {
        var reducer = OfficeReducer()
        let events = reducer.runToExit(try Fixture.events("skill-and-mcp.jsonl"))
        #expect(events.contains(.skillLoaded(room: "manager", skill: "office-house-style")))
        let calls = events.compactMap { if case .serviceCall(_, let room, let server, let active) = $0 { "\(room) \(server) \(active)" } else { nil } }
        #expect(calls == ["manager specification-website true", "manager specification-website false",
                          "general-purpose specification-website true", "general-purpose specification-website false"])
        #expect(reducer.state.serviceCallsByServer["specification-website"] == 2)
        let approvals = try ControlTests.requests("skill-and-mcp.jsonl").filter { $0.toolName.hasPrefix("mcp__") }
        #expect(approvals.first?.kind == .approval(summary: #"{"query":"favicon"}"#))
    }

    @Test func blockRulesCoverUntickedServersAndSkills() {
        let rules = Kit.blockRules(
            servers: [McpServer(name: "penpot", status: "connected", source: "user"), McpServer(name: "claude.ai Google Drive", status: "connected", source: "claudeai")],
            allowedServers: ["penpot"],
            skills: [CommandInfo(name: "office-house-style", description: ""), CommandInfo(name: "dataviz", description: "")],
            allowedSkills: ["office-house-style"]
        )
        #expect(rules == ["mcp__claude_ai_Google_Drive", "Skill(dataviz)"])
    }
}

struct KitLoaderLiveTests {
    /// Uses the real CLI when it's installed and logged in; costs nothing because the model name is invalid.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OFFICE_LIVE_TESTS"] == "1"))
    func loadsTheRealKit() async throws {
        let env = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: nil)
        let cli = try #require(ClaudeEnvironment.locateCLI(environment: env))
        let workspace = Fixture.directory.deletingLastPathComponent().appendingPathComponent("SampleWorkspace")
        let start = ContinuousClock.now
        let kit = await KitLoader.load(executable: cli, environment: env, workingDirectory: workspace)
        #expect(kit.skills.contains { $0.name == "office-house-style" })
        #expect(!kit.servers.isEmpty)
        print("kit: \(kit.skills.count) skills, \(kit.servers.count) servers (\(kit.usableServers.count) connected) in \(ContinuousClock.now - start)")
    }
}

struct KitMatchTests {
    let kit = Kit(servers: [McpServer(name: "penpot", status: "connected", source: nil), McpServer(name: "figma", status: "failed", source: nil)],
                  skills: [CommandInfo(name: "chrome-devtools-mcp:memory-leak-debugging", description: "Diagnoses and resolves memory leaks in JavaScript applications"),
                           CommandInfo(name: "dataviz", description: "Use whenever you are about to create any chart or graph"),
                           CommandInfo(name: "readme-media", description: "Create, refresh or polish the README GIFs and app icon")])

    @Test func namesAndDescriptionsPickSkillsAndServers() {
        #expect(kit.matching("Fix the memory leak in the city scene") == ([], ["chrome-devtools-mcp:memory-leak-debugging"]))
        #expect(kit.matching("Refresh the README GIFs") == ([], ["readme-media"]))
        #expect(kit.matching("Tidy the Penpot board") == (["penpot"], []))
    }

    @Test func oneSharedDescriptionWordIsNotEnough() {
        #expect(kit.matching("Create a new floor preset") == ([], []))
    }

    @Test func serversThatAreNotConnectedAreNeverPicked() {
        #expect(kit.matching("Pull the Figma frame") == ([], []))
    }
}
