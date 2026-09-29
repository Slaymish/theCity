import Foundation
import Testing
@testable import OfficeCore

/// What the app promises the `claude` CLI: the flags it passes, the JSON it hands over and how it reads the answers.
struct ContractTests {
    static let base = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--permission-mode", "manual", "--permission-prompt-tool", "stdio"]

    @Test func aPlainJobPassesOnlyTheStreamingFlags() {
        let config = RunConfig(request: "hi", workingDirectory: URL(fileURLWithPath: "/tmp"), claudeConfigDirectory: nil, model: nil, maxBudgetUSD: nil)
        #expect(config.arguments == Self.base)
    }

    @Test func everySettingBecomesItsFlag() {
        let config = RunConfig(request: "hi", workingDirectory: URL(fileURLWithPath: "/tmp"), claudeConfigDirectory: URL(fileURLWithPath: "/cfg"),
                               model: "sonnet", maxBudgetUSD: 2.5, appendSystemPrompt: "brief", agents: #"{"a":{}}"#, resumeSessionID: "sid",
                               blockedTools: ["mcp__github", "Skill(pdf)"], permissionMode: .auto, worktreeName: "wt")
        #expect(config.arguments == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "auto", "--permission-prompt-tool", "stdio",
            "--worktree", "wt", "--resume", "sid", "--disallowedTools", "mcp__github,Skill(pdf)", "--model", "sonnet",
            "--append-system-prompt", "brief", "--agents", #"{"a":{}}"#, "--max-budget-usd", "2.5",
        ])
        #expect(config.claudeConfigDirectory?.path == "/cfg")
        #expect(!config.arguments.contains("/cfg"))
    }

    @Test(arguments: PermissionMode.allCases)
    func permissionModesAreTheCLIsOwnNames(_ mode: PermissionMode) {
        let config = RunConfig(request: "", workingDirectory: URL(fileURLWithPath: "/tmp"), claudeConfigDirectory: nil, model: nil,
                               maxBudgetUSD: nil, permissionMode: mode)
        let flag = config.arguments.firstIndex(of: "--permission-mode")!
        #expect(config.arguments[flag + 1] == ["auto": "auto", "acceptEdits": "acceptEdits", "manual": "manual", "plan": "plan"][mode.rawValue])
    }

    @Test func builtInDepartmentsTravelAsAgentsJSON() throws {
        let tester = try #require(AgentCatalogue.builtIn.first { $0.name == "tester" })
        let writer = try #require(AgentCatalogue.builtIn.first { $0.name == "writer" })
        let projectOwn = Department(name: "research", description: "From .claude/agents")
        let json = try #require(AgentCatalogue.agentsJSON(for: [projectOwn, tester, writer]))
        let agents = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]])
        #expect(Set(agents.keys) == ["tester", "writer"])
        #expect(agents["tester"]?["description"] as? String == tester.description)
        #expect(agents["tester"]?["prompt"] as? String == tester.prompt)
        #expect(agents["tester"]?["tools"] == nil)
        #expect(agents["writer"]?["tools"] as? [String] == writer.tools)
        #expect(AgentCatalogue.agentsJSON(for: [projectOwn]) == nil)
        #expect(AgentCatalogue.agentsJSON(for: []) == nil)
    }

    @Test func frontmatterQuotesAreStrippedOnlyInMatchingPairs() {
        #expect(AgentCatalogue.parse("---\nname: \"a\"\n---")?.name == "a")
        #expect(AgentCatalogue.parse("---\nname: 'b'\n---")?.name == "b")
        #expect(AgentCatalogue.parse("---\nname: \"c'\n---")?.name == "\"c'")
        #expect(AgentCatalogue.parse("---\nname: x\ndescription: \"\"\n---")?.description == "")
        #expect(AgentCatalogue.parse("---\nname: \"\n---")?.name == "\"")
    }

    @Test func versionsNeedAtLeastMajorAndMinor() {
        #expect(ClaudeEnvironment.parseVersion("2.1 (Claude Code)") == [2, 1])
        #expect(ClaudeEnvironment.parseVersion("2 (Claude Code)") == nil)
        #expect(ClaudeEnvironment.parseVersion("2.x.1") == nil)
    }
}

