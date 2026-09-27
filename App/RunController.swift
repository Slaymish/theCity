import AppKit
import Foundation
import Observation
import SwiftUI
import OfficeCore

struct LogEntry: Identifiable {
    enum Kind { case event(String), malformed(String), app, sent }
    let id = UUID()
    let elapsed: TimeInterval
    let kind: Kind
    let text: String
    /// Some lines run to tens of thousands of characters; laying them out even at two lines stalls scrolling.
    let preview: String

    init(elapsed: TimeInterval, kind: Kind, text: String) {
        self.elapsed = elapsed
        self.kind = kind
        self.text = text
        preview = text.count > 600 ? String(text.prefix(600)) + "…" : text
    }
}

/// Wall-clock time for one handoff, keyed by its `Agent` tool_use id.
struct HandoffTiming: Equatable {
    var startedAt: Date?
    var endedAt: Date?
    var waited: TimeInterval = 0
    var waitingSince: Date?

    func waiting(now: Date) -> TimeInterval { waited + (waitingSince.map { now.timeIntervalSince($0) } ?? 0) }

    func worked(now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max((endedAt ?? now).timeIntervalSince(startedAt) - waiting(now: endedAt ?? now), 0)
    }
}

struct Step: Identifiable, Equatable {
    enum Status { case waiting, working, done }
    var id: String { room }
    var room: String
    var colour: NSColor
    var isContractor: Bool
    var status: Status = .waiting
    var workedFor: TimeInterval = 0
    var startedAt: Date?
}

@MainActor
@Observable
final class RunController {
    enum Screen { case reception, hiring, office }
    enum PanelTab { case requests, room, kit }

    let buildingID: UUID?
    private(set) var floorID: UUID?
    var pendingFloorName: String?
    var pendingPreset: FloorPreset?
    var opensWhenHired = false
    private(set) var queued: [(text: String, continues: Bool)] = []
    let scene = OfficeScene()
    let kiosk = KioskSession()

    var screen: Screen = .reception
    enum Readiness: Equatable {
        case checking, ready, cliMissing, notLoggedIn
        case cliOutdated(String)
    }

    struct LimitNotice: Equatable {
        var message: String
        var url: URL?
        var resetsAt: Date?
    }

    var request = RunController.launchArgument("-request") ?? ""
    private(set) var readiness: Readiness = .checking
    private(set) var limitNotice: LimitNotice?
    private(set) var catalogueNames: [String] = []
    private(set) var hiringIsSlow = false
    var workingDirectory: URL? {
        didSet {
            if !isDemo { UserDefaults.standard.set(workingDirectory?.path, forKey: "workingDirectory") }
            loadKit()
            refreshCatalogue()
        }
    }
    var budgetUSD: Double = Preferences.shared.budgetUSD
    private(set) var permissionMode: PermissionMode = Preferences.shared.permissionMode
    var panelTab: PanelTab = .requests
    var showPanel = false
    var selectedRoom: String?
    var model: String? = RunController.launchArgument("-model") ?? Preferences.shared.model
    var configDirectory: URL? = Preferences.shared.configDirectory {
        didSet {
            loadKit()
            checkReadiness()
        }
    }
    private(set) var kit: Kit?
    private(set) var isLoadingKit = false
    var allowedServers: Set<String> = []
    var allowedSkills: Set<String> = []
    private(set) var kitReasons: [String: String] = [:]
    @ObservationIgnored private var kitTask: Task<Kit?, Never>?

    private(set) var candidates: [Candidate] = []
    private(set) var hiringNote: String?
    private(set) var isHiring = false
    private(set) var hired: [Department] = []

    private(set) var state = OfficeState()
    private(set) var steps: [Step] = []
    private(set) var activity: [ActivityItem] = []
    private(set) var log: [LogEntry] = []
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var jobFiles: [String] = []
    private(set) var followUps: [String] = []
    private(set) var history: [HistoryEntry] = []
    var showHistory = false
    private(set) var resumeSession: String?
    private(set) var currentJob: UUID?
    private(set) var timings: [String: HandoffTiming] = [:]
    /// Context windows seen on this floor, so a follow-up's gauge shows before its first `result`.
    private(set) var contextWindows: [String: Int] = [:]

    @ObservationIgnored private var reducer = OfficeReducer()
    @ObservationIgnored private var process: ClaudeProcess?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var isReplay = false
    @ObservationIgnored private var builtFor: (hires: [String], servers: [String], dark: Bool)?

    static let budgets: [Double] = [0.5, 1, 2, 5, 10]

