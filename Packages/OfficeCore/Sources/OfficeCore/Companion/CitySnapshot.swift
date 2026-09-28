import Foundation

/// What the Mac tells the companion app: every building, its floors, and what each floor's office is doing now.
/// It is a picture rather than a log, so a phone that joins late or misses an update only needs the latest one.
public struct CitySnapshot: Codable, Sendable, Equatable {
    /// Bumped when a change would break an older phone; the phone asks for an update instead of misreading it.
    public static let protocolVersion = 1

    public var version = CitySnapshot.protocolVersion
    /// The Mac's name, so the phone can say where its city lives.
    public var host: String
    public var takenAt: Date
    public var buildings: [BuildingSnapshot]

    public init(host: String, takenAt: Date, buildings: [BuildingSnapshot]) {
        self.host = host
        self.takenAt = takenAt
        self.buildings = buildings
    }

    public var waitingCount: Int { buildings.reduce(0) { $0 + $1.waitingCount } }
}

public struct BuildingSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The folder's name.
    public var name: String
    /// The project's proper name from the billboard, once Haiku has named it.
    public var title: String?
    /// Which facade the building wears.
    public var style: Int
    public var floors: [FloorSnapshot]

    public init(id: UUID, name: String, title: String?, style: Int, floors: [FloorSnapshot]) {
        self.id = id
        self.name = name
        self.title = title
        self.style = style
        self.floors = floors
    }

    public var displayName: String { title ?? name }
    public var waitingCount: Int { floors.reduce(0) { $0 + $1.questions.count } }
    public var workingCount: Int { floors.filter(\.isRunning).count }
}

public struct FloorSnapshot: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: Codable, Sendable, Equatable {
        case idle
        case running
        case completed(summary: String?)
        case cancelled
        case failed(message: String?)
    }

    public var id: UUID
    public var name: String
    /// Department names in hiring order, which is the order the office lays out its pods.
    public var hires: [String]
    /// The job being worked on, or the last one.
    public var request: String?
    public var phase: Phase
    /// When the current or last job started; a new value means a new run, so the phone resets the office.
    public var startedAt: Date?
    public var managerActive: Bool
    public var handoffs: [HandoffSnapshot]
    /// The latest caption over each room's robot, such as "Reading README.md".
    public var captions: [String: String]
    public var skills: [String: [String]]
    public var serviceCalls: [ServiceCallSnapshot]
    public var questions: [QuestionSnapshot]
    public var tokens: Int
    public var costUSD: Double?

    public init(id: UUID, name: String, hires: [String], request: String?, phase: Phase, startedAt: Date?, managerActive: Bool = false,
                handoffs: [HandoffSnapshot] = [], captions: [String: String] = [:], skills: [String: [String]] = [:],
                serviceCalls: [ServiceCallSnapshot] = [], questions: [QuestionSnapshot] = [], tokens: Int = 0, costUSD: Double? = nil) {
        self.id = id
        self.name = name
        self.hires = hires
        self.request = request
        self.phase = phase
        self.startedAt = startedAt
        self.managerActive = managerActive
        self.handoffs = handoffs
        self.captions = captions
        self.skills = skills
        self.serviceCalls = serviceCalls
        self.questions = questions
        self.tokens = tokens
        self.costUSD = costUSD
    }

    public var isRunning: Bool { phase == .running }
}

public struct HandoffSnapshot: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: Codable, Sendable, Equatable { case completed, killed, failed }

    public var id: String { toolUseID }
    public var toolUseID: String
    public var room: String
    public var brief: String?
    public var phase: Handoff.Phase
    public var step: String?
    /// The last tool the room used, which picks the symbol in its speech bubble.
    public var lastTool: String?
    public var outcome: Outcome?
    public var handedBack: Bool

    public init(toolUseID: String, room: String, brief: String?, phase: Handoff.Phase, step: String?, lastTool: String?,
                outcome: Outcome?, handedBack: Bool) {
        self.toolUseID = toolUseID
        self.room = room
        self.brief = brief
        self.phase = phase
        self.step = step
        self.lastTool = lastTool
        self.outcome = outcome
        self.handedBack = handedBack
    }
}

public struct ServiceCallSnapshot: Codable, Sendable, Equatable, Hashable {
    public var callID: String
    public var room: String
    public var server: String

    public init(callID: String, room: String, server: String) {
        self.callID = callID
        self.room = room
        self.server = server
    }
}

/// A question or approval waiting on you, with only what the phone's card needs to show and answer it.
public struct QuestionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String { requestID }
    public var requestID: String
    public var room: String
    public var toolName: String
    /// Set for `AskUserQuestion`; otherwise this is an approval described by `summary`.
    public var questions: [AskedQuestion]?
    public var summary: String?

    public init(requestID: String, room: String, toolName: String, questions: [AskedQuestion]?, summary: String?) {
        self.requestID = requestID
        self.room = room
        self.toolName = toolName
        self.questions = questions
        self.summary = summary
    }

    public init(_ pending: PendingRequest) {
        requestID = pending.id
        room = pending.room
        toolName = pending.request.toolName
        switch pending.request.kind {
        case .question(let asked):
            questions = asked
            summary = nil
        case .approval(let text):
            questions = nil
            summary = Clip.text(text, to: Clip.summary)
        }
    }

    public var request: PermissionRequest {
        PermissionRequest(requestID: requestID, toolName: toolName,
                          kind: questions.map { .question($0) } ?? .approval(summary: summary ?? toolName))
    }
}

/// Snapshots are sent often and stored in CloudKit, so free text is capped. Questions are never clipped: you need all of one to answer it.
enum Clip {
    static let caption = 120
    static let summary = 400
    static let request = 400

    static func text(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
