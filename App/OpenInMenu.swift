import AppKit
import SwiftUI

/// Opens the project folder in an editor or terminal, remembering the last choice as the default.
struct OpenInMenu: View {
    let directory: URL
    private var preferences = Preferences.shared

    init(directory: URL) {
        self.directory = directory
    }

    private static let candidates = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
        "com.apple.dt.Xcode", "com.jetbrains.WebStorm", "com.sublimetext.4", "com.mitchellh.ghostty",
        "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal", "com.apple.finder",
    ]

    private var installed: [URL] {
        Self.candidates.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    private var remembered: URL? {
        guard let path = preferences.editorPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        Group {
            if let remembered {
                Menu("Open in \(Self.name(of: remembered))", systemImage: "arrow.up.forward.app") {
                    choices
                } primaryAction: {
                    open(with: remembered)
                }
            } else {
                Menu("Open…", systemImage: "arrow.up.forward.app") { choices }
            }
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(kind: .secondary))
        .fixedSize()
        .help("Open this project's folder in another app")
    }

    @ViewBuilder private var choices: some View {
        ForEach(installed, id: \.self) { app in
            Button {
                open(with: app)
            } label: {
                Label { Text(Self.name(of: app)) } icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)) }
            }
        }
        Divider()
        Button("Other app…", action: chooseOther)
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(with: app)
    }

    private func open(with app: URL) {
        preferences.editorPath = app.path
        NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}
