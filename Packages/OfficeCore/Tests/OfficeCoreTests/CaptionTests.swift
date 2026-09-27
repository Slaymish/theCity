import Foundation
import Testing
@testable import OfficeCore

struct CaptionTests {
    @Test(arguments: [
        ("Read", ["file_path": "/repo/App/Worker.swift"], "reading Worker.swift"),
        ("Write", ["file_path": "/repo/App/ContentViewController.swift"], "writing ContentViewCont…"),
        ("Bash", ["command": "git status --short"], "running git"),
        ("Bash", ["command": "ls", "description": "List files"], "running List files"),
        ("Grep", ["pattern": "roomActivity"], "searching \"roomActivity\""),
        ("WebSearch", ["query": "swift actors reentrancy"], "web: \"swift actors ree…\""),
        ("WebFetch", ["url": "https://www.apple.com/uk/"], "reading apple.com"),
        ("TodoWrite", [:], "planning"),
        ("Read", [:], "reading"),
        ("mcp__specification-website__search", [:], "using search"),
    ])
    func captionsFitTheScreen(name: String, input: [String: String], expected: String) {
        let caption = ToolCaption.text(name: name, input: .object(input.mapValues { .string($0) }))
        #expect(caption == expected)
        #expect(caption.count <= ToolCaption.limit)
    }

    @Test func captionsFollowEachRoomsToolCalls() throws {
        var reducer = OfficeReducer()
        let captions = reducer.runToExit(try Fixture.events("three-rooms.jsonl")).compactMap {
            if case .roomCaption(let room, let caption) = $0 { "\(room): \(caption)" } else { nil }
        }
        #expect(captions.contains { $0.hasPrefix("research: reading ") })
        #expect(captions.contains("build: writing hello.txt"))
        #expect(captions.contains("build: thinking…"))
    }
}
