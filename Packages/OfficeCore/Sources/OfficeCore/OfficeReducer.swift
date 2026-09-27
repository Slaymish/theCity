import Foundation

public enum RunInput: Sendable, Equatable {
    case launched
    case wire(WireEvent)
    case cancelRequested
    case requestResolved(requestID: String)
    case processExited(code: Int32, stderr: String)
    case launchFailed(LaunchFailure)
}

public enum LaunchFailure: Sendable, Equatable {
    case cliNotFound
    case notLoggedIn
    case couldNotStart(String)
}

public enum FailureReason: Sendable, Equatable {
    case cliNotFound
    case notLoggedIn
    case runError(terminalReason: String?)
    case processCrashed(code: Int32)
    case couldNotStart
    case budgetExhausted
}

public enum RunOutcome: Sendable, Equatable {
    case completed(summary: String?, costUSD: Double?)
    case cancelled(costUSD: Double?)
    case failed(FailureReason, message: String?)
}

public enum RoomOutcome: Sendable, Equatable {
    case completed
    case killed
    case failed(String)
}

public struct TokenTally: Sendable, Equatable {
    public var usage: TokenUsage = .zero
    public var estimatedThinking = 0
    /// Mid-stream output counts are partial; only the `result` totals are exact.
    public var isFinal = false
    public var costUSD: Double?

    public var total: Int { usage.total + (isFinal ? 0 : estimatedThinking) }
}

public enum OfficeEvent: Sendable, Equatable {
    case runStarted
    case managerActive(Bool)
    case handoff(toolUseID: String, room: String, description: String?)
    case roomStarted(toolUseID: String, room: String)
    case roomActivity(room: String, toolName: String, step: String?)
    case roomCaption(room: String, caption: String)
    case roomFinished(toolUseID: String, room: String, outcome: RoomOutcome)
    case handback(toolUseID: String, room: String, isError: Bool)
    case tallyChanged(TokenTally)
    case handRaised(PermissionRequest, room: String)
    case handLowered(requestID: String, room: String)
    case skillLoaded(room: String, skill: String)
    case serviceCall(callID: String, room: String, server: String, active: Bool)
    case runEnded(RunOutcome)
}

public struct ToolCall: Sendable, Equatable {
    public var name: String
    public var summary: String?

    static let fileWriters: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    init(name: String, input: JSONValue) {
        self.name = name
        summary = ["file_path", "notebook_path", "command", "pattern", "url", "query", "skill", "description"]
            .lazy.compactMap { input[$0]?.stringValue }.first
    }
}

public struct Handoff: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case requested, working, finished }
    public var toolUseID: String
    public var room: String
    public var taskID: String?
    public var phase: Phase
    public var isBackground = false
    public var handedBack = false
    public var brief: String?
    public var prompt: String?
    public var tools: [ToolCall] = []
    public var report: String?
    public var model: String?
    public var tokens: Int?
    public var toolUses: Int?
    /// What the room is doing now, such as "Reading README.md"; nil once it finishes.
    public var step: String?
    public var outcome: RoomOutcome?

    public var toolCallCount: Int { max(tools.count, toolUses ?? 0) }
}

public struct RoomCounts: Sendable, Equatable {
    public var working = 0
    public var idle = 0
    public var waiting = 0

    public init(working: Int = 0, idle: Int = 0, waiting: Int = 0) {
        self.working = working
        self.idle = idle
        self.waiting = waiting
    }

    public static func + (lhs: RoomCounts, rhs: RoomCounts) -> RoomCounts {
        RoomCounts(working: lhs.working + rhs.working, idle: lhs.idle + rhs.idle, waiting: lhs.waiting + rhs.waiting)
    }
}

public struct PendingRequest: Sendable, Equatable, Identifiable {
    public var id: String { request.requestID }
    public var request: PermissionRequest
    /// `manager` unless a subagent asked.
    public var room: String

    public init(request: PermissionRequest, room: String) {
        self.request = request
        self.room = room
    }
}

