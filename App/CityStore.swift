import AppKit
import Foundation
import Observation
import OfficeCore

/// Buildings are projects (a folder); floors are saved office setups inside them, each with its own job session.
@MainActor
@Observable
final class CityStore {
    struct Floor: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var hires: [String]
        var model: String?
        var budgetUSD: Double
        var allowedServers: [String]?
        var allowedSkills: [String]?
        var createdAt = Date()
        var lastRequest: String?
        var sessionID: String?
        var lastOutcome: String?
    }

    struct Building: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var path: String
        var style: Int
        var floors: [Floor] = []
        var createdAt = Date()

        var url: URL { URL(fileURLWithPath: path) }
    }

    enum Route: Equatable {
        case welcome
        case city
        case building(UUID)
        case floor(building: UUID, floor: UUID)
        case newFloor(UUID)
    }

    static let shared = CityStore()

    private(set) var buildings: [Building] = []
    var route: Route = .welcome
    private(set) var sessions: [UUID: RunController] = [:]
    private(set) var draft: RunController?
    private(set) var journal: [JobRecord] = JobJournal.load()

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("The Office/city.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            buildings = (try? decoder.decode([Building].self, from: data)) ?? []
        }
        if buildings.isEmpty, let path = RunController.launchArgument("-workspace") ?? UserDefaults.standard.string(forKey: "workingDirectory") {
            _ = addBuilding(at: URL(fileURLWithPath: path))
        }
        route = buildings.isEmpty ? .welcome : .city
        if ProcessInfo.processInfo.arguments.contains("-show-building"), let first = buildings.first { route = .building(first.id) }
    }

    // MARK: Buildings and floors

    func building(_ id: UUID) -> Building? { buildings.first { $0.id == id } }

    func floor(_ id: UUID, in building: UUID) -> Floor? { self.building(building)?.floors.first { $0.id == id } }

    @discardableResult
    func addBuilding(at url: URL) -> Building {
        if let existing = buildings.first(where: { $0.path == url.path }) { return existing }
        let building = Building(name: url.lastPathComponent, path: url.path, style: buildings.count % 8)
        buildings.append(building)
        save()
        return building
    }

    func removeBuilding(_ id: UUID) {
        guard let building = building(id), !building.floors.contains(where: { sessions[$0.id]?.isRunning == true }) else { return }
        building.floors.forEach { sessions[$0.id] = nil }
        buildings.removeAll { $0.id == id }
        if case .building(id) = route { route = .city }
        save()
    }

    func removeFloor(_ id: UUID, in buildingID: UUID) {
        guard sessions[id]?.isRunning != true, let index = buildings.firstIndex(where: { $0.id == buildingID }) else { return }
        buildings[index].floors.removeAll { $0.id == id }
        sessions[id] = nil
        save()
    }

    func renameFloor(_ id: UUID, in buildingID: UUID, to name: String) {
        update(floor: id, in: buildingID) { $0.name = name }
    }

    func update(floor id: UUID, in buildingID: UUID, _ change: (inout Floor) -> Void) {
        guard let b = buildings.firstIndex(where: { $0.id == buildingID }),
              let f = buildings[b].floors.firstIndex(where: { $0.id == id }) else { return }
        change(&buildings[b].floors[f])
        save()
    }

    // MARK: Sessions

    func session(for floorID: UUID, in buildingID: UUID) -> RunController? {
        if let existing = sessions[floorID] { return existing }
        guard let building = building(buildingID), let floor = floor(floorID, in: buildingID) else { return nil }
        let session = RunController(building: building, floor: floor)
        sessions[floorID] = session
        return session
    }

    func startNewFloor(in buildingID: UUID, request: String = "", name: String? = nil) {
        guard let building = building(buildingID) else { return }
        let session = RunController(building: building, floor: nil)
        session.pendingFloorName = name
        draft = session
        route = .newFloor(buildingID)
        if !request.isEmpty {
            session.request = request
            session.beginHiring()
        }
    }

    /// Reception hands a request to an existing floor's team.
    func send(_ request: String, toFloor floorID: UUID, in buildingID: UUID) {
        guard let session = session(for: floorID, in: buildingID) else { return }
        route = .floor(building: buildingID, floor: floorID)
        if session.isRunning {
            session.queue(request)
        } else {
            session.newJobOnFloor(request)
        }
    }

    /// Called when a draft's hiring is done: the draft becomes the new floor's session.
    func floorOpened(_ session: RunController) -> UUID? {
        guard let buildingID = session.buildingID, let index = buildings.firstIndex(where: { $0.id == buildingID }) else { return nil }
        let floor = Floor(
            name: session.pendingFloorName ?? Self.floorName(for: session.request, existing: buildings[index].floors.map(\.name)),
            hires: session.hired.map(\.name), model: session.model, budgetUSD: session.budgetUSD,
            allowedServers: session.kit.map { _ in Array(session.allowedServers) },
            allowedSkills: session.kit.map { _ in Array(session.allowedSkills) },
            lastRequest: session.request
        )
        buildings[index].floors.append(floor)
        sessions[floor.id] = session
        if draft === session { draft = nil }
        save()
        route = .floor(building: buildingID, floor: floor.id)
        return floor.id
    }

    func jobStarted(on floorID: UUID?, in buildingID: UUID?, request: String) {
        guard let floorID, let buildingID else { return }
        update(floor: floorID, in: buildingID) { $0.lastRequest = request }
    }

    func jobEnded(on floorID: UUID?, in buildingID: UUID?, sessionID: String?, outcome: String) {
        guard let floorID, let buildingID else { return }
        update(floor: floorID, in: buildingID) {
            $0.sessionID = sessionID ?? $0.sessionID
            $0.lastOutcome = outcome
        }
    }

    nonisolated static func floorName(for request: String, existing: [String]) -> String {
        let words = request.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
        var name = words.isEmpty ? "New floor" : String(words.prefix(40))
        if let first = name.first { name = first.uppercased() + name.dropFirst() }
        var candidate = name
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(name) \(n)"
            n += 1
        }
        return candidate
    }

    /// Replays a saved stream on a throwaway floor of the first building, for demos and checking the scene.
    func startReplay(_ url: URL) {
        let building = buildings.first ?? addBuilding(at: RunController.defaultWorkspace ?? url.deletingLastPathComponent())
        let session = RunController(building: building, floor: nil)
        draft = session
        route = .newFloor(building.id)
        session.replay(url)
    }

    var activeSession: RunController? {
        switch route {
        case .floor(let building, let floor): session(for: floor, in: building)
        case .newFloor: draft
        default: nil
        }
    }

    // MARK: Across floors

    var allSessions: [RunController] { Array(sessions.values) + (draft.map { [$0] } ?? []) }

    var pendingCount: Int { allSessions.reduce(0) { $0 + $1.state.pendingRequests.count } }

    var anyRunning: Bool { allSessions.contains { $0.isRunning } }

    func status(of building: Building) -> (working: Int, waiting: Int) {
        building.floors.reduce((0, 0)) { total, floor in
            guard let session = sessions[floor.id] else { return total }
            return (total.0 + (session.isRunning ? 1 : 0), total.1 + session.state.pendingRequests.count)
        }
    }

    func session(forRequest requestID: String) -> RunController? {
        allSessions.first { $0.state.pendingRequests.contains { $0.id == requestID } }
    }

    func shutDown() async {
        for session in allSessions where session.isRunning { await session.shutDown() }
    }

    // MARK: Journal

    var recentJobs: [JobRecord] { Array(journal.reversed().prefix(5)) }

    private var lastSeen: [String: Date] = UserDefaults.standard.dictionary(forKey: "lastSeen") as? [String: Date] ?? [:]

    @discardableResult
    func visit(_ id: UUID) -> Date? {
        let previous = lastSeen[id.uuidString]
        lastSeen[id.uuidString] = .now
        UserDefaults.standard.set(lastSeen, forKey: "lastSeen")
        return previous
    }

    func jobs(in building: Building, since date: Date) -> [JobRecord] {
        journal.filter { job in
            job.date > date && (job.buildingID == building.id || (job.buildingID == nil && job.workingDirectory == building.path))
        }.reversed()
    }

    func hasParcel(_ building: Building) -> Bool {
        guard let seen = lastSeen[building.id.uuidString] else { return false }
        return jobs(in: building, since: seen).contains { $0.outcome == "completed" }
    }

    var groundBreaking: UUID?

    func record(_ change: (inout [JobRecord]) -> Void) {
        change(&journal)
        JobJournal.save(journal)
    }

    // MARK: Persistence

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(buildings) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
