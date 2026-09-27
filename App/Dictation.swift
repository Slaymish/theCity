import AppKit
import Observation
import SwiftUI
@preconcurrency import WhisperKit

@MainActor
@Observable
final class DictationStore {
    enum ModelState: Equatable {
        case none, downloading(Double), loading, ready, failed(String)
    }

    static let shared = DictationStore()
    static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let models = ["large-v3-turbo": variant]

    private(set) var state: ModelState = .none
    private(set) var recordingTarget: UUID?
    private(set) var isTranscribing = false
    private(set) var problem: String?

    private let transcriber = Transcriber()
    private var modelTask: Task<Void, Never>?
    private var starting: Task<Bool, Never>?
    private var insert: ((String) -> Void)?
    private var shortcutMonitor: Any?

    var isAvailable: Bool { state == .ready }

    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("The City/Dictation", isDirectory: true)
    }

    static func folder(for variant: String) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    private init() {}

    func start() {
        installShortcut()
        guard let name = Preferences.shared.dictationModel, let variant = Self.models[name] else { return }
        let folder = Self.folder(for: variant)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            Preferences.shared.dictationModel = nil
            return
        }
        load(folder)
    }

    func choose(_ name: String?) {
        guard name != Preferences.shared.dictationModel || state != .ready else { return }
        Preferences.shared.dictationModel = name
        if let name, let variant = Self.models[name] { download(variant) } else { remove() }
    }

    func remove() {
        modelTask?.cancel()
        modelTask = nil
        recordingTarget = nil
        insert = nil
        Preferences.shared.dictationModel = nil
        state = .none
        problem = nil
        let transcriber = transcriber
        Task { await transcriber.unload() }
        try? FileManager.default.removeItem(at: Self.base)
    }

    private func download(_ variant: String) {
        modelTask?.cancel()
        state = .downloading(0)
        problem = nil
        modelTask = Task {
            do {
                let folder = try await WhisperKit.download(variant: variant, downloadBase: Self.base) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        if case .downloading = self.state { self.state = .downloading(fraction) }
                    }
                }
                try Task.checkCancellation()
                try await loadModel(folder)
            } catch {
                if !Task.isCancelled { state = .failed("The download didn’t finish: \(error.localizedDescription)") }
            }
        }
    }

    private func load(_ folder: URL) {
        modelTask?.cancel()
        modelTask = Task {
            do { try await loadModel(folder) } catch {
                if !Task.isCancelled { state = .failed("The model couldn’t be loaded: \(error.localizedDescription)") }
            }
        }
    }

    private func loadModel(_ folder: URL) async throws {
        state = .loading
        try await transcriber.load(folder)
        try Task.checkCancellation()
        state = .ready
    }

    func toggle(_ id: UUID, insert: @escaping (String) -> Void) {
        guard isAvailable, !isTranscribing else { return }
        if recordingTarget == id {
            stop()
        } else if recordingTarget == nil {
            record(id, insert: insert)
        }
    }

    private func record(_ id: UUID, insert: @escaping (String) -> Void) {
        recordingTarget = id
        self.insert = insert
        problem = nil
        let transcriber = transcriber
        starting = Task {
            guard await AudioProcessor.requestRecordPermission() else {
                problem = "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
                return false
            }
            do {
                try await transcriber.start()
                return true
            } catch {
                problem = "Recording didn’t start: \(error.localizedDescription)"
                return false
            }
        }
        Task {
            if await starting?.value == false, recordingTarget == id {
                recordingTarget = nil
                self.insert = nil
            }
        }
    }

    func cancel(_ id: UUID) {
        guard recordingTarget == id else { return }
        recordingTarget = nil
        insert = nil
        let transcriber = transcriber
        let starting = starting
        Task {
            _ = await starting?.value
            await transcriber.cancel()
        }
    }

    private func stop() {
        recordingTarget = nil
        isTranscribing = true
        let insert = insert
        self.insert = nil
        let transcriber = transcriber
        let starting = starting
        Task {
            defer { isTranscribing = false }
            guard await starting?.value != false else { return }
            do {
                let text = try await transcriber.stop()
                if !text.isEmpty { insert?(text) }
            } catch {
                problem = "Transcription didn’t work: \(error.localizedDescription)"
            }
        }
    }

    private func installShortcut() {
        guard shortcutMonitor == nil else { return }
        // A menu equivalent without ⌘ reaches the text field first, which types a non-breaking space.
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option,
                  NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { return event }
            return nil
        }
    }
}

struct DictationTarget {
    let id: UUID
    let toggle: () -> Void
}

extension FocusedValues {
    @Entry var dictationTarget: DictationTarget?
}

extension View {
    func dictation(text: Binding<String>) -> some View {
        modifier(Dictation(text: text))
    }
}

private struct Dictation: ViewModifier {
    @Binding var text: String
    @State private var id = UUID()
    @Environment(\.isEnabled) private var isEnabled
    private var store: DictationStore { .shared }

    func body(content: Content) -> some View {
        HStack(spacing: 8) {
            content
            if store.isAvailable { button }
        }
        .focusedValue(\.dictationTarget, store.isAvailable && isEnabled ? DictationTarget(id: id, toggle: toggle) : nil)
        .onChange(of: isEnabled) { if !isEnabled { store.cancel(id) } }
        .onDisappear { store.cancel(id) }
    }

    private var button: some View {
        let recording = store.recordingTarget == id
        return Button(action: toggle) {
            Image(systemName: recording ? "mic.fill" : "mic")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(Typography.caption)
        .foregroundStyle(Color(recording ? Palette.error : Palette.muted))
        .disabled(store.isTranscribing || (store.recordingTarget != nil && !recording))
        .help(store.problem ?? (store.isTranscribing ? "Turning your speech into text…" : recording ? "Stop and insert the text (⌥Space)" : "Dictate (⌥Space)"))
        .accessibilityLabel(recording ? "Stop dictation" : "Dictate")
    }

    private func toggle() {
        let text = $text
        store.toggle(id) { words in
            let current = text.wrappedValue
            text.wrappedValue = current.isEmpty || current.last?.isWhitespace == true ? current + words : current + " " + words
        }
    }
}

struct DictationSettings: View {
    private var store: DictationStore { .shared }

    var body: some View {
        Section {
            Picker("Model", selection: Binding(get: { Preferences.shared.dictationModel }, set: { store.choose($0) })) {
                Text("None").tag(String?.none)
                ForEach(DictationStore.models.keys.sorted(), id: \.self) { name in
                    Text("Whisper \(name) (632 MB)").tag(String?.some(name))
                }
            }
            switch store.state {
            case .none: EmptyView()
            case .downloading(let fraction): ProgressView("Downloading…", value: fraction)
            case .loading: LabeledContent("Status") { ProgressView().controlSize(.small) }
            case .ready: LabeledContent("Status", value: "Ready")
            case .failed(let message): Text(message).font(.caption).foregroundStyle(Color(Palette.error))
            }
            if let problem = store.problem {
                Text(problem).font(.caption).foregroundStyle(Color(Palette.error))
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("Press ⌥Space in a prompt to dictate. Speech is turned into text on this Mac and never leaves it.")
                .font(.caption).foregroundStyle(Color(Palette.muted))
        }
    }
}
