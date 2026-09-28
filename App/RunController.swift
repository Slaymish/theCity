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

/// A request that arrived while its floor was busy, kept with the floor so quitting doesn't lose it.
struct QueuedJob: Codable, Equatable {
    var text: String
    var continues: Bool
    var place: JobPlace?
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
    var pendingPlace: JobPlace?
    private(set) var queued: [QueuedJob] = [] {
        didSet {
            guard let floorID, let buildingID, queued != oldValue else { return }
            CityStore.shared.update(floor: floorID, in: buildingID) { $0.queued = queued.isEmpty ? nil : queued }
        }
    }
    /// Set when a job doesn't finish, so a cancel or a spent limit doesn't set the rest of the queue off one by one.
    private(set) var queueHeld = false
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
    var receptionNote: String {
        Preferences.shared.receptionist == .claude ? "The receptionist is asking Claude Haiku about your request…" : "The receptionist is reading your request on this Mac…"
    }
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
    /// Follow-ups keep the log, so a long-lived floor would otherwise hold every raw line it has ever streamed.
    private(set) var log: [LogEntry] = [] {
        didSet { if log.count > Self.logLimit + 1000 { log.removeFirst(log.count - Self.logLimit) } }
    }
    static let logLimit = 5000
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    private(set) var jobFiles: [String] = []
    private(set) var followUps: [String] = []
    private(set) var history: [HistoryEntry] = []
    var showHistory = false
    private(set) var resumeSession: String?
    /// A session the terminal worked in, which follow-ups continue until the floor's next job starts.
    private(set) var terminalSession: String?
    @ObservationIgnored private var terminalOpened: (session: String, directory: URL, date: Date, fresh: Bool)?
    /// Where this floor's session runs, which may be a worktree; follow-ups must resume there.
    private(set) var jobDirectory: URL?
    private(set) var branch: String?
    /// The checkout root this floor's job or terminal works in, so another floor doesn't start there unasked.
    private(set) var checkout: String?
    /// A job held back because another floor is already working in its checkout.
    private(set) var clash: Clash?
    @ObservationIgnored private var clashAnswer: CheckedContinuation<Clash.Choice, Never>?
    private(set) var currentJob: UUID?
    private(set) var timings: [String: HandoffTiming] = [:]
    /// What the companion app needs beyond `state`: captions, last tools and service calls in flight.
    private(set) var mirror = FloorMirror()
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
        jobDirectory = floor.jobDirectory.map { URL(fileURLWithPath: $0) }
        branch = floor.branch
        queued = floor.queued ?? []
        queueHeld = !queued.isEmpty
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

    /// The last kit read for each folder and account; listing it takes `claude` seconds, so a floor starts from this and refreshes behind it.
    private static var kitCache: [String: Kit] = [:]

    static func cachedKit(for workingDirectory: URL, configDirectory: URL?) -> Kit? {
        kitCache["\(workingDirectory.path)|\(configDirectory?.path ?? "")"]
    }

    static func cacheKit(_ kit: Kit, for workingDirectory: URL, configDirectory: URL?) {
        kitCache["\(workingDirectory.path)|\(configDirectory?.path ?? "")"] = kit
    }

    func loadKit() {
        guard let workingDirectory, let load = Self.kitLoader(for: workingDirectory, configDirectory: configDirectory) else { return }
        kitTask?.cancel()
        let configDirectory = configDirectory
        if let cached = Self.cachedKit(for: workingDirectory, configDirectory: configDirectory), cached != kit { useKit(cached) }
        isLoadingKit = kit == nil
        let task = Task { () -> Kit? in
            let loaded = await load()
            guard !Task.isCancelled else { return nil }
            Self.cacheKit(loaded, for: workingDirectory, configDirectory: configDirectory)
            return loaded
        }
        kitTask = task
        Task {
            guard let loaded = await task.value else { return }
            isLoadingKit = false
            // A refresh that changes nothing mustn't undo the services and skills hiring just picked.
            if loaded != kit { useKit(loaded) }
        }
    }

