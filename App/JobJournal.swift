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
    var tokens: Int?

    var folderName: String { URL(fileURLWithPath: workingDirectory).lastPathComponent }
}

enum JobJournal {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("The City/jobs.json")
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

/// Running totals for one floor, kept apart from the journal so they survive its 200-record cap.
struct JobTotals: Codable, Equatable {
    var jobs = 0
    var succeeded = 0
    var cancelled = 0
    var spendUSD: Double = 0
    var tokens = 0
    var duration: TimeInterval = 0

    /// Cancelled jobs are left out of the denominator.
    var successRate: Double? {
        let decided = jobs - cancelled
        return decided > 0 ? Double(succeeded) / Double(decided) : nil
    }

    var averageDuration: TimeInterval { jobs > 0 ? duration / Double(jobs) : 0 }

    mutating func add(isNew: Bool, outcome: String, replacing previous: String?, costUSD: Double, tokens: Int, duration: TimeInterval) {
        if isNew { jobs += 1 }
        if previous == "completed" { succeeded -= 1 }
        if previous == "cancelled" { cancelled -= 1 }
        if outcome == "completed" { succeeded += 1 }
        if outcome == "cancelled" { cancelled += 1 }
        spendUSD += costUSD
        self.tokens += tokens
        self.duration += duration
    }

    static func + (lhs: JobTotals, rhs: JobTotals) -> JobTotals {
        JobTotals(jobs: lhs.jobs + rhs.jobs, succeeded: lhs.succeeded + rhs.succeeded, cancelled: lhs.cancelled + rhs.cancelled,
                  spendUSD: lhs.spendUSD + rhs.spendUSD, tokens: lhs.tokens + rhs.tokens, duration: lhs.duration + rhs.duration)
    }

    static var url: URL { JobJournal.url.deletingLastPathComponent().appendingPathComponent("totals.json") }

    /// The first launch with totals starts them from whatever the journal still holds.
    static func load(seed journal: [JobRecord]) -> [UUID: JobTotals] {
        if let data = try? Data(contentsOf: url), let totals = try? JSONDecoder().decode([UUID: JobTotals].self, from: data) { return totals }
        return journal.reduce(into: [:]) { totals, job in
            guard let floor = job.floorID else { return }
            totals[floor, default: JobTotals()].add(isNew: true, outcome: job.outcome, replacing: nil, costUSD: job.costUSD ?? 0,
                                                    tokens: job.tokens ?? 0, duration: job.duration)
        }
    }

    static func save(_ totals: [UUID: JobTotals]) {
        guard let data = try? JSONEncoder().encode(totals) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Jobs on a set of floors: today's from the journal, all-time from the running totals.
struct JobSummary: Equatable {
    var today = 0
    var todaySpendUSD: Double = 0
    var todayTokens = 0
    var totals = JobTotals()
}