#if os(macOS)
struct CLICallTests {
    /// A script that answers only when called exactly as the app calls the real CLI.
    static func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n\(body)\n".utf8), attributes: [.posixPermissions: 0o755])
        return url
    }

    @Test func versionAsksWithTheFlagAndTheEnvironment() async throws {
        let strict = try Self.script(#"[ "$*" = "--version" ] && [ "$MARK" = yes ] && echo '2.1.300 (Claude Code)'"#)
        #expect(await ClaudeEnvironment.version(executable: strict, environment: ["MARK": "yes"]) == [2, 1, 300])
        #expect(await ClaudeEnvironment.version(executable: strict, environment: [:]) == nil)
    }

    @Test func signInStatusComesFromAuthStatus() async throws {
        let cli = try Self.script(#"[ "$*" = "auth status" ] && [ "$MARK" = yes ] && echo "{\"loggedIn\": $STATE}""#)
        #expect(await ClaudeEnvironment.isLoggedIn(executable: cli, environment: ["MARK": "yes", "STATE": "true"]) == true)
        #expect(await ClaudeEnvironment.isLoggedIn(executable: cli, environment: ["MARK": "yes", "STATE": "false"]) == false)
        #expect(await ClaudeEnvironment.isLoggedIn(executable: cli, environment: ["STATE": "true"]) == nil)
        let silent = try Self.script("exit 0")
        #expect(await ClaudeEnvironment.isLoggedIn(executable: silent, environment: [:]) == nil)
    }

    @Test func theFirstCLIOnThePathWins() throws {
        let first = try Self.script("true"), second = try Self.script("true")
        let path = [first, second].map { $0.deletingLastPathComponent().path }.joined(separator: ":")
        #expect(ClaudeEnvironment.locateCLI(environment: ["PATH": path], alsoSearch: [])?.path == first.path)
        #expect(ClaudeEnvironment.locateCLI(environment: ["PATH": "/nonexistent"], alsoSearch: [second.deletingLastPathComponent().path])?.path == second.path)
    }

    @Test func aProcessRunsWhereItIsToldWithItsEnvironment() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let physical = try #require(realpath(dir.path, nil).map { String(cString: $0) })
        let process = try ClaudeProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                        arguments: ["-c", #"printf '{"type":"x","cwd":"%s","mark":"%s"}\n' "$(pwd -P)" "$MARK""#],
                                        environment: ["MARK": "set"], workingDirectory: dir)
        var raw: [String] = []
        for await output in process.output { if case .line(let line) = output { raw.append(line.raw) } }
        #expect(raw == [#"{"type":"x","cwd":"\#(physical)","mark":"set"}"#])
    }

    @Test func withoutKeptInputAProcessSeesEndOfInputAtOnce() async throws {
        let process = try ClaudeProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                        arguments: ["-c", #"if read -r line; then echo "{\"type\":\"got\"}"; else echo '{"type":"eof"}'; fi"#],
                                        environment: [:], workingDirectory: FileManager.default.temporaryDirectory)
        #expect(!process.send(Data("hello\n".utf8)))
        var raw: [String] = []
        for await output in process.output { if case .line(let line) = output { raw.append(line.raw) } }
        #expect(raw == [#"{"type":"eof"}"#])
    }

    @Test func keptInputCarriesLinesUntilClosed() async throws {
        let process = try ClaudeProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                        arguments: ["-c", #"while read -r line; do echo "{\"type\":\"$line\"}"; done; echo '{"type":"closed"}'"#],
                                        environment: [:], workingDirectory: FileManager.default.temporaryDirectory, keepInputOpen: true)
        #expect(process.send(Data("one\n".utf8)))
        #expect(process.send(Data("two\n".utf8)))
        process.closeInput()
        #expect(!process.send(Data("three\n".utf8)))
        var raw: [String] = []
        var exit: Int32?
        for await output in process.output {
            switch output {
            case .line(let line): raw.append(line.raw)
            case .exited(let code, _): exit = code
            }
        }
        #expect(raw == [#"{"type":"one"}"#, #"{"type":"two"}"#, #"{"type":"closed"}"#])
        #expect(exit == 0)
    }

    @Test func cancellingTwiceSendsOneInterrupt() async throws {
        let process = try ClaudeProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                        arguments: ["-c", #"n=0; trap 'n=$((n+1)); echo "{\"type\":\"int$n\"}"' INT; echo '{"type":"ready"}'; while [ $n -lt 2 ]; do sleep 0.05; done"#],
                                        environment: [:], workingDirectory: FileManager.default.temporaryDirectory)
        var raw: [String] = []
        for await output in process.output {
            guard case .line(let line) = output else { continue }
            raw.append(line.raw)
            if line.raw.contains("ready") {
                process.cancel()
                process.cancel()
            }
        }
        #expect(raw.filter { $0.contains("int") } == [#"{"type":"int1"}"#])
    }
}
#endif
