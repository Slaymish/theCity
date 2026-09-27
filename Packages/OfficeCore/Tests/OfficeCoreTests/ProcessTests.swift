import Foundation
import Testing
@testable import OfficeCore

struct ProcessTests {
    static let shell = URL(fileURLWithPath: "/bin/sh")

    static func collect(_ process: ClaudeProcess) async -> (lines: [StreamLine], exit: (Int32, String)?) {
        var lines: [StreamLine] = []
        var exit: (Int32, String)?
        for await output in process.output {
            switch output {
            case .line(let line): lines.append(line)
            case .exited(let code, let stderr): exit = (code, stderr)
            }
        }
        return (lines, exit)
    }

    @Test func streamsAFixtureThroughARealProcess() async throws {
        let process = try ClaudeProcess(
            executable: Self.shell,
            arguments: ["-c", "cat \"$0\"; echo oops >&2; exit 3", Fixture.url("three-rooms.jsonl").path],
            environment: [:],
            workingDirectory: Fixture.directory
        )
        let (lines, exit) = await Self.collect(process)
        #expect(lines.count == 39)
        #expect(lines.map(\.index) == Array(0..<39))
        #expect(exit?.0 == 3)
        #expect(exit?.1 == "oops\n")
    }

    @Test func lineSeparatorInsideJsonDoesNotSplitTheLine() async throws {
        let process = try ClaudeProcess(
            executable: Self.shell,
            arguments: ["-c", "printf '{\"type\":\"rate_limit_event\",\"t\":\"a\\342\\200\\250b\"}\\n'"],
            environment: [:],
            workingDirectory: Fixture.directory
        )
        let (lines, _) = await Self.collect(process)
        #expect(lines.map(\.parsed) == [.event(.rateLimit(RateLimit(status: nil, resetsAt: nil, kind: nil, windows: [:])))])
    }

    @Test func cancelSendsInterruptAndKeepsTheFinalLine() async throws {
        let script = """
        trap 'echo "{\\"type\\":\\"result\\",\\"subtype\\":\\"error_during_execution\\",\\"is_error\\":true}"; exit 0' INT
        echo '{"type":"system","subtype":"init"}'
        while :; do sleep 0.05; done
        """
        let process = try ClaudeProcess(executable: Self.shell, arguments: ["-c", script], environment: [:], workingDirectory: Fixture.directory)
        Task {
            try await Task.sleep(for: .milliseconds(300))
            process.cancel()
        }
        let (lines, exit) = await Self.collect(process)
        #expect(lines.count == 2)
        #expect(exit?.0 == 0)
    }

    @Test func cancelEscalatesWhenInterruptIsIgnored() async throws {
        let process = try ClaudeProcess(
            executable: Self.shell,
            arguments: ["-c", "trap '' INT; echo ready; while :; do sleep 0.05; done"],
            environment: [:],
            workingDirectory: Fixture.directory
        )
        var start = ContinuousClock.now
        var exit: (Int32, String)?
        for await output in process.output {
            switch output {
            case .line:
                start = .now
                process.cancel()
            case .exited(let code, let stderr): exit = (code, stderr)
            }
        }
        #expect(exit?.0 == SIGTERM)
        #expect(ContinuousClock.now - start >= .seconds(3))
    }

    @Test func environmentDropsParentSessionAndSetsConfigDirectory() {
        let env = ClaudeEnvironment.make(
            base: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "x", "CLAUDE_CODE_USE_BEDROCK": "1", "PATH": "/usr/bin"],
            configDirectory: URL(fileURLWithPath: "/tmp/cfg")
        )
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(env["CLAUDE_CODE_USE_BEDROCK"] == "1")
        #expect(env["CLAUDE_CONFIG_DIR"] == "/tmp/cfg")
        #expect(env["PATH"]?.hasSuffix(":/opt/homebrew/bin:/usr/local/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.claude/local:/usr/bin") == true)
    }

    @Test func missingCLIIsNotFound() throws {
        #expect(ClaudeEnvironment.locateCLI(environment: ["PATH": "/nonexistent"], alsoSearch: []) == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: fake.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        #expect(ClaudeEnvironment.locateCLI(environment: ["PATH": "/nonexistent"], alsoSearch: [dir.path])?.path == fake.path)
    }

    @Test func replayYieldsEveryLineThenExits() async throws {
        let stream = try FixtureReplay.stream(contentsOf: Fixture.url("three-rooms.jsonl"), interval: .zero)
        var count = 0
        var exited = false
        for await output in stream {
            if case .line = output { count += 1 } else { exited = true }
        }
        #expect(count == 39)
        #expect(exited)
    }
}
