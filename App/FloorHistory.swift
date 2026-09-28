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
        DataFiles.url("history/\(floorID.uuidString).json")
    }

    static func load(_ floorID: UUID) -> [HistoryEntry] {
        DataFiles.load([HistoryEntry].self, from: url(for: floorID)) ?? []
    }

    static func save(_ entries: [HistoryEntry], for floorID: UUID) {
        DataFiles.save(entries, to: url(for: floorID))
    }

    static func delete(_ floorID: UUID) {
        try? FileManager.default.removeItem(at: url(for: floorID))
    }
}