public struct OfficeState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, running, ended(RunOutcome) }

    public var phase: Phase = .idle
    public var managerActive = false
    /// Keyed by the `Agent` tool_use id; this, not the task id, is what every later event links back to.
    public var handoffs: [String: Handoff] = [:]
    public var tally = TokenTally()
    public var pendingRequests: [PendingRequest] = []
    public var backgroundTasks = 0
    public var sessionID: String?
    /// Files written or edited by any room, confirmed by a successful tool result, in first-touched order.
    public var outputFiles: [String] = []
    public var mcpServers: [McpServer] = []
    public var skillsByRoom: [String: [String]] = [:]
    public var serviceCallsByServer: [String: Int] = [:]
    public var rateLimit: RateLimit?
    /// Tokens in the manager's latest API message: its prompt plus its reply.
    public var contextTokens = 0
    public var mainModel: String?
    public var contextWindows: [String: Int] = [:]
    /// Live, one per API message in the main session, until a `result` gives the exact count.
    public var turns = 0
    /// Tokens are live; costs arrive only with a `result`.
    public var models: [String: ModelUsage] = [:]
    public var permissionDenials = 0
    public var subagentStats: SubagentStats?

    public func contextFraction(windows: [String: Int] = [:]) -> Double? {
        guard let model = mainModel, let window = contextWindows[model] ?? windows[model], window > 0 else { return nil }
        return Double(contextTokens) / Double(window)
    }

    /// Each room is counted once: waiting on you, working, or idle.
    public func roomCounts(staff: [String]) -> RoomCounts {
        let rooms = Set(["manager"] + staff + handoffs.values.map(\.room))
        let waiting = Set(pendingRequests.map(\.room))
        let working = workingRooms
        return rooms.reduce(into: RoomCounts()) { counts, room in
            if waiting.contains(room) {
                counts.waiting += 1
            } else if room == "manager" ? managerActive : working.contains(room) {
                counts.working += 1
            } else {
                counts.idle += 1
            }
        }
    }

    public func handoffs(in room: String) -> [Handoff] {
        handoffs.values.filter { $0.room == room }.sorted { $0.toolUseID < $1.toolUseID }
    }

    public init() {}

    public var workingRooms: Set<String> {
        Set(handoffs.values.filter { $0.phase == .working }.map(\.room))
    }
}

/// The run ends on process exit, not on `result`: background subagents make the CLI emit one `result` per turn.
public struct OfficeReducer: Sendable {
    public private(set) var state = OfficeState()
    private var usageByMessage: [String: TokenUsage] = [:]
    /// Running sums of `usageByMessage`, overall and by model, so each message costs O(1) rather than a re-sum of the run.
    private var liveUsage: TokenUsage = .zero
    private var liveByModel: [String: TokenUsage] = [:]
    /// Totals from the latest `result`; they are cumulative, so later turns add on top of them.
    private var usageBaseline: TokenUsage = .zero
    private var modelBaseline: [String: ModelUsage] = [:]
    private var modelByMessage: [String: String] = [:]
    private var turnsBaseline = 0
    private var mainMessages: Set<String> = []
    private var taskToToolUse: [String: String] = [:]
    private var cancelRequested = false
    private var authFailed = false
    private var lastResult: RunResult?
    private var pendingWrites: [String: String] = [:]
    private var pendingSkills: [String: (room: String, skill: String)] = [:]
    private var pendingServiceCalls: [String: (room: String, server: String)] = [:]
    private var captionedCalls: [String: String] = [:]
    private var latestCall: [String: String] = [:]

    public init() {}

    public mutating func apply(_ input: RunInput) -> [OfficeEvent] {
        if case .ended = state.phase { return [] }
        var out: [OfficeEvent] = []
        switch input {
        case .launched:
            if state.phase == .idle {
                state.phase = .running
                out.append(.runStarted)
            }
        case .cancelRequested:
            cancelRequested = true
        case .requestResolved(let requestID):
            out += lowerHand(requestID)
        case .launchFailed(let failure):
            let reason: FailureReason = switch failure {
            case .cliNotFound: .cliNotFound
            case .notLoggedIn: .notLoggedIn
            case .couldNotStart: .couldNotStart
            }
            let message: String? = if case .couldNotStart(let m) = failure { m } else { nil }
            out += end(.failed(reason, message: message))
        case .processExited(let code, let stderr):
            out += end(outcome(exitCode: code, stderr: stderr))
        case .wire(let event):
            out += apply(event)
        }
        out += syncManager()
        return out
    }

