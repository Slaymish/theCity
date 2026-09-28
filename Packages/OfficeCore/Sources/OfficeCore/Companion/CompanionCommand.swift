import Foundation

/// Something the phone asks the Mac to do. The Mac decides whether it still makes sense when it arrives.
public struct CompanionCommand: Codable, Sendable, Equatable, Identifiable {
    /// Deliberately narrow: nothing here can widen what a floor may do, such as "always allow" or a change of permission mode.
    public enum Action: Codable, Sendable, Equatable {
        case answer(floor: UUID, requestID: String, answers: [String: String])
        case allow(floor: UUID, requestID: String)
        case deny(floor: UUID, requestID: String)
        /// Goes to Reception, which picks a floor or sets one up, just as a request typed on the Mac does.
        case newJob(building: UUID, request: String)
        case cancel(floor: UUID)
    }

    public var id: UUID
    public var issuedAt: Date
    /// The phone's name, for the Mac's log and notifications.
    public var device: String
    public var action: Action

    public init(id: UUID = UUID(), issuedAt: Date, device: String, action: Action) {
        self.id = id
        self.issuedAt = issuedAt
        self.device = device
        self.action = action
    }
}

/// A command as it travels: the exact bytes that were signed, and the signature. The Mac checks the bytes before decoding them.
public struct SealedCommand: Codable, Sendable, Equatable {
    public var payload: Data
    public var tag: Data

    public init(payload: Data, tag: Data) {
        self.payload = payload
        self.tag = tag
    }

    public static func seal(_ command: CompanionCommand, with signer: some CommandSigner) throws -> SealedCommand {
        let payload = try CompanionCoding.encoder.encode(command)
        return SealedCommand(payload: payload, tag: signer.tag(for: payload))
    }
}

/// Signs and checks commands with the key both devices got when they paired.
public protocol CommandSigner: Sendable {
    func tag(for payload: Data) -> Data
    func isValid(_ tag: Data, for payload: Data) -> Bool
}

/// The Mac's checks on every command, in order: signed by a paired phone, readable, recent, and not seen before.
public struct CommandGate: Sendable {
    public enum Rejection: Error, Equatable {
        case badSignature
        case unreadable
        /// Older than `lifetime`, for example sent while the Mac was asleep. A job you asked for hours ago shouldn't start now.
        case expired
        case fromTheFuture
        case replayed
    }

    public let lifetime: TimeInterval
    /// Allowance for the two clocks disagreeing.
    public let skew: TimeInterval
    private var seen: [UUID: Date] = [:]

    public init(lifetime: TimeInterval = 15 * 60, skew: TimeInterval = 2 * 60) {
        self.lifetime = lifetime
        self.skew = skew
    }

    public mutating func admit(_ sealed: SealedCommand, now: Date, signer: some CommandSigner) -> Result<CompanionCommand, Rejection> {
        guard signer.isValid(sealed.tag, for: sealed.payload) else { return .failure(.badSignature) }
        guard let command = try? CompanionCoding.decoder.decode(CompanionCommand.self, from: sealed.payload) else { return .failure(.unreadable) }
        let age = now.timeIntervalSince(command.issuedAt)
        guard age <= lifetime else { return .failure(.expired) }
        guard age >= -skew else { return .failure(.fromTheFuture) }
        // Anything older than the lifetime is refused as expired anyway, so the memory of it can go.
        seen = seen.filter { now.timeIntervalSince($0.value) <= lifetime + skew }
        guard seen[command.id] == nil else { return .failure(.replayed) }
        seen[command.id] = command.issuedAt
        return .success(command)
    }
}

public enum CompanionCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
