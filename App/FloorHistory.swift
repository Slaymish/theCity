import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case request, followUp, outcome }
    var id = UUID()
    var date: Date
    var job: UUID
    var kind: Kind
    var title: String?
    var text: String
}

enum FloorHistory {
    static func url(for floorID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("The City/history/\(floorID.uuidString).json")
    }

    static func load(_ floorID: UUID) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url(for: floorID)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [HistoryEntry], for floorID: UUID) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        let url = url(for: floorID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func delete(_ floorID: UUID) {
        try? FileManager.default.removeItem(at: url(for: floorID))
    }
}