    private func useKit(_ loaded: Kit) {
        kit = loaded
        let floor = floorID.flatMap { id in buildingID.flatMap { CityStore.shared.floor(id, in: $0) } }
        allowedServers = floor?.allowedServers.map(Set.init) ?? Set(loaded.usableServers.map(\.name))
        allowedSkills = floor?.allowedSkills.map(Set.init) ?? Set(loaded.skills.map(\.name))
        kitReasons = [:]
        let servers = loaded.usableServers.filter { allowedServers.contains($0.name) }
        guard screen == .office && !isRunning else { return }
        let names = servers.map(\.name), dark = Preferences.shared.isDark
        guard let builtFor, builtFor.hires == hired.map(\.name), builtFor.dark == dark else { return buildScene() }
        guard builtFor.servers != names else { return }
        scene.setServers(servers)
        self.builtFor = (builtFor.hires, names, dark)
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

    static func kitLoader(for workingDirectory: URL, configDirectory: URL?) -> (@Sendable () async -> Kit)? {
        let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        guard let executable = cliOverride ?? ClaudeEnvironment.locateCLI(environment: environment) else { return nil }
        return { await KitLoader.load(executable: executable, environment: environment, workingDirectory: workingDirectory) }
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

    /// Waits for a readiness check in progress to finish, giving up after 30 seconds.
    func settledReadiness() async -> Readiness {
        var waited = 0
        while readiness == .checking, waited < 300 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        return readiness
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

    static func launchArgument(_ name: String) -> String? { LaunchArgument.value(name) }

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
            let kit = if let kit = self.kit { kit } else { await Self.value(of: kitTask, within: .seconds(3)) }
            let slash = SlashCommand.parse(request, commands: kit?.commands ?? [])
            let brief = slash.map { [$0.command.description, $0.arguments].filter { !$0.isEmpty }.joined(separator: ": ") } ?? request
            var outcome = await HiringDesk.propose(request: brief, catalogue: catalogue, kit: kit, configDirectory: configDirectory)
            if let preset = pendingPreset { outcome = HiringDesk.staff(outcome, with: preset, catalogue: catalogue) }
            guard screen == .hiring else { return }
            switch outcome {
            case .proposed(let proposed, let kitPlan):
                candidates = proposed
                if !proposed.contains(where: \.hired) { hiringNote = "The receptionist didn’t think any department was needed. Pick some yourself." }
                if let kit, let kitPlan {
                    allowedServers = kitPlan.servers
                    allowedSkills = kitPlan.skills
                    if let slash, kit.skills.contains(where: { $0.name == slash.command.name }) { allowedSkills.insert(slash.command.name) }
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
        start(message: request, resume: nil, place: pendingPlace)
    }

    /// A job that arrives while the floor is busy waits its turn.
    func queue(_ text: String, continuing: Bool = false, place: JobPlace? = nil) {
        queued.append(QueuedJob(text: text, continues: continuing, place: place))
        appLog("Queued \(continuing ? "follow-up" : "job") for when this floor is free: \(text)")
    }

    func resumeQueue() {
        queueHeld = false
        startNextQueued()
    }

    func discardQueue() {
        appLog("Discarded \(queued.count) queued job\(queued.count == 1 ? "" : "s")")
        queued = []
        queueHeld = false
    }

    /// The next job waits until the floor is free; if it's busy again by then, that job's end starts it instead.
    private func startNextQueued() {
        guard !queued.isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !queueHeld, !isRunning, !kiosk.isAlive, !queued.isEmpty else { return }
            let next = queued.removeFirst()
            if next.continues, canContinue { followUp(next.text) } else { newJobOnFloor(next.text, place: next.place) }
        }
    }

    /// A fresh job for this floor's existing team.
    func newJobOnFloor(_ text: String, place: JobPlace? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty else { return }
        guard !kiosk.isAlive else { return queue(text, place: place) }
        request = text
        jobFiles = []
        followUps = []
        currentJob = nil
        start(message: text, resume: nil, place: place)
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

    static func clock(_ seconds: TimeInterval) -> String { Wording.clock(seconds) }

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

    var canContinue: Bool { sessionToContinue != nil }

    private var sessionToContinue: String? { terminalSession ?? state.sessionID ?? resumeSession }

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
        guard !isRunning, !text.isEmpty, let session = sessionToContinue else { return }
        guard !kiosk.isAlive else { return queue(text, continuing: true) }
        followUps.append(text)
        start(message: text, resume: session, place: nil)
    }

    var canTakeOver: Bool { kiosk.isAlive || (!isRunning && !isDemo && workingDirectory != nil) }

    /// Opens the kiosk's terminal, starting `claude` on this floor's session if it isn't already running there.
    func takeOver() {
        guard canTakeOver, let workingDirectory else { return }
        if !kiosk.isAlive {
            let resume = jobDirectoryIsGone ? nil : sessionToContinue
            let directory = resume == nil ? workingDirectory : jobDirectory ?? workingDirectory
            // A fresh session gets its ID up front, since the terminal never reports it.
            let session = resume ?? UUID().uuidString.lowercased()
            kiosk.start(directory: directory, resume: resume, sessionID: resume == nil ? session : nil, model: model,
                        configDirectory: configDirectory) { [weak self] in self?.kioskEnded() }
            terminalOpened = (session, directory, .now, resume == nil)
            scene.setKioskLive(true)
            Task { checkout = await Self.checkout(of: directory) }
            if jobDirectoryIsGone { appLog("The last job’s worktree is gone, so the terminal starts a fresh session") }
            appLog(resume.map { "Terminal opened on session \($0)" } ?? "Terminal opened")
        }
        selectedRoom = nil
        kiosk.isOpen = true
    }

    private func kioskEnded() {
        scene.setKioskLive(false)
        appLog("Terminal session ended")
        guard let opened = terminalOpened else {
            if !queueHeld { startNextQueued() }
            return
        }
        terminalOpened = nil
        let configDirectory = configDirectory
        Task {
            let turns = await Task.detached {
                guard let file = SessionTranscript.file(for: opened.session, configDirectory: configDirectory),
                      let data = try? Data(contentsOf: file) else { return [SessionTranscript.Turn]() }
                return SessionTranscript.turns(in: data, since: opened.date)
            }.value
            if !turns.isEmpty { adoptTerminalWork(turns, session: opened.session, directory: opened.directory, fresh: opened.fresh) }
            if !queueHeld { startNextQueued() }
        }
    }

    private func adoptTerminalWork(_ turns: [SessionTranscript.Turn], session: String, directory: URL, fresh: Bool) {
        terminalSession = session
        resumeSession = session
        if let floorID, let buildingID { CityStore.shared.update(floor: floorID, in: buildingID) { $0.sessionID = session } }
        if fresh { settle(in: directory) }
        appLog("Follow-ups continue the terminal’s session \(session)")
        for (index, turn) in turns.enumerated() {
            let starts = fresh && index == 0
            remember(starts ? .request : .followUp, title: starts ? "New job in the terminal" : "Follow-up in the terminal", turn.prompt, date: turn.date)
        }
        if let reply = turns.last?.reply { remember(.outcome, title: "Terminal reply", reply, date: turns.last?.date ?? .now) }
    }

    // MARK: Running

    var isDemo: Bool { workingDirectory?.path.hasPrefix(Bundle.main.bundlePath) == true }

    private func start(message request: String, resume: String?, place: JobPlace?) {
        guard !isRunning, let workingDirectory else { return }
        isReplay = false
        reset(keepLog: resume != nil)
        guard !isDemo else {
            send(.launchFailed(.couldNotStart("The demo only replays a recording. Break ground on one of your own projects to run a real job.")))
            return
        }
        if resume != nil, jobDirectoryIsGone, let jobDirectory {
            send(.launchFailed(.couldNotStart("The worktree this floor’s last job ran in (\(jobDirectory.path)) is gone, so a follow-up can’t pick it up. Start a new job instead.")))
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
        let makesWorktree = resume == nil && place == .newWorktree
        let lastDirectory = jobDirectoryIsGone ? nil : jobDirectory
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
            var config = config
            do {
                var directory: URL = switch (resume, place) {
                case (.some, _), (nil, nil): lastDirectory ?? workingDirectory
                case (nil, .newWorktree): workingDirectory
                case (nil, .branch(let branch)): try await Git.directory(for: branch, in: workingDirectory)
                }
                if makesWorktree {
                    checkout = nil
                    config.worktreeName = try await Git.freshWorktreeName(displayTitle, in: workingDirectory)
                } else {
                    guard let claimed = try await claimCheckout(directory, resuming: resume != nil) else { return }
                    directory = claimed
                }
                guard !Task.isCancelled else { return }
                config.workingDirectory = directory
                let process = try ClaudeProcess(
                    executable: executable,
                    arguments: config.arguments,
                    environment: environment,
                    workingDirectory: directory,
                    keepInputOpen: true
                )
                self.process = process
                appLog("Launched in \(directory.path)\(config.worktreeName.map { " (Claude makes worktree \($0))" } ?? "")")
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
        answerClash(.cancel)
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
        if case .wire(.sessionStarted(let info)) = input, !isReplay, let cwd = info.cwd { settle(in: URL(fileURLWithPath: cwd)) }
        CityStore.shared.refreshBadge()
        if case .ended = state.phase, endedAt == nil {
            endedAt = Self.now()
            if !isReplay, let jobDirectory, !jobDirectoryIsGone { settle(in: jobDirectory) }
        }
        if state.contextWindows.contains(where: { contextWindows[$0.key] != $0.value }) { contextWindows.merge(state.contextWindows) { $1 } }
        track(events)
        var mirrored = mirror
        mirrored.record(events)
        if mirrored != mirror { mirror = mirrored }
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
                    if Self.sessionIsGone(outcome) { forgetSession() }
                    recordJob(outcome)
                    if case .cancelled = outcome {} else { CityStore.shared.resultReady(on: floorID, in: buildingID) }
                    remember(.outcome, title: Self.title(for: outcome), Self.message(for: outcome, budget: budgetUSD))
                }
                if case .completed = outcome, !queueHeld {
                    startNextQueued()
                } else if !queued.isEmpty, !queueHeld {
                    queueHeld = true
                    appLog("Holding \(queued.count) queued job\(queued.count == 1 ? "" : "s") because this one didn’t finish")
                }
            default:
                break
            }
        }
    }

    /// `init` reports where the session really runs, including a worktree `claude --worktree` just made.
    private func settle(in directory: URL) {
        jobDirectory = directory
        Task {
            let name = await Git.currentBranch(in: directory)
            let root = await Self.checkout(of: directory)
            guard jobDirectory == directory else { return }
            branch = name
            checkout = root
            guard let floorID, let buildingID else { return }
            CityStore.shared.update(floor: floorID, in: buildingID) {
                $0.jobDirectory = directory.path
                $0.branch = name
            }
        }
    }

    struct Clash: Identifiable {
        enum Choice { case worktree, share, cancel }
        let id = UUID()
        var folder: String
        var holder: String
        /// What a new worktree would start from; nil for a follow-up, which has to resume where its session ran.
        var base: String?
    }

    private var jobDirectoryIsGone: Bool {
        jobDirectory.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private var isWatched: Bool {
        guard NSApp.isActive, MainWindow.shared.isOpen, let buildingID else { return false }
        let route = CityStore.shared.route
        return route == .newFloor(buildingID) || floorID.map { route == .floor(building: buildingID, floor: $0) } == true
    }

    private static func checkout(of directory: URL) async -> String {
        await Git.checkout(of: directory) ?? directory.resolvingSymlinksInPath().path
    }

    /// Where a job may run without sharing a checkout with another floor: a fresh worktree off it, or the same folder if the user says so.
    private func claimCheckout(_ directory: URL, resuming: Bool) async throws -> URL? {
        var directory = directory
        while true {
            let isRepo = await Git.checkout(of: directory) != nil
            let root = await Self.checkout(of: directory)
            guard let holder = CityStore.shared.sessions.values.first(where: {
                $0 !== self && $0.checkout == root && ($0.isRunning || $0.kiosk.isAlive)
            }) else {
                checkout = root
                return directory
            }
            let base = !resuming && isRepo ? try await Git.head(of: directory) : nil
            let clash = Clash(folder: URL(fileURLWithPath: root).lastPathComponent, holder: holder.displayTitle, base: base)
            let choice: Clash.Choice = base != nil && !isWatched ? .worktree : await withCheckedContinuation { continuation in
                clashAnswer = continuation
                self.clash = clash
            }
            switch choice {
            case .cancel:
                return nil
            case .share:
                appLog("Sharing \(root) with \(holder.displayTitle)")
                checkout = root
                return directory
            case .worktree:
                guard let base else { return nil }
                directory = try await Git.worktree(named: displayTitle, from: base, in: directory)
                appLog("\(holder.displayTitle) is working in \(root), so this job gets its own worktree off \(base) at \(directory.path)")
            }
        }
    }

    func answerClash(_ choice: Clash.Choice) {
        clash = nil
        clashAnswer?.resume(returning: choice)
        clashAnswer = nil
    }

    private func workingHandoff(in room: String) -> String? {
        state.handoffs(in: room).last { $0.phase == .working }?.toolUseID
    }

    private func stopWaiting(_ id: String) {
        guard let since = timings[id]?.waitingSince else { return }
        timings[id]?.waited += Self.now().timeIntervalSince(since)
        timings[id]?.waitingSince = nil
    }

    static func sessionIsGone(_ outcome: RunOutcome) -> Bool {
        guard case .failed(_, let message?) = outcome else { return false }
        return message.contains("No conversation found")
    }

    private func forgetSession() {
        resumeSession = nil
        terminalSession = nil
        guard let floorID, let buildingID else { return }
        CityStore.shared.update(floor: floorID, in: buildingID) { $0.sessionID = nil }
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

    private func remember(_ kind: HistoryEntry.Kind, title: String? = nil, _ text: String, date: Date = .now) {
        // A cancelled job can end after its floor is removed; don't write the history back.
        guard let floorID, let buildingID, !isReplay, !isDemo,
              CityStore.shared.floor(floorID, in: buildingID) != nil else { return }
        let job = kind == .request ? UUID() : history.last?.job ?? UUID()
        history.append(HistoryEntry(date: date, job: job, kind: kind, title: title, text: text))
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
        case .failed where sessionIsGone(outcome):
            "This floor’s last session is gone. Claude Code deletes old transcripts after a while, so it can’t be continued. Start a new job instead."
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
        terminalSession = nil
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