    private mutating func apply(_ event: WireEvent) -> [OfficeEvent] {
        var out: [OfficeEvent] = []
        switch event {
        case .sessionStarted(let session):
            state.sessionID = session.sessionID ?? state.sessionID
            if !session.mcpServers.isEmpty { state.mcpServers = session.mcpServers }
            if state.phase == .idle {
                state.phase = .running
                out.append(.runStarted)
            } else if state.tally.isFinal {
                state.tally.isFinal = false
                out.append(.tallyChanged(state.tally))
            }
        case .assistant(let message):
            if message.error == "authentication_failed" { authFailed = true }
            let model = message.model == "<synthetic>" ? nil : message.model
            if let id = message.messageID, let usage = message.usage, !state.tally.isFinal {
                recordUsage(usage, model: model, for: id)
                state.tally.usage = usageBaseline + liveUsage
                state.models = liveModels()
                out.append(.tallyChanged(state.tally))
            }
            if let parent = message.parentToolUseID {
                if let model { state.handoffs[parent]?.model = model }
            } else if let id = message.messageID {
                mainMessages.insert(id)
                state.turns = turnsBaseline + mainMessages.count
                if let usage = message.usage {
                    state.contextTokens = usage.total
                    state.mainModel = model ?? state.mainModel
                }
            }
            for case let .toolUse(id, name, _, _, input) in message.blocks {
                let room = message.parentToolUseID.flatMap { state.handoffs[$0]?.room } ?? "manager"
                if ToolCall.fileWriters.contains(name), let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue {
                    pendingWrites[id] = path
                }
                if name == "Skill", let skill = input["skill"]?.stringValue {
                    pendingSkills[id] = (room, skill)
                }
                if let split = McpNaming.split(name, servers: state.mcpServers.map(\.name)), pendingServiceCalls[id] == nil {
                    pendingServiceCalls[id] = (room, split.server)
                    state.serviceCallsByServer[split.server, default: 0] += 1
                    out.append(.serviceCall(callID: id, room: room, server: split.server, active: true))
                }
                captionedCalls[id] = room
                latestCall[room] = id
                out.append(.roomCaption(room: room, caption: ToolCaption.text(name: name, input: input)))
                if let parent = message.parentToolUseID {
                    state.handoffs[parent]?.tools.append(ToolCall(name: name, input: input))
                }
            }
            guard message.parentToolUseID == nil else { break }
            for case let .toolUse(id, name, subagentType, description, _) in message.blocks where name == "Agent" || name == "Task" {
                guard state.handoffs[id] == nil else { continue }
                let room = subagentType ?? "general-purpose"
                state.handoffs[id] = Handoff(toolUseID: id, room: room, taskID: nil, phase: .requested, brief: description)
                out.append(.handoff(toolUseID: id, room: room, description: description))
            }
        case .thinkingTokens(let delta):
            guard !state.tally.isFinal else { break }
            state.tally.estimatedThinking += delta
            out.append(.tallyChanged(state.tally))
        case .taskStarted(let task):
            guard let toolUseID = task.toolUseID else { break }
            taskToToolUse[task.taskID] = toolUseID
            let room = state.handoffs[toolUseID]?.room ?? task.subagentType ?? "general-purpose"
            if state.handoffs[toolUseID] == nil {
                state.handoffs[toolUseID] = Handoff(toolUseID: toolUseID, room: room, taskID: nil, phase: .requested)
                out.append(.handoff(toolUseID: toolUseID, room: room, description: task.description))
            }
            state.handoffs[toolUseID]?.taskID = task.taskID
            state.handoffs[toolUseID]?.phase = .working
            state.handoffs[toolUseID]?.isBackground = task.isBackgrounded
            if state.handoffs[toolUseID]?.brief == nil { state.handoffs[toolUseID]?.brief = task.description }
            state.handoffs[toolUseID]?.prompt = task.prompt
            out.append(.roomStarted(toolUseID: toolUseID, room: room))
        case .taskProgress(let progress):
            guard let toolUseID = progress.toolUseID ?? taskToToolUse[progress.taskID],
                  let handoff = state.handoffs[toolUseID] else { break }
            if let tokens = progress.totalTokens { state.handoffs[toolUseID]?.tokens = tokens }
            if let uses = progress.toolUses { state.handoffs[toolUseID]?.toolUses = uses }
            if let step = progress.description, handoff.phase != .finished { state.handoffs[toolUseID]?.step = step }
            if let tool = progress.lastToolName {
                out.append(.roomActivity(room: handoff.room, toolName: tool, step: progress.description))
            }
        case .taskUpdated(let taskID, let status), .taskNotification(let taskID, _, let status):
            if let status { out += finishRoom(taskID: taskID, status: status) }
        case .user(let message):
            for result in message.toolResults {
                if let path = pendingWrites.removeValue(forKey: result.toolUseID), !result.isError, !state.outputFiles.contains(path) {
                    state.outputFiles.append(path)
                }
                if let loaded = pendingSkills.removeValue(forKey: result.toolUseID), !result.isError,
                   !state.skillsByRoom[loaded.room, default: []].contains(loaded.skill) {
                    state.skillsByRoom[loaded.room, default: []].append(loaded.skill)
                    out.append(.skillLoaded(room: loaded.room, skill: loaded.skill))
                }
                if let room = captionedCalls.removeValue(forKey: result.toolUseID), latestCall[room] == result.toolUseID {
                    out.append(.roomCaption(room: room, caption: ToolCaption.thinking))
                }
                if let call = pendingServiceCalls.removeValue(forKey: result.toolUseID) {
                    out.append(.serviceCall(callID: result.toolUseID, room: call.room, server: call.server, active: false))
                }
            }
            guard message.parentToolUseID == nil, message.agentReport?.status != "async_launched" else { break }
            for result in message.toolResults {
                guard let handoff = state.handoffs[result.toolUseID] else { continue }
                state.handoffs[result.toolUseID]?.report = result.text.map(HandBack.clean)
                if let tokens = message.agentReport?.totalTokens { state.handoffs[result.toolUseID]?.tokens = tokens }
                if handoff.phase != .finished {
                    let outcome: RoomOutcome = result.isError ? .failed("Tool error") : .completed
                    finish(result.toolUseID, outcome)
                    out.append(.roomFinished(toolUseID: handoff.toolUseID, room: handoff.room, outcome: outcome))
                }
                out += handBack(result.toolUseID, isError: result.isError)
            }
        case .result(let result):
            lastResult = result
            state.tally.isFinal = true
            state.tally.estimatedThinking = 0
            if !result.modelUsage.isEmpty {
                usageBaseline = result.totalUsage
                usageByMessage = [:]
                liveUsage = .zero
                state.tally.usage = usageBaseline
                modelBaseline = result.modelUsage
                modelByMessage = [:]
                liveByModel = [:]
                state.models = modelBaseline
                for (model, usage) in result.modelUsage {
                    if let window = usage.contextWindow { state.contextWindows[model] = window }
                }
            }
            turnsBaseline += result.numTurns ?? mainMessages.count
            mainMessages = []
            state.turns = turnsBaseline
            state.permissionDenials += result.permissionDenials
            state.subagentStats = result.subagentStats ?? state.subagentStats
            state.tally.costUSD = result.totalCostUSD
            out.append(.tallyChanged(state.tally))
        case .permissionRequest(let request):
            let room = request.agentID.flatMap { taskToToolUse[$0] }.flatMap { state.handoffs[$0]?.room } ?? "manager"
            state.pendingRequests.append(PendingRequest(request: request, room: room))
            out.append(.handRaised(request, room: room))
        case .backgroundTasksChanged(let count):
            state.backgroundTasks = count
        case .rateLimit(let limit):
            state.rateLimit = limit
        case .controlResponse, .unknown:
            break
        }
        return out
    }

