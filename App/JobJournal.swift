import Foundation

struct JobRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var request: String
    var workingDirectory: String
    var hires: [String]
    var costUSD: Double?
    var budgetUSD: Double
    var duration: TimeInterval
    var files: [String]
    var sessionID: String?
    var outcome: String
    var buildingID: UUID?
    var floorID: UUID?

    var folderName: String { URL(fileURLWithPath: workingDirectory).lastPathComponent }
}

enum JobJournal {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("The Office/jobs.json")
    }

    static func load() -> [JobRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([JobRecord].self, from: data)) ?? []
    }

    static func save(_ records: [JobRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(records.suffix(200))) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
