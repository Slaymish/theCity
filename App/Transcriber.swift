import Foundation
@preconcurrency import WhisperKit

actor Transcriber {
    enum Failure: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The dictation model isn’t loaded." }
    }

    private var kit: WhisperKit?

    func load(_ folder: URL) async throws {
        kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: true, load: true, download: false))
    }

    func unload() {
        kit?.audioProcessor.stopRecording()
        kit = nil
    }

    func start() throws {
        guard let kit else { throw Failure.notLoaded }
        kit.audioProcessor.purgeAudioSamples(keepingLast: 0)
        try kit.audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)
    }

    func cancel() {
        kit?.audioProcessor.stopRecording()
        kit?.audioProcessor.purgeAudioSamples(keepingLast: 0)
    }

    func stop() async throws -> String {
        guard let kit else { throw Failure.notLoaded }
        kit.audioProcessor.stopRecording()
        let samples = Array(kit.audioProcessor.audioSamples)
        kit.audioProcessor.purgeAudioSamples(keepingLast: 0)
        return try await transcribe(samples)
    }

    /// Turns speech that didn't come from this Mac's microphone into text.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let kit else { throw Failure.notLoaded }
        guard !samples.isEmpty else { return "" }
        let results = try await kit.transcribe(audioArray: samples,
                                               decodeOptions: DecodingOptions(task: .transcribe, skipSpecialTokens: true, withoutTimestamps: true))
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