    private func outcome(exitCode: Int32, stderr: String) -> RunOutcome {
        if cancelRequested { return .cancelled(costUSD: lastResult?.totalCostUSD) }
        guard let result = lastResult else {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(.processCrashed(code: exitCode), message: trimmed.isEmpty ? nil : trimmed)
        }
        guard result.isError else { return .completed(summary: result.text, costUSD: result.totalCostUSD) }
        if result.terminalReason == "budget_exhausted" {
            return .failed(.budgetExhausted, message: result.errors.joined(separator: " "))
        }
        if authFailed { return .failed(.notLoggedIn, message: result.text) }
        return .failed(.runError(terminalReason: result.terminalReason), message: result.text)
    }

    private mutating func finishRoom(taskID: String, status: String) -> [OfficeEvent] {
        guard let toolUseID = taskToToolUse[taskID], let handoff = state.handoffs[toolUseID],
              handoff.phase == .working else { return [] }
        let outcome: RoomOutcome
        switch status {
        case "completed": outcome = .completed
        case "killed", "stopped": outcome = .killed
        case "failed": outcome = .failed(status)
        default: return []
        }
        finish(toolUseID, outcome)
        var out: [OfficeEvent] = [.roomFinished(toolUseID: toolUseID, room: handoff.room, outcome: outcome)]
        if handoff.isBackground { out += handBack(toolUseID, isError: outcome != .completed) }
        return out
    }

