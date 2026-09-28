import Foundation

/// Runs beside a floor's reducer on the Mac and keeps what a snapshot needs but `OfficeState` doesn't hold:
/// each room's caption, the tool it last used and the service calls in flight, which only exist as events.
public struct FloorMirror: Sendable, Equatable {
    public private(set) var captions: [String: String] = [:]
    public private(set) var serviceCalls: [ServiceCallSnapshot] = []
    public private(set) var lastTools: [String: String] = [:]

    public init() {}

    public mutating func record(_ events: [OfficeEvent]) {
        for event in events {
            switch event {
            case .runStarted:
                captions = [:]
                serviceCalls = []
                lastTools = [:]
            case .roomCaption(let room, let caption):
                captions[room] = Clip.text(caption, to: Clip.caption)
            case .roomActivity(let room, let tool, _):
                lastTools[room] = tool
            case .serviceCall(let id, let room, let server, let active):
                serviceCalls.removeAll { $0.callID == id }
                if active { serviceCalls.append(ServiceCallSnapshot(callID: id, room: room, server: server)) }
            case .runEnded:
                serviceCalls = []
            default:
                break
            }
        }
    }

    public func snapshot(id: UUID, name: String, hires: [String], colours: [String: Int] = [:], request: String?, state: OfficeState,
                         startedAt: Date?) -> FloorSnapshot {
        FloorSnapshot(
            id: id, name: name, hires: hires, colours: colours, request: request.map { Clip.text($0, to: Clip.request) },
            phase: Self.phase(state.phase), startedAt: startedAt, managerActive: state.managerActive,
            handoffs: state.handoffs.values.sorted { $0.toolUseID < $1.toolUseID }.map { handoff in
                HandoffSnapshot(
                    toolUseID: handoff.toolUseID, room: handoff.room, brief: handoff.brief.map { Clip.text($0, to: Clip.caption) },
                    phase: handoff.phase, step: handoff.step.map { Clip.text($0, to: Clip.caption) }, lastTool: lastTools[handoff.room] ?? handoff.tools.last?.name,
                    outcome: handoff.outcome.map {
                        switch $0 {
                        case .completed: .completed
                        case .killed: .killed
                        case .failed: .failed
                        }
                    },
                    handedBack: handoff.handedBack)
            },
            captions: captions, skills: state.skillsByRoom, serviceCalls: serviceCalls,
            questions: state.pendingRequests.map(QuestionSnapshot.init), tokens: state.tally.total, costUSD: state.tally.costUSD)
    }

    static func phase(_ phase: OfficeState.Phase) -> FloorSnapshot.Phase {
        switch phase {
        case .idle: .idle
        case .running: .running
        case .ended(.completed(let summary, _)): .completed(summary: summary.map { Clip.text($0, to: Clip.summary) })
        case .ended(.cancelled): .cancelled
        case .ended(.failed(_, let message)): .failed(message: message.map { Clip.text($0, to: Clip.summary) })
        }
    }
}
