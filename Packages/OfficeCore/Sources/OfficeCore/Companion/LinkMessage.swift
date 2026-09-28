import Foundation

/// What the Mac tells the phone about a command once it has dealt with it.
public struct CommandReceipt: Codable, Sendable, Equatable {
    public enum Outcome: Codable, Sendable, Equatable {
        case done
        /// Said to the person holding the phone, such as "Already answered on the Mac".
        case refused(String)
    }

    public var commandID: UUID
    public var outcome: Outcome

    public init(commandID: UUID, outcome: Outcome) {
        self.commandID = commandID
        self.outcome = outcome
    }
}

/// One message on the local network connection. Snapshots and receipts go to the phone, commands go to the Mac.
public enum LinkMessage: Codable, Sendable, Equatable {
    case snapshot(CitySnapshot)
    case command(SealedCommand)
    case receipt(CommandReceipt)
    /// Sent by the phone when it connects, so the Mac can refuse a phone too old to read its snapshots.
    case hello(version: Int, device: String)
}

/// Frames messages on a byte stream: a 4-byte big-endian length, then that many bytes of JSON.
public struct LinkFramer: Sendable {
    /// Far above any real snapshot; a length beyond it means the stream is corrupt, not that a message is big.
    public static let maximumLength = 8 * 1024 * 1024

    public enum Failure: Error, Equatable { case tooLong(Int), unreadable }

    private var buffer = Data()

    public init() {}

    public static func frame(_ message: LinkMessage) throws -> Data {
        let body = try CompanionCoding.encoder.encode(message)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Adds bytes as they arrive and returns every message now complete. A failure means the connection should close.
    public mutating func feed(_ bytes: Data) throws -> [LinkMessage] {
        buffer.append(bytes)
        var messages: [LinkMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maximumLength else { throw Failure.tooLong(length) }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.dropFirst(4).prefix(length)
            buffer = Data(buffer.dropFirst(4 + length))
            guard let message = try? CompanionCoding.decoder.decode(LinkMessage.self, from: Data(body)) else { throw Failure.unreadable }
            messages.append(message)
        }
        return messages
    }
}