    private mutating func finish(_ toolUseID: String, _ outcome: RoomOutcome) {
        state.handoffs[toolUseID]?.phase = .finished
        state.handoffs[toolUseID]?.outcome = outcome
        state.handoffs[toolUseID]?.step = nil
    }

    /// One API message arrives as several events sharing an id; the latest usage replaces the earlier one.
    private mutating func recordUsage(_ usage: TokenUsage, model: String?, for id: String) {
        let previous = usageByMessage.updateValue(usage, forKey: id)
        liveUsage = liveUsage - (previous ?? .zero) + usage
        let previousModel = modelByMessage[id]
        if let model { modelByMessage[id] = model }
        if let previousModel, let model, previousModel != model {
            // A message changing model is rare enough to rebuild the per-model sums from scratch.
            liveByModel = usageByMessage.reduce(into: [:]) { sums, entry in
                guard let model = modelByMessage[entry.key] else { return }
                sums[model, default: .zero] = sums[model, default: .zero] + entry.value
            }
        } else if let model = modelByMessage[id] {
            // If the message had no model until now, its earlier usage isn't in any model's sum yet.
            let counted: TokenUsage = previousModel == nil ? .zero : previous ?? .zero
            liveByModel[model, default: .zero] = liveByModel[model, default: .zero] - counted + usage
        }
    }

    private func liveModels() -> [String: ModelUsage] {
        liveByModel.reduce(into: modelBaseline) { models, entry in
            models[entry.key, default: ModelUsage(usage: .zero)].usage = models[entry.key, default: ModelUsage(usage: .zero)].usage + entry.value
        }
    }

    private mutating func handBack(_ toolUseID: String, isError: Bool) -> [OfficeEvent] {
        guard let handoff = state.handoffs[toolUseID], !handoff.handedBack else { return [] }
        state.handoffs[toolUseID]?.handedBack = true
        return [.handback(toolUseID: toolUseID, room: handoff.room, isError: isError)]
    }

    private mutating func lowerHand(_ requestID: String) -> [OfficeEvent] {
        guard let index = state.pendingRequests.firstIndex(where: { $0.id == requestID }) else { return [] }
        let pending = state.pendingRequests.remove(at: index)
        return [.handLowered(requestID: requestID, room: pending.room)]
    }

    private mutating func end(_ outcome: RunOutcome) -> [OfficeEvent] {
        var out: [OfficeEvent] = state.pendingRequests.map { .handLowered(requestID: $0.id, room: $0.room) }
        state.pendingRequests = []
        out += pendingServiceCalls.sorted { $0.key < $1.key }.map { .serviceCall(callID: $0.key, room: $0.value.room, server: $0.value.server, active: false) }
        pendingServiceCalls = [:]
        for (id, handoff) in state.handoffs.sorted(by: { $0.key < $1.key }) where handoff.phase != .finished {
            finish(id, .killed)
            out.append(.roomFinished(toolUseID: id, room: handoff.room, outcome: .killed))
        }
        state.phase = .ended(outcome)
        out.append(.runEnded(outcome))
        return out
    }

    private mutating func syncManager() -> [OfficeEvent] {
        let active = state.phase == .running && state.workingRooms.isEmpty
        guard active != state.managerActive else { return [] }
        state.managerActive = active
        return [.managerActive(active)]
    }
}

private extension TokenUsage {
    static func - (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input - rhs.input,
            cacheCreation: lhs.cacheCreation - rhs.cacheCreation,
            cacheRead: lhs.cacheRead - rhs.cacheRead,
            output: lhs.output - rhs.output
        )
    }
}
