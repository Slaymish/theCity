import Foundation
@testable import OfficeCore

enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../fixtures")
        .standardized

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func rawLines(_ name: String) throws -> [String] {
        var lines = try String(contentsOf: url(name), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func events(_ name: String) throws -> [WireEvent] {
        try rawLines(name).compactMap {
            if case .event(let event) = StreamParser.parse($0) { event } else { nil }
        }
    }
}

extension OfficeReducer {
    mutating func run(_ events: [WireEvent]) -> [OfficeEvent] {
        events.flatMap { apply(.wire($0)) }
    }

    mutating func runToExit(_ events: [WireEvent], code: Int32 = 0) -> [OfficeEvent] {
        run(events) + apply(.processExited(code: code, stderr: ""))
    }
}

extension Array where Element == OfficeEvent {
    var withoutTally: [OfficeEvent] {
        filter { if case .tallyChanged = $0 { false } else { true } }
    }
}