    init(building: CityStore.Building?, floor: CityStore.Floor?) {
        buildingID = building?.id
        floorID = floor?.id
        history = floor.map { FloorHistory.load($0.id) } ?? []
        workingDirectory = building?.url ?? Self.defaultWorkspace
        if let path = floor?.configDirectory { configDirectory = URL(fileURLWithPath: path) }
        refreshCatalogue()
        loadKit()
        checkReadiness()
        guard let floor, let url = building?.url else { return }
        let catalogue = AgentCatalogue.load(workingDirectory: url)
        hired = floor.hires.compactMap { name in catalogue.first { $0.name == name } }
        model = floor.model
        budgetUSD = floor.budgetUSD
        if let servers = floor.allowedServers { allowedServers = Set(servers) }
        if let skills = floor.allowedSkills { allowedSkills = Set(skills) }
        resumeSession = floor.sessionID
        request = floor.lastRequest ?? ""
        screen = .office
        buildScene()
    }

    /// The floor's own office, built from its team and the services it may use.
    func buildScene(dark: Bool = Preferences.shared.isDark) {
        let servers = (kit?.usableServers ?? []).filter { allowedServers.contains($0.name) }
        builtFor = (hired.map(\.name), servers.map(\.name), dark)
        scene.build(hired: hired, servers: servers,
                    colour: { [weak self] in self?.colour(for: $0) ?? Palette.muted }, dark: dark)
        showRecords()
    }

    func showRecords() {
        guard let floorID, let buildingID else { return }
        let journal = CityStore.shared.journal
        let mine = journal.filter { $0.floorID == floorID && $0.outcome == "completed" }
        let fastest = journal.filter { $0.buildingID == buildingID && $0.outcome == "completed" }.min { $0.duration < $1.duration }
        scene.showRecords(mine, fastest: fastest?.floorID == floorID ? fastest?.duration : nil)
    }

    var displayTitle: String {
        guard let buildingID, let floorID, let floor = CityStore.shared.floor(floorID, in: buildingID) else { return pendingFloorName ?? "New floor" }
        return floor.name
    }

