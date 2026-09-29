import Foundation

/// Speech recorded on the phone, sent to the Mac to be turned into text by the Mac's dictation model.
/// The samples are 16-bit little-endian mono at 16 kHz, which is what the model reads and a quarter of the size of 32-bit floats.
public struct DictationClip: Codable, Sendable, Equatable {
    public static let sampleRate = 16_000
    /// Long enough for a dictated job, short enough that one clip (as base64 JSON) stays well under `LinkFramer.maximumLength`.
    public static let maximumSeconds = 120

    public var id: UUID
    public var samples: Data

    public init(id: UUID = UUID(), samples: Data) {
        self.id = id
        self.samples = samples
    }

    /// Clips at the maximum length; anything beyond it is dropped.
    public init(id: UUID = UUID(), floats: [Float]) {
        var data = Data(capacity: min(floats.count, Self.maximumSamples) * 2)
        for value in floats.prefix(Self.maximumSamples) {
            var sample = Int16(max(-1, min(1, value)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        self.init(id: id, samples: data)
    }

    static var maximumSamples: Int { sampleRate * maximumSeconds }

    public var count: Int { samples.count / 2 }
    public var seconds: Double { Double(count) / Double(Self.sampleRate) }

    /// Nil when the clip is empty or longer than the Mac will take, so a bad or hostile clip is refused before it reaches the model.
    public var floats: [Float]? {
        guard count > 0, count <= Self.maximumSamples, samples.count.isMultiple(of: 2) else { return nil }
        return stride(from: samples.startIndex, to: samples.endIndex, by: 2).map { index in
            let raw = UInt16(samples[index]) | UInt16(samples[index + 1]) << 8
            return Float(Int16(bitPattern: raw)) / Float(Int16.max)
        }
    }
}

/// The Mac's answer to a clip: the words, or a reason it couldn't get them, said to the person holding the phone.
public struct DictationResult: Codable, Sendable, Equatable {
    public enum Outcome: Codable, Sendable, Equatable {
        case text(String)
        case failed(String)
    }

    public var clipID: UUID
    public var outcome: Outcome

    public init(clipID: UUID, outcome: Outcome) {
        self.clipID = clipID
        self.outcome = outcome
    }
}
