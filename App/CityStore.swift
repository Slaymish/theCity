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
        var nameIsCustom: Bool?
        var configDirectory: String?
        var presetID: String?
        var purpose: String?
    }

    struct Building: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var path: String
        var style: Int
        var floors: [Floor] = []
        var createdAt = Date()
        var title: String?

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
    var route: Route = .welcome {
        didSet { endDemoIfLeft() }
    }
    private(set) var demoID: UUID?
    private var demoEntered = false
    private(set) var sessions: [UUID: RunController] = [:]
    private(set) var draft: RunController?
    var cancelledRequests: [UUID: String] = [:]
    var routing: Set<UUID> = []
    private(set) var hiringHeadless: [UUID: RunController] = [:]
    private(set) var journal: [JobRecord] = JobJournal.load()
    private(set) var totals: [UUID: JobTotals] = [:]

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("The City/city.json")
    }

    private init() {
        totals = JobTotals.load(seed: journal)
        if let data = try? Data(contentsOf: Self.fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            buildings = (try? decoder.decode([Building].self, from: data)) ?? []
        }
        if buildings.isEmpty, let path = RunController.launchArgument("-workspace") ?? UserDefaults.standard.string(forKey: "workingDirectory") {
            _ = addBuilding(at: URL(fileURLWithPath: path))
        }
        buildings.map(\.id).forEach(nameProject)
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
        nameProject(building.id)
        return building
    }

    private var naming: Set<UUID> = []

    /// Asks Haiku once for the project's proper name, shown on the building's billboard.
    private func nameProject(_ id: UUID) {
        guard let building = building(id), building.title == nil, !naming.contains(id) else { return }
        naming.insert(id)
        Task {
            let title = await FloorNamer.projectName(folder: building.url, configDirectory: Preferences.shared.configDirectory)
            naming.remove(id)
            guard let title, let index = buildings.firstIndex(where: { $0.id == id }) else { return }
            buildings[index].title = title
            save()
        }
    }

    func removeBuilding(_ id: UUID) {
        guard let building = building(id), !building.floors.contains(where: { sessions[$0.id]?.isRunning == true }) else { return }
        building.floors.forEach { sessions[$0.id]?.kiosk.end(); sessions[$0.id] = nil; FloorHistory.delete($0.id) }
        hiringHeadless[id] = nil
        buildings.removeAll { $0.id == id }
        if case .building(id) = route { route = .city }
        save()
    }

    func removeFloor(_ id: UUID, in buildingID: UUID) {
        guard let index = buildings.firstIndex(where: { $0.id == buildingID }) else { return }
        sessions[id]?.cancel()
        sessions[id]?.kiosk.end()
        if route == .floor(building: buildingID, floor: id) { route = .building(buildingID) }
        buildings[index].floors.removeAll { $0.id == id }
        sessions[id] = nil
        FloorHistory.delete(id)
        save()
    }

    func renameFloor(_ id: UUID, in buildingID: UUID, to name: String) {
        update(floor: id, in: buildingID) {
            $0.name = name
            $0.nameIsCustom = true
        }
    }

    private var namedFor: [UUID: String] = [:]

    /// Asks Haiku once for a short label describing the floor's work, unless the user named it.
    private func relabel(_ floorID: UUID, in buildingID: UUID, for request: String) {
        guard let building = building(buildingID), let floor = floor(floorID, in: buildingID),
              floor.nameIsCustom != true, namedFor[floorID] != request,
              !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        namedFor[floorID] = request
        let others = building.floors.filter { $0.id != floorID }.map(\.name)
        let configDirectory = sessions[floorID]?.configDirectory ?? Preferences.shared.configDirectory
        Task {
            guard let label = await FloorNamer.label(for: request, avoiding: others, configDirectory: configDirectory),
                  namedFor[floorID] == request, self.floor(floorID, in: buildingID)?.nameIsCustom != true else { return }
            update(floor: floorID, in: buildingID) { $0.name = label }
        }
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

    var currentBuildingID: UUID? {
        switch route {
        case .building(let id), .floor(let id, _), .newFloor(let id): id
        default: nil
        }
    }

    func startNewFloor(in buildingID: UUID, request: String = "", name: String? = nil, preset: FloorPreset? = nil) {
        guard let building = building(buildingID) else { return }
        let session = RunController(building: building, floor: nil)
        session.pendingFloorName = name
        session.pendingPreset = preset
        draft = session
        route = .newFloor(buildingID)
        if request.isEmpty {
            session.pickTeamYourself()
        } else {
            session.request = request
            session.beginHiring()
        }
    }

    func hireNewFloor(in buildingID: UUID, request: String, name: String?, preset: FloorPreset?) {
        guard let building = building(buildingID), hiringHeadless[buildingID] == nil else { return }
        let session = RunController(building: building, floor: nil)
        session.pendingFloorName = name
        session.pendingPreset = preset
        session.request = request
        session.opensWhenHired = true
        hiringHeadless[buildingID] = session
        session.beginHiring()
    }

    func headlessHiringDone(_ session: RunController) {
        guard let buildingID = session.buildingID, hiringHeadless[buildingID] === session else { return }
        if session.candidates.contains(where: \.hired) { return session.openOffice() }
        hiringHeadless[buildingID] = nil
        let name = session.displayTitle
        let place = building(buildingID)?.name ?? name
        guard draft == nil else {
            return Attention.shared.needsTeam(for: name, place: place, building: buildingID, drafted: false)
        }
        session.opensWhenHired = false
        draft = session
        if MainWindow.shared.isOpen && NSApp.isActive {
            route = .newFloor(buildingID)
        } else {
            Attention.shared.needsTeam(for: name, place: place, building: buildingID, drafted: true)
        }
    }

    func isBusy(_ buildingID: UUID) -> Bool { routing.contains(buildingID) || hiringHeadless[buildingID] != nil }

    func cancelNewFloor() {
        guard case .newFloor(let id) = route else { return }
        if let request = draft?.request, !request.isEmpty { cancelledRequests[id] = request }
        draft = nil
        route = .building(id)
    }

    /// Reception hands a request to an existing floor's team, as a fresh job or as a follow-up on its last one.
    func send(_ request: String, toFloor floorID: UUID, in buildingID: UUID, continuing: Bool = false, navigate: Bool = true) {
        guard let session = session(for: floorID, in: buildingID) else { return }
        if navigate { route = .floor(building: buildingID, floor: floorID) }
        if session.isRunning {
            session.queue(request, continuing: continuing)
        } else if continuing {
            session.followUp(request)
        } else {
            session.newJobOnFloor(request)
        }
    }

    func canContinue(_ floor: Floor) -> Bool {
        floor.sessionID != nil || sessions[floor.id]?.canContinue == true
    }

    /// Called when a draft's hiring is done: the draft becomes the new floor's session.
    func floorOpened(_ session: RunController) -> UUID? {
        guard let buildingID = session.buildingID, let index = buildings.firstIndex(where: { $0.id == buildingID }) else { return nil }
        let floor = Floor(
            name: session.pendingFloorName ?? Self.floorName(for: session.request, existing: buildings[index].floors.map(\.name)),
            hires: session.hired.map(\.name), model: session.model, budgetUSD: session.budgetUSD,
            allowedServers: session.kit.map { _ in Array(session.allowedServers) },
            allowedSkills: session.kit.map { _ in Array(session.allowedSkills) },
            lastRequest: session.request,
            configDirectory: session.configDirectory?.path,
            presetID: session.pendingPreset?.id,
            purpose: session.pendingPreset?.purpose ?? (session.request.isEmpty ? nil : String(session.request.prefix(160)))
        )
        buildings[index].floors.append(floor)
        sessions[floor.id] = session
        if draft === session { draft = nil }
        if hiringHeadless[buildingID] === session { hiringHeadless[buildingID] = nil }
        save()
        if !session.opensWhenHired { route = .floor(building: buildingID, floor: floor.id) }
        if session.pendingPreset?.session != .fresh { relabel(floor.id, in: buildingID, for: session.request) }
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

    static var demoRecording: URL? { Bundle.main.url(forResource: "three-rooms", withExtension: "jsonl") }

    func startDemo() {
        guard demoID == nil,
              let workspace = Bundle.main.url(forResource: "SampleWorkspace", withExtension: nil),
              let recording = Self.demoRecording else { return }
        let floor = Floor(name: "Demo", hires: AgentCatalogue.load(workingDirectory: workspace).filter { !$0.isBuiltIn }.map(\.name),
                          budgetUSD: Preferences.shared.budgetUSD,
                          lastRequest: "Write hello.txt with a one-line greeting.", nameIsCustom: true)
        let building = Building(name: "Demo", path: workspace.path, style: buildings.count % 8, floors: [floor], title: "Demo")
        buildings.append(building)
        demoID = building.id
        route = .city
        Task { @MainActor in
            // Entering the floor before the building has finished rising leaves the camera outside it.
            try? await Task.sleep(for: .milliseconds(100))
            guard demoID == building.id else { return }
            route = .building(building.id)
            try? await Task.sleep(for: .seconds(OfficeScene.reduceMotion ? 0.1 : World.slide + 0.2))
            guard demoID == building.id, route == .building(building.id) else { return }
            route = .floor(building: building.id, floor: floor.id)
            session(for: floor.id, in: building.id)?.replay(recording)
        }
    }

    private func endDemoIfLeft() {
        guard let id = demoID else { return }
        switch route {
        case .building(id), .floor(id, _), .newFloor(id):
            demoEntered = true
            return
        default:
            guard demoEntered else { return }
        }
        demoID = nil
        demoEntered = false
        if draft?.buildingID == id { draft = nil }
        building(id)?.floors.forEach { sessions[$0.id]?.cancel(); sessions[$0.id]?.kiosk.end(); sessions[$0.id] = nil; FloorHistory.delete($0.id) }
        buildings.removeAll { $0.id == id }
        if buildings.isEmpty { route = .welcome }
    }

    var activeSession: RunController? {
        switch route {
        case .floor(let building, let floor): session(for: floor, in: building)
        case .newFloor: draft
        default: nil
        }
    }

    // MARK: Across floors

    var allSessions: [RunController] { Array(sessions.values) + Array(hiringHeadless.values) + (draft.map { [$0] } ?? []) }

    var pendingCount: Int { allSessions.reduce(0) { $0 + $1.state.pendingRequests.count } }

    var anyRunning: Bool { allSessions.contains { $0.isRunning } }

    func status(of building: Building) -> (working: Int, waiting: Int) {
        building.floors.reduce((0, 0)) { total, floor in
            guard let session = sessions[floor.id] else { return total }
            return (total.0 + (session.isRunning ? 1 : 0), total.1 + session.state.pendingRequests.count)
        }
    }

    func statusLine(for building: Building) -> String {
        let status = status(of: building)
        let floors = building.floors.isEmpty ? "Empty lot" : "\(building.floors.count) floor\(building.floors.count == 1 ? "" : "s")"
        return status.waiting > 0 ? "Needs you" : status.working > 0 ? "\(status.working) working" : building.floors.isEmpty ? floors : "\(floors) · all quiet"
    }

    /// Spend and tokens of the jobs running now, and every room on these floors by what it's doing.
    func live(on floors: [Floor]) -> (spendUSD: Double, tokens: Int, rooms: RoomCounts) {
        floors.reduce((0, 0, RoomCounts())) { total, floor in
            guard let session = sessions[floor.id] else { return (total.0, total.1, total.2 + RoomCounts(idle: floor.hires.count + 1)) }
            let running = session.isRunning
            return (total.0 + (running ? session.state.tally.costUSD ?? 0 : 0), total.1 + (running ? session.state.tally.total : 0),
                    total.2 + session.roomCounts)
        }
    }

    func jobSummary(on floors: [Floor]) -> JobSummary {
        let ids = Set(floors.map(\.id))
        let today = journal.filter { job in job.floorID.map(ids.contains) == true && Calendar.current.isDateInToday(job.date) }
        return JobSummary(today: today.count, todaySpendUSD: today.compactMap(\.costUSD).reduce(0, +),
                          todayTokens: today.compactMap(\.tokens).reduce(0, +),
                          totals: floors.compactMap { totals[$0.id] }.reduce(JobTotals(), +))
    }

    var allFloors: [Floor] { buildings.flatMap(\.floors) }

    func vitals(on floors: [Floor]) -> Vitals {
        let live = live(on: floors)
        return Vitals(rooms: live.rooms, running: floors.contains { sessions[$0.id]?.isRunning == true }, liveSpendUSD: live.spendUSD,
                      liveTokens: live.tokens, summary: jobSummary(on: floors), onPlan: isOnPlan)
    }

    func jobsByDay(on floors: [Floor], days: Int = 7) -> [(day: Date, jobs: Int)] {
        let ids = Set(floors.map(\.id)), calendar = Calendar.current, today = calendar.startOfDay(for: .now)
        let counts = journal.reduce(into: [Date: Int]()) { counts, job in
            if job.floorID.map(ids.contains) == true { counts[calendar.startOfDay(for: job.date), default: 0] += 1 }
        }
        return (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }.map { ($0, counts[$0] ?? 0) }
    }

    /// Offscreen renders only: sample sessions and jobs that are never saved.
    func seedPreview(sessions seeded: [UUID: RunController], journal jobs: [JobRecord]) {
        sessions.merge(seeded) { $1 }
        journal += jobs
        for job in jobs {
            guard let floor = job.floorID else { continue }
            totals[floor, default: JobTotals()].add(isNew: true, outcome: job.outcome, replacing: nil, costUSD: job.costUSD ?? 0,
                                                    tokens: job.tokens ?? 0, duration: job.duration)
        }
    }

    var isOnPlan: Bool {
        StatusFormat.isOnPlan(allSessions.compactMap(\.state.rateLimit).first { !$0.windows.isEmpty }, configDirectory: Preferences.shared.configDirectory)
    }

    func dollars(_ amount: Double) -> String { StatusFormat.dollars(amount, onPlan: isOnPlan) }

    func session(forRequest requestID: String) -> RunController? {
        allSessions.first { $0.state.pendingRequests.contains { $0.id == requestID } }
    }

    func shutDown() async {
        for session in allSessions where session.isRunning { await session.shutDown() }
    }

    // MARK: Journal

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

    func addToTotals(floor: UUID?, _ change: (inout JobTotals) -> Void) {
        guard let floor else { return }
        change(&totals[floor, default: JobTotals()])
        JobTotals.save(totals)
    }

    // MARK: Persistence

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(buildings.filter { $0.id != demoID }) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