    var placeName: String {
        ([buildingID.flatMap { CityStore.shared.building($0)?.name }, displayTitle] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    func loadKit() {
        guard let workingDirectory else { return }
        let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        guard let executable = Self.cliOverride ?? ClaudeEnvironment.locateCLI(environment: environment) else { return }
        kitTask?.cancel()
        isLoadingKit = true
        let task = Task { () -> Kit? in
            let loaded = await KitLoader.load(executable: executable, environment: environment, workingDirectory: workingDirectory)
            return Task.isCancelled ? nil : loaded
        }
        kitTask = task
        Task {
            guard let loaded = await task.value else { return }
            kit = loaded
            let floor = floorID.flatMap { id in buildingID.flatMap { CityStore.shared.floor(id, in: $0) } }
            allowedServers = floor?.allowedServers.map(Set.init) ?? Set(loaded.usableServers.map(\.name))
            allowedSkills = floor?.allowedSkills.map(Set.init) ?? Set(loaded.skills.map(\.name))
            kitReasons = [:]
            isLoadingKit = false
            let servers = loaded.usableServers.filter { allowedServers.contains($0.name) }.map(\.name)
            if screen == .office && !isRunning, builtFor.map({ $0 != (hired.map(\.name), servers, Preferences.shared.isDark) }) ?? true { buildScene() }
        }
    }

    func toggleServer(_ name: String) {
        if !allowedServers.insert(name).inserted { allowedServers.remove(name) }
    }

    func toggleSkill(_ name: String) {
        if !allowedSkills.insert(name).inserted { allowedSkills.remove(name) }
    }

    func friendly(_ toolName: String) -> String {
        McpNaming.friendly(toolName, servers: (kit?.servers ?? state.mcpServers).map(\.name))
    }

    var isRunning: Bool { state.phase == .running || (consumer != nil && endedAt == nil) }

    var roomCounts: RoomCounts { state.roomCounts(staff: hired.map(\.name)) }

    var currentStep: String? {
        state.handoffs.values.filter { $0.phase == .working && $0.step != nil }.max { started($0) < started($1) }?.step
    }

    func started(_ handoff: Handoff) -> Date { timings[handoff.toolUseID]?.startedAt ?? .distantPast }

    func roomStats(_ room: String, now: Date) -> (latest: Handoff?, worked: TimeInterval, waited: TimeInterval, tokens: Int, tools: Int) {
        let staff = Set(hired.map(\.name))
        let handoffs = room == "contractor" ? state.handoffs.values.filter { !staff.contains($0.room) } : state.handoffs(in: room)
        return (handoffs.max { started($0) < started($1) },
                handoffs.reduce(0) { $0 + (timings[$1.toolUseID]?.worked(now: now) ?? 0) },
                handoffs.reduce(0) { $0 + (timings[$1.toolUseID]?.waiting(now: now) ?? 0) },
                handoffs.reduce(0) { $0 + ($1.tokens ?? 0) }, handoffs.reduce(0) { $0 + $1.toolCallCount })
    }

    var isOnPlan: Bool { StatusFormat.isOnPlan(state.rateLimit, configDirectory: configDirectory) }

    func dollars(_ amount: Double) -> String { StatusFormat.dollars(amount, onPlan: isOnPlan) }

    static var configDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names.filter { $0.hasPrefix(".claude-") }.sorted()
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".claude.json").path) }
    }

    private static var cliOverride: URL? {
        (launchArgument("-cli") ?? Preferences.shared.cliPath).map { URL(fileURLWithPath: $0) }
    }

    var primaryModels: [ModelOption] {
        Array((kit?.models ?? []).filter { $0.value != "default" }.prefix(4))
    }

    var otherModels: [ModelOption] {
        Array((kit?.models ?? []).filter { $0.value != "default" }.dropFirst(4))
    }

    func modelName(_ value: String?) -> String {
        guard let value else { return "Default" }
        return kit?.models.first { $0.value == value }?.displayName ?? value.capitalized
    }

    func refreshCatalogue() {
        catalogueNames = workingDirectory.map { AgentCatalogue.load(workingDirectory: $0).map(\.name) } ?? []
    }

    func checkReadiness() {
        let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        guard let executable = Self.cliOverride ?? ClaudeEnvironment.locateCLI(environment: environment),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            readiness = .cliMissing
            return
        }
        if readiness != .ready { readiness = .checking }
        Task {
            if let version = await ClaudeEnvironment.version(executable: executable, environment: environment),
               !ClaudeEnvironment.isSupported(version) {
                readiness = .cliOutdated(version.map(String.init).joined(separator: "."))
                return
            }
            let loggedIn = await ClaudeEnvironment.isLoggedIn(executable: executable, environment: environment)
            readiness = loggedIn == false ? .notLoggedIn : .ready
        }
    }

    func signIn() { Self.signIn(configDirectory: configDirectory) }

    /// The inventory run costs nothing, so Settings can list models before any floor exists.
    static func models(configDirectory: URL?) async -> [ModelOption] {
        let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        guard let executable = cliOverride ?? ClaudeEnvironment.locateCLI(environment: environment) else { return [] }
        let kit = await KitLoader.load(executable: executable, environment: environment, workingDirectory: FileManager.default.homeDirectoryForCurrentUser)
        return Array(kit.models.filter { $0.value != "default" }.prefix(4))
    }

    static func signIn(configDirectory: URL?) {
        let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        guard let executable = cliOverride ?? ClaudeEnvironment.locateCLI(environment: environment) else { return }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("The City sign-in.command")
        let config = configDirectory.map { "export CLAUDE_CONFIG_DIR=\(shellQuoted($0.path))\n" } ?? ""
        let body = "#!/bin/zsh\n\(config)\(shellQuoted(executable.path)) auth login\necho\necho 'You can close this window and return to The City.'\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func clearLimitNoticeIfExpired() {
        if let resets = limitNotice?.resetsAt, resets < .now { limitNotice = nil }
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func launchArgument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static var defaultWorkspace: URL? {
        launchArgument("-workspace").map { URL(fileURLWithPath: $0) }
    }

    func colour(for room: String) -> NSColor {
        if room == "manager" { return Palette.manager }
        if let index = catalogueNames.firstIndex(of: room) { return Palette.accent(forCatalogueIndex: index) }
        return Palette.muted
    }

    func displayName(_ room: String) -> String {
        if room == "manager" { return "The manager" }
        if room == "contractor" || !catalogueNames.contains(room) { return "Contractor" }
        return room.capitalized
    }

    // MARK: Hiring

    func beginHiring() {
        guard let workingDirectory, !request.isEmpty else { return }
        screen = .hiring
        askReceptionist(workingDirectory: workingDirectory)
    }

    func pickTeamYourself() {
        guard let workingDirectory else { return }
        let catalogue = AgentCatalogue.load(workingDirectory: workingDirectory)
        catalogueNames = catalogue.map(\.name)
        candidates = catalogue.map { Candidate(department: $0, reason: nil, hired: false) }
        hiringNote = catalogue.isEmpty ? "No departments found in \(workingDirectory.lastPathComponent)/.claude/agents." : nil
        screen = .hiring
    }

    func askAgain() {
        guard let workingDirectory, !isHiring else { return }
        askReceptionist(workingDirectory: workingDirectory)
    }

    func move(_ id: String, before target: String) {
        guard id != target, let from = candidates.firstIndex(where: { $0.id == id }) else { return }
        let moving = candidates.remove(at: from)
        let to = candidates.firstIndex(where: { $0.id == target }) ?? candidates.endIndex
        candidates.insert(moving, at: to)
    }

    private func askReceptionist(workingDirectory: URL) {
        isHiring = true
        hiringNote = nil
        let catalogue = AgentCatalogue.load(workingDirectory: workingDirectory)
        catalogueNames = catalogue.map(\.name)
        hiringIsSlow = false
        Task {
            try? await Task.sleep(for: .seconds(3))
            if isHiring { hiringIsSlow = true }
        }
        candidates = catalogue.map { Candidate(department: $0, reason: nil, hired: false) }
        guard !catalogue.isEmpty else {
            isHiring = false
            hiringNote = "No departments found in \(workingDirectory.lastPathComponent)/.claude/agents. Add agent files there to hire them."
            if opensWhenHired { CityStore.shared.headlessHiringDone(self) }
            return
        }
        let request = request
        let kitTask = kitTask
        Task {
            let kit = await Self.value(of: kitTask, within: .seconds(3)) ?? self.kit
            var outcome = await HiringDesk.propose(request: request, catalogue: catalogue, kit: kit)
            if let preset = pendingPreset { outcome = HiringDesk.staff(outcome, with: preset, catalogue: catalogue) }
            guard screen == .hiring else { return }
            switch outcome {
            case .proposed(let proposed, let kitPlan):
                candidates = proposed
                if !proposed.contains(where: \.hired) { hiringNote = "The receptionist didn’t think any department was needed. Pick some yourself." }
                if let kit, let kitPlan {
                    allowedServers = kitPlan.servers
                    allowedSkills = kitPlan.skills
                    kitReasons = kitPlan.reasons
                    self.kit = kit
                }
            case .unavailable(let note, let everyone):
                candidates = everyone
                hiringNote = note
            }
            isHiring = false
            if opensWhenHired { CityStore.shared.headlessHiringDone(self) }
        }
    }

    private static func value(of task: Task<Kit?, Never>?, within limit: Duration) async -> Kit? {
        guard let task else { return nil }
        return await withTaskGroup(of: Kit?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func moveUp(_ candidate: Candidate) {
        guard let index = candidates.firstIndex(of: candidate), index > 0 else { return }
        candidates.swapAt(index, index - 1)
    }

    func moveDown(_ candidate: Candidate) {
        guard let index = candidates.firstIndex(of: candidate), index < candidates.count - 1 else { return }
        candidates.swapAt(index, index + 1)
    }

    func toggle(_ candidate: Candidate) {
        guard let index = candidates.firstIndex(of: candidate) else { return }
        candidates[index].hired.toggle()
    }

    func backToReception() {
        guard !isRunning else { return }
        screen = .reception
    }

    func openOffice() {
        hired = candidates.filter(\.hired).map(\.department)
        screen = .office
        jobFiles = []
        followUps = []
        currentJob = nil
        resumeSession = nil
        selectedRoom = nil
        panelTab = .requests
        buildScene()
        if floorID == nil { floorID = CityStore.shared.floorOpened(self) }
        guard floorID != nil || !opensWhenHired else { return }
        start(message: request, resume: nil)
    }

    /// A job that arrives while the floor is busy waits its turn.
    func queue(_ text: String, continuing: Bool = false) {
        queued.append((text, continuing))
        appLog("Queued \(continuing ? "follow-up" : "job") for when this floor is free: \(text)")
    }

    /// A fresh job for this floor's existing team.
    func newJobOnFloor(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty else { return }
        guard !kiosk.isAlive else { return queue(text) }
        request = text
        jobFiles = []
        followUps = []
        currentJob = nil
        start(message: text, resume: nil)
    }

    var recordLine: String? {
        let journal = CityStore.shared.journal
        guard case .ended(.completed) = state.phase, let job = journal.last(where: { $0.id == currentJob }) else { return nil }
        let earlier = journal.filter { $0.id != job.id && $0.workingDirectory == job.workingDirectory && $0.outcome == "completed" }
        if earlier.count >= 2, earlier.allSatisfy({ $0.duration > job.duration }) {
            return "Fastest job in \(job.folderName) yet: \(Self.clock(job.duration))"
        }
        if let cost = job.costUSD, job.budgetUSD - cost >= 0.01 {
            return "Under budget by \((job.budgetUSD - cost).formatted(.currency(code: "USD")))"
        }
        return nil
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func spoken(_ seconds: TimeInterval) -> String {
        spokenFormatter.string(from: seconds.rounded()) ?? clock(seconds)
    }

    private static let spokenFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    private func recordJob(_ outcome: RunOutcome) {
        guard let workingDirectory else { return }
        let runCost = state.tally.costUSD ?? 0
        let runTokens = state.tally.total
        let runTime = (endedAt ?? .now).timeIntervalSince(startedAt ?? .now)
        let label: String = switch outcome {
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
        CityStore.shared.jobEnded(on: floorID, in: buildingID, sessionID: state.sessionID, outcome: label)
        let job = currentJob ?? UUID()
        let files = jobFiles
        let session = state.sessionID
        let (request, hires, budget, buildingID, floorID) = (request, hired.map(\.name), budgetUSD, buildingID, floorID)
        currentJob = job
        defer { CityStore.shared.sessions.values.filter { $0.buildingID == buildingID }.forEach { $0.showRecords() } }
        let previous = CityStore.shared.journal.last { $0.id == job }
        CityStore.shared.addToTotals(floor: floorID) {
            $0.add(isNew: previous == nil, outcome: label, replacing: previous?.outcome, costUSD: runCost, tokens: runTokens, duration: runTime)
        }
        CityStore.shared.record { journal in
            if let index = journal.firstIndex(where: { $0.id == job }) {
                journal[index].costUSD = (journal[index].costUSD ?? 0) + runCost
                journal[index].tokens = (journal[index].tokens ?? 0) + runTokens
                journal[index].duration += runTime
                journal[index].files = files
                journal[index].sessionID = session ?? journal[index].sessionID
                journal[index].outcome = label
                journal[index].date = .now
                journal.append(journal.remove(at: index))
            } else {
                journal.append(JobRecord(id: job, date: .now, request: request, workingDirectory: workingDirectory.path,
                                         hires: hires, costUSD: runCost, budgetUSD: budget, duration: runTime,
                                         files: files, sessionID: session, outcome: label, buildingID: buildingID, floorID: floorID,
                                         tokens: runTokens))
            }
        }
    }

    var canContinue: Bool { (state.sessionID ?? resumeSession) != nil }

    func tryAgain() {
        if let last = followUps.last, canContinue {
            followUps.removeLast()
            followUp(last)
        } else {
            newJobOnFloor(request)
        }
    }

    func followUp(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty, let session = state.sessionID ?? resumeSession else { return }
        guard !kiosk.isAlive else { return queue(text, continuing: true) }
        followUps.append(text)
        start(message: text, resume: session)
    }

    var canTakeOver: Bool { kiosk.isAlive || (!isRunning && !isDemo && workingDirectory != nil) }

    /// Opens the kiosk's terminal, starting `claude` on this floor's session if it isn't already running there.
    func takeOver() {
        guard canTakeOver, let workingDirectory else { return }
        if !kiosk.isAlive {
            let resume = state.sessionID ?? resumeSession
            kiosk.start(directory: workingDirectory, resume: resume, model: model, configDirectory: configDirectory) { [weak self] in self?.kioskEnded() }
            scene.setKioskLive(true)
            appLog(resume.map { "Terminal opened on session \($0)" } ?? "Terminal opened")
        }
        selectedRoom = nil
        kiosk.isOpen = true
    }

    private func kioskEnded() {
        scene.setKioskLive(false)
        appLog("Terminal session ended")
        guard !queued.isEmpty else { return }
        let next = queued.removeFirst()
        if next.continues { followUp(next.text) } else { newJobOnFloor(next.text) }
    }

    // MARK: Running

    var isDemo: Bool { workingDirectory?.path.hasPrefix(Bundle.main.bundlePath) == true }

    private func start(message request: String, resume: String?) {
        guard !isRunning, let workingDirectory else { return }
        isReplay = false
        reset(keepLog: resume != nil)
        guard !isDemo else {
            send(.launchFailed(.couldNotStart("The demo only replays a recording. Break ground on one of your own projects to run a real job.")))
            return
        }
        CityStore.shared.jobStarted(on: floorID, in: buildingID, request: request)
        remember(resume == nil ? .request : .followUp, request)
        if let resume { appLog("Follow-up in session \(resume): \(request)") }
        let config = RunConfig(
            request: request,
            workingDirectory: workingDirectory,
            claudeConfigDirectory: configDirectory,
            model: model,
            maxBudgetUSD: budgetUSD,
            appendSystemPrompt: hired.isEmpty ? nil : AgentCatalogue.hiringBrief(for: hired),
            agents: AgentCatalogue.agentsJSON(for: hired),
            resumeSessionID: resume,
            blockedTools: kit.map { Kit.blockRules(servers: $0.usableServers, allowedServers: allowedServers,
                                                   skills: $0.skills, allowedSkills: allowedSkills) } ?? [],
            permissionMode: permissionMode
        )
        let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        consumer = Task { [weak self] in
            guard let self else { return }
            guard let executable = Self.cliOverride ?? ClaudeEnvironment.locateCLI(environment: environment),
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                appLog(Self.cliOverride.map { "No executable at \($0.path)" } ?? "claude CLI not found on PATH or in \(ClaudeEnvironment.extraPaths.joined(separator: ", "))")
                return send(.launchFailed(.cliNotFound))
            }
            appLog("Using \(executable.path)")
            appLog("Checking login (claude auth status)…")
            if await ClaudeEnvironment.isLoggedIn(executable: executable, environment: environment) == false {
                appLog("Not logged in for config directory \(configDirectory?.path ?? "default")")
                return send(.launchFailed(.notLoggedIn))
            }
            guard !Task.isCancelled else { return }
            do {
                let process = try ClaudeProcess(
                    executable: executable,
                    arguments: config.arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    keepInputOpen: true
                )
                self.process = process
                appLog("Launched in \(workingDirectory.path)")
                if let brief = config.appendSystemPrompt { appLog("Hiring brief: \(brief)") }
                appLog("Permission mode: \(config.permissionMode.title)")
                if !config.blockedTools.isEmpty { appLog("Blocked for this job: \(config.blockedTools.joined(separator: ", "))") }
                send(.launched)
                write(ControlMessage.initialize(), note: "initialize")
                write(ControlMessage.userMessage(request), note: "request")
                await consume(process.output)
            } catch {
                appLog("Launch failed: \(error.localizedDescription)")
                send(.launchFailed(.couldNotStart(error.localizedDescription)))
            }
        }
    }

    /// The README reels render in simulated time, so they swap this for their own clock.
    static var now: () -> Date = { .now }

    /// A job the README reels drive one wire line at a time, with no `claude` process. A nil `dark` keeps a floor already shown in a building.
    func beginScript(servers: [McpServer], dark: Bool?) {
        kit = Kit(servers: servers)
        allowedServers = Set(servers.map(\.name))
        screen = .office
        jobFiles = []
        followUps = []
        if let dark { buildScene(dark: dark) }
        readiness = .ready
        reset(keepLog: false)
        isReplay = true
        send(.launched)
    }

    func endScript() { send(.processExited(code: 0, stderr: "")) }

    func feed(_ raw: String) {
        guard case .event(let event) = StreamParser.parse(raw, index: log.count).parsed else { return }
        send(.wire(event))
    }

    func replay(_ url: URL) {
        guard !isRunning else { return }
        if hired.isEmpty, let workingDirectory { hired = AgentCatalogue.load(workingDirectory: workingDirectory) }
        screen = .office
        jobFiles = []
        followUps = []
        buildScene()
        reset(keepLog: false)
        do {
            isReplay = true
            let stream = try FixtureReplay.stream(contentsOf: url, workingDirectory: workingDirectory)
            appLog("Replaying \(url.lastPathComponent)")
            send(.launched)
            consumer = Task { [weak self] in await self?.consume(stream) }
        } catch {
            appLog("Could not read \(url.path): \(error.localizedDescription)")
        }
    }

    func cancel() {
        guard isRunning else { return }
        appLog("Cancel requested (SIGINT)")
        send(.cancelRequested)
        if let process {
            process.closeInput()
            process.cancel()
        } else {
            consumer?.cancel()
            send(.processExited(code: 0, stderr: ""))
        }
    }

    func newJob() {
        guard !isRunning else { return }
        reset(keepLog: false)
        clearLimitNoticeIfExpired()
    }

    var isAccountFailure: Bool {
        guard case .ended(.failed(let reason, let message)) = state.phase else { return false }
        switch reason {
        case .cliNotFound, .notLoggedIn: return true
        case .runError: return (message ?? "").localizedCaseInsensitiveContains("limit")
        default: return false
        }
    }

    func select(room: String) {
        selectedRoom = room
        showPanel = true
        panelTab = state.pendingRequests.contains { $0.room == room } ? .requests : .room
    }

    func shutDown() async {
        guard isRunning else { return }
        cancel()
        for _ in 0..<60 where isRunning { try? await Task.sleep(for: .milliseconds(100)) }
    }

    // MARK: Questions and approvals

    func answer(_ pending: PendingRequest, answers: [String: String]) {
        write(ControlMessage.answer(pending.request, answers: answers), note: "answered \(answers.values.joined(separator: " / "))")
        send(.requestResolved(requestID: pending.id))
    }

    func allow(_ pending: PendingRequest, always: Bool = false) {
        let note = always ? "always allowed \(pending.request.suggestedRules.joined(separator: ", "))" : "allowed \(pending.request.toolName)"
        write(ControlMessage.allow(pending.request, always: always), note: note)
        send(.requestResolved(requestID: pending.id))
    }

    func setPermissionMode(_ mode: PermissionMode) {
        guard mode != permissionMode else { return }
        permissionMode = mode
        if isRunning { write(ControlMessage.setPermissionMode(mode), note: "permission mode \(mode.title)") }
    }

    func allowAndSwitchToAuto(_ pending: PendingRequest) {
        setPermissionMode(.auto)
        allow(pending)
    }

    func deny(_ pending: PendingRequest) {
        write(ControlMessage.deny(pending.request, message: "The user denied this in The City."), note: "denied \(pending.request.toolName)")
        send(.requestResolved(requestID: pending.id))
    }

    private func write(_ line: Data, note: String) {
        let sent = process?.send(line) ?? false
        log.append(LogEntry(elapsed: sinceStart, kind: .sent, text: sent ? "→ \(note)" : "→ \(note) (not sent: no live process)"))
    }

    private func consume(_ stream: AsyncStream<RunnerOutput>) async {
        for await output in stream {
            switch output {
            case .line(let line):
                switch line.parsed {
                case .event(let event):
                    log.append(LogEntry(elapsed: sinceStart, kind: .event(Self.tag(for: event)), text: line.raw))
                    send(.wire(event))
                    if case .result = event { closeInputIfIdle() }
                case .malformed(let reason):
                    log.append(LogEntry(elapsed: sinceStart, kind: .malformed(reason), text: line.raw))
                }
            case .exited(let code, let stderr):
                appLog("Process exited with code \(code)")
                if !stderr.isEmpty { appLog("stderr: \(stderr)") }
                send(.processExited(code: code, stderr: stderr))
            }
        }
        process = nil
    }

    /// Background subagents start a fresh turn when they finish, so stdin stays open until nothing is outstanding.
    private func closeInputIfIdle() {
        guard let process, state.backgroundTasks == 0, state.pendingRequests.isEmpty else { return }
        appLog("Turn finished with nothing outstanding; closing input")
        process.closeInput()
    }

    private func send(_ input: RunInput) {
        let events = reducer.apply(input)
        // Every write to an observed property re-renders its readers, even an equal one, and this runs once per stream line.
        if state != reducer.state { state = reducer.state }
        // Replayed limits are old or made up, so they mustn't replace the account's saved reading.
        if case .wire(.rateLimit(let limit)) = input, !isReplay { UsageStore.shared.record(limit, configDirectory: configDirectory) }
        Attention.shared.waiting(state.pendingRequests.count)
        if case .ended = state.phase, endedAt == nil { endedAt = Self.now() }
        if state.contextWindows.contains(where: { contextWindows[$0.key] != $0.value }) { contextWindows.merge(state.contextWindows) { $1 } }
        track(events)
        for path in state.outputFiles where !jobFiles.contains(path) { jobFiles.append(path) }
        if !events.isEmpty { scene.apply(events) }
    }

    private func note(_ room: String, _ text: String) {
        activity.append(ActivityItem(room: room, text: text))
        if activity.count > 40 { activity.removeFirst(activity.count - 40) }
    }

    private func track(_ events: [OfficeEvent]) {
        for event in events {
            let name = { (room: String) in self.displayName(room) }
            switch event {
            case .handoff(_, let room, let description):
                note("manager", "The manager briefed \(name(room))\(description.map { ": \($0)" } ?? "")")
            case .roomActivity(let room, let tool, _):
                let last = state.handoffs(in: room).last?.tools.last?.summary.map { URL(fileURLWithPath: $0).lastPathComponent }
                note(room, "\(name(room)): \(Wording.verb(tool).lowercased())\(last.map { " \($0)" } ?? "")")
            case .roomFinished(_, let room, let outcome):
                note(room, outcome == .completed ? "\(name(room)) finished" : "\(name(room)) stopped")
            case .skillLoaded(let room, let skill):
                note(room, "\(name(room)) picked up the \(skill) skill")
            case .serviceCall(_, let room, let server, true):
                note(room, "\(name(room)) is calling \(OfficeScene.shortName(server))")
            default:
                break
            }
            switch event {
            case .handoff(_, let room, _):
                if !steps.contains(where: { $0.room == room }) {
                    steps.append(Step(room: room, colour: colour(for: room), isContractor: true))
                }
            case .roomStarted(let id, let room):
                timings[id, default: HandoffTiming()].startedAt = timings[id]?.startedAt ?? Self.now()
                guard let i = steps.firstIndex(where: { $0.room == room }) else { break }
                steps[i].status = .working
                steps[i].startedAt = steps[i].startedAt ?? Self.now()
            case .roomFinished(let id, let room, _):
                stopWaiting(id)
                timings[id]?.endedAt = Self.now()
                guard let i = steps.firstIndex(where: { $0.room == room }), let start = steps[i].startedAt else { break }
                steps[i].workedFor += Self.now().timeIntervalSince(start)
                steps[i].startedAt = nil
                steps[i].status = .done
            case .handRaised(let request, let room):
                if let id = workingHandoff(in: room), timings[id]?.waitingSince == nil { timings[id]?.waitingSince = Self.now() }
                panelTab = .requests
                if !isReplay { Attention.shared.needsInput(from: room, request: request, place: placeName, building: buildingID, floor: floorID) }
                let who = room == "manager" ? "The manager" : room.capitalized
                AccessibilityNotification.Announcement("\(who) needs you").post()
            case .handLowered(_, let room):
                if let id = workingHandoff(in: room), !state.pendingRequests.contains(where: { $0.room == room }) { stopWaiting(id) }
            case .runEnded(let outcome):
                if !isReplay { Attention.shared.finished(outcome, files: state.outputFiles, place: placeName, building: buildingID, floor: floorID) }
                noteLimit(outcome)
                if !isReplay {
                    recordJob(outcome)
                    remember(.outcome, title: Self.title(for: outcome), Self.message(for: outcome, budget: budgetUSD))
                }
                if !queued.isEmpty {
                    let next = queued.removeFirst()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        if next.continues { self?.followUp(next.text) } else { self?.newJobOnFloor(next.text) }
                    }
                }
            default:
                break
            }
        }
    }

    private func workingHandoff(in room: String) -> String? {
        state.handoffs(in: room).last { $0.phase == .working }?.toolUseID
    }

    private func stopWaiting(_ id: String) {
        guard let since = timings[id]?.waitingSince else { return }
        timings[id]?.waited += Self.now().timeIntervalSince(since)
        timings[id]?.waitingSince = nil
    }

    private func noteLimit(_ outcome: RunOutcome) {
        let rejected = state.rateLimit?.isRejected == true
        guard case .failed(let reason, let message) = outcome else { return }
        switch reason {
        case .notLoggedIn: readiness = .notLoggedIn
        case .cliNotFound: readiness = .cliMissing
        case .runError where rejected || (message ?? "").localizedCaseInsensitiveContains("limit"):
            let text = message ?? "Your Claude plan’s limit is reached."
            let url = (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue))?
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
            limitNotice = LimitNotice(message: text, url: url, resetsAt: rejected ? state.rateLimit?.resetsAt : nil)
        default: break
        }
    }

    private func remember(_ kind: HistoryEntry.Kind, title: String? = nil, _ text: String) {
        guard let floorID, !isReplay, !isDemo else { return }
        let job = kind == .request ? UUID() : history.last?.job ?? UUID()
        history.append(HistoryEntry(date: .now, job: job, kind: kind, title: title, text: text))
        FloorHistory.save(history, for: floorID)
    }

    static func title(for outcome: RunOutcome) -> String {
        switch outcome {
        case .completed: "Delivered"
        case .cancelled: "Cancelled"
        case .failed(.budgetExhausted, _): "Budget reached"
        case .failed: "The job stopped"
        }
    }

    static func message(for outcome: RunOutcome, budget: Double) -> String {
        switch outcome {
        case .completed(let summary, _): summary ?? "Done."
        case .cancelled: "You cancelled the job. You can still send a follow-up to pick it up again."
        case .failed(.cliNotFound, _): "Claude Code isn’t installed. Install or locate it below, then try again."
        case .failed(.notLoggedIn, _): "You’re not signed in to Claude Code with this account. Sign in below, then try again."
        case .failed(.budgetExhausted, _): "The job reached its \(budget.formatted(.currency(code: "USD"))) budget."
        case .failed(.runError, let message): message ?? "The job stopped unexpectedly."
        case .failed(.processCrashed(let code), let message): "Claude Code stopped without finishing (exit \(code)). \(message ?? "")"
        case .failed(.couldNotStart, let message): "Claude Code couldn’t start: \(message ?? "")"
        }
    }

    private func reset(keepLog: Bool) {
        reducer = OfficeReducer()
        state = reducer.state
        if !keepLog { log = [] }
        steps = hired.map { Step(room: $0.name, colour: colour(for: $0.name), isContractor: false) }
        activity = []
        timings = [:]
        startedAt = Self.now()
        endedAt = nil
        process = nil
        consumer = nil
        scene.apply([])
    }

    private func appLog(_ text: String) {
        log.append(LogEntry(elapsed: sinceStart, kind: .app, text: text))
    }

    private var sinceStart: TimeInterval { startedAt.map { Self.now().timeIntervalSince($0) } ?? 0 }

    private static func tag(for event: WireEvent) -> String {
        switch event {
        case .sessionStarted: "system/init"
        case .assistant(let m): m.parentToolUseID == nil ? "assistant" : "assistant (subagent)"
        case .user(let m): m.parentToolUseID == nil ? "user" : "user (subagent)"
        case .taskStarted: "system/task_started"
        case .taskProgress: "system/task_progress"
        case .taskUpdated: "system/task_updated"
        case .taskNotification: "system/task_notification"
        case .thinkingTokens: "system/thinking_tokens"
        case .backgroundTasksChanged: "system/background_tasks_changed"
        case .permissionRequest(let r): "control_request/can_use_tool (\(McpNaming.friendly(r.toolName, servers: [])))"
        case .controlResponse: "control_response"
        case .rateLimit: "rate_limit_event"
        case .result: "result"
        case .unknown(let type, let subtype): "\(type)/\(subtype ?? "-") (unknown)"
        }
    }
}
