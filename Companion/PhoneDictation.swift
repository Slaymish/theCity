import AVFoundation
import Observation
import OfficeCore
import SwiftUI

/// Records on the phone and has the Mac turn the speech into text. The phone never holds a model.
@MainActor
@Observable
final class PhoneDictation {
    enum State: Equatable {
        case idle, recording, waiting
    }

    private(set) var state: State = .idle
    private(set) var problem: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let recorder = Samples()
    @ObservationIgnored private var limit: Task<Void, Never>?

    /// Starts recording, or stops and sends what was said. `insert` gets the words when they come back.
    func toggle(link: CityLink, insert: @escaping (String) -> Void) {
        switch state {
        case .idle: Task { await start(link: link, insert: insert) }
        case .recording: finish(link: link, insert: insert)
        case .waiting: break
        }
    }

    func cancel() {
        guard state == .recording else { return }
        stopEngine()
        state = .idle
    }

    private func start(link: CityLink, insert: @escaping (String) -> Void) async {
        problem = nil
        guard link.route == .local else { return problem = CityLink.DictationFailure.offline.errorDescription }
        guard await AVAudioApplication.requestRecordPermission() else {
            return problem = "Microphone access is off. Turn it on in Settings › The City."
        }
        do {
            try beginEngine()
            state = .recording
            // The Mac takes a clip up to `maximumSeconds`; stop there rather than lose the end of what was said.
            limit = Task {
                try? await Task.sleep(for: .seconds(DictationClip.maximumSeconds))
                if !Task.isCancelled, state == .recording { finish(link: link, insert: insert) }
            }
        } catch {
            stopEngine()
            problem = "Recording didn’t start: \(error.localizedDescription)"
        }
    }

    private func beginEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(DictationClip.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw Failure.noFormat }
        recorder.reset()
        let recorder = recorder
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / format.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = out.floatChannelData?[0] else { return }
            recorder.append(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        }
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        limit?.cancel()
        limit = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Back to the ambient session the office's sounds use, so the silent switch mutes them again.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
    }

    private func finish(link: CityLink, insert: @escaping (String) -> Void) {
        stopEngine()
        let floats = recorder.take()
        // Under a third of a second is a mis-tap, not speech.
        guard floats.count > DictationClip.sampleRate / 3 else { return state = .idle }
        state = .waiting
        Task {
            defer { state = .idle }
            do {
                let text = try await link.dictate(DictationClip(floats: floats))
                insert(text)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private enum Failure: LocalizedError {
        case noFormat
        var errorDescription: String? { "The microphone’s format isn’t supported." }
    }
}

/// The audio tap runs on a real-time thread, so it appends under a lock instead of hopping to the main actor.
private final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var floats: [Float] = []

    func reset() { lock.withLock { floats = [] } }

    func append(_ buffer: UnsafeBufferPointer<Float>) {
        lock.withLock {
            guard floats.count < DictationClip.sampleRate * DictationClip.maximumSeconds else { return }
            floats.append(contentsOf: buffer)
        }
    }

    func take() -> [Float] { lock.withLock { let taken = floats; floats = []; return taken } }
}

/// A mic button that appends what you say to `text`. Shown only when the Mac is reachable on this network.
struct DictationButton: View {
    let link: CityLink
    @Binding var text: String
    @State private var dictation = PhoneDictation()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                let text = $text
                dictation.toggle(link: link) { words in
                    let current = text.wrappedValue
                    text.wrappedValue = current.isEmpty || current.last?.isWhitespace == true ? current + words : current + " " + words
                }
            } label: {
                switch dictation.state {
                case .idle: Image(systemName: "mic")
                case .recording: Image(systemName: "mic.fill").foregroundStyle(Color(Palette.error))
                case .waiting: ProgressView()
                }
            }
            .buttonStyle(.plain)
            .disabled(dictation.state == .waiting || (dictation.state == .idle && link.route != .local))
            .accessibilityLabel(dictation.state == .recording ? "Stop dictation" : "Dictate")
            .accessibilityHint("Your Mac turns your speech into text")
            if let problem = dictation.problem {
                Text(problem).font(.footnote).foregroundStyle(Color(Palette.error)).multilineTextAlignment(.trailing)
            }
        }
        .onDisappear { dictation.cancel() }
    }
}
