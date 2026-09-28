import Foundation
import Testing
@testable import OfficeCore

struct SessionTranscriptTests {
    private let lines = [
        #"{"type":"user","message":{"role":"user","content":"Old prompt"},"timestamp":"2026-09-28T09:00:00.000Z"}"#,
        #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"},"timestamp":"2026-09-28T10:00:00.000Z"}"#,
        #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"timestamp":"2026-09-28T10:00:01.000Z"}"#,
        #"{"type":"user","message":{"role":"user","content":"Add a README"},"timestamp":"2026-09-28T10:00:02.000Z"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":""}]},"timestamp":"2026-09-28T10:00:03.000Z"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reading the project."}]},"timestamp":"2026-09-28T10:00:04.000Z"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"timestamp":"2026-09-28T10:00:05.000Z"}"#,
        #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"Subagent text"}]},"timestamp":"2026-09-28T10:00:06.000Z"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Wrote README.md."}]},"timestamp":"2026-09-28T10:00:07.000Z"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"Match this logo"}]},"timestamp":"2026-09-28T10:01:00.000Z"}"#,
        #"not json"#,
    ]

    private var data: Data { Data(lines.joined(separator: "\n").utf8) }

    @Test func readsTypedPromptsAndTheirLastReply() throws {
        let since = try Date("2026-09-28T09:30:00Z", strategy: .iso8601)
        let turns = SessionTranscript.turns(in: data, since: since)
        #expect(turns.map(\.prompt) == ["Add a README", "Match this logo"])
        #expect(turns.map(\.reply) == ["Wrote README.md.", nil])
    }

    @Test func skipsTurnsBeforeTheTerminalOpened() throws {
        let since = try Date("2026-09-28T10:00:30Z", strategy: .iso8601)
        #expect(SessionTranscript.turns(in: data, since: since).map(\.prompt) == ["Match this logo"])
    }

    @Test func findsTheTranscriptInAnyProjectFolder() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("SessionTranscriptTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        let folder = config.appendingPathComponent("projects/-Users-me-app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        try data.write(to: folder.appendingPathComponent("\(id).jsonl"))
        #expect(SessionTranscript.file(for: id, configDirectory: config)?.lastPathComponent == "\(id).jsonl")
        #expect(SessionTranscript.file(for: "missing", configDirectory: config) == nil)
        #expect(SessionTranscript.file(for: id, configDirectory: nil, environment: ["CLAUDE_CONFIG_DIR": config.path]) != nil)
    }
}
