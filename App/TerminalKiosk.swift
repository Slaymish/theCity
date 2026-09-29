import AppKit
import OfficeCore
import simd
import SwiftTerm
import SwiftUI

/// The floor's own interactive `claude`, typed into at the kiosk between the Manager and the Outbox.
@MainActor
@Observable
final class KioskSession {
    var isOpen = false
    private(set) var isAlive = false
    @ObservationIgnored private(set) var view: KioskTerminalView?
    @ObservationIgnored private var dark: Bool?

    func start(directory: URL, resume: String?, sessionID: String? = nil, model: String?, configDirectory: URL?, ended: @escaping () -> Void) {
        guard !isAlive else { return }
        let view = KioskTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.onExit = { [weak self] in
            guard let self, self.view === view else { return }
            self.isAlive = false
            self.isOpen = false
            ended()
        }
        self.view = view
        dark = nil
        var command = "claude"
        if let resume { command += " --resume " + Self.quoted(resume) }
        if let sessionID { command += " --session-id " + Self.quoted(sessionID) }
        if let model { command += " --model " + Self.quoted(model) }
        var environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"] == nil { environment["LANG"] = "\(Locale.current.identifier).UTF-8" }
        view.startProcess(executable: Self.loginShell, args: ["-l", "-i", "-c", "exec " + command],
                          environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: directory.path)
        isAlive = true
    }

    func end() {
        view?.onExit = nil
        view?.terminate()
        view = nil
        isAlive = false
        isOpen = false
    }

    func applyColours(dark: Bool) {
        guard let view, dark != self.dark else { return }
        self.dark = dark
        view.nativeBackgroundColor = Palette.resolved(Palette.screenOff, dark: dark)
        view.nativeForegroundColor = Palette.resolved(Palette.screenOn, dark: dark)
        view.caretColor = Palette.resolved(Palette.screenOn, dark: dark)
        view.selectedTextBackgroundColor = Palette.resolved(Palette.primaryFill, dark: dark)
    }

    private static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell, !String(cString: shell).isEmpty { return String(cString: shell) }
        return "/bin/zsh"
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class KioskTerminalView: LocalProcessTerminalView {
    var onExit: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        onExit?()
    }
}

struct KioskTerminal: NSViewRepresentable {
    let session: KioskSession
    let dark: Bool

    func makeNSView(context: Context) -> NSView { session.view ?? NSView() }

    func updateNSView(_ view: NSView, context: Context) { session.applyColours(dark: dark) }
}

/// Sits the live terminal over the kiosk's screen once the camera has flown in, and blocks the scene's gestures meanwhile.
struct KioskLayer: View {
    let controller: RunController
    let scene: OfficeScene
    @Environment(\.colorScheme) private var colorScheme
    @State private var monitor: Any?

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { _ in
                Color.clear.contentShape(Rectangle())
                TimelineView(.animation(paused: scene.camera.motion.settled)) { _ in
                    if scene.camera.isArriving, let rect = scene.kioskScreenRect() {
                        KioskTerminal(session: controller.kiosk, dark: colorScheme == .dark && BrandStore.shared.current.supportsDark)
                            .frame(width: rect.width, height: rect.height)
                            .clipShape(RoundedRectangle(cornerRadius: rect.width * CGFloat(OfficeScene.kioskScreenRadius / OfficeScene.kioskScreen.x)))
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .ignoresSafeArea()
            Button("Leave", systemImage: "chevron.backward") { controller.kiosk.isOpen = false }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .help("Back to the floor (esc). The terminal keeps running.")
                .padding(20)
        }
        .onAppear {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [controller] event in
                guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
                controller.kiosk.isOpen = false
                return nil
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            controller.kiosk.isOpen = false
        }
    }
}

extension CameraRig {
    var isArriving: Bool {
        simd_distance(current.target, goal.target) < 0.05 && abs(current.distance - goal.distance) < 0.05 * goal.distance
            && abs(current.yaw - goal.yaw) < 0.02 && abs(current.pitch - goal.pitch) < 0.02
    }
}
