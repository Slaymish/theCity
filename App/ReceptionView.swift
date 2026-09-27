import AppKit
import OfficeCore
import SwiftUI

struct ReceptionView: View {
    @Bindable var controller: RunController
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Wordmark()
                Spacer()
                if let onCancel {
                    Button("Cancel", action: onCancel).buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("The job").eyebrow()
                TextField("Describe the job, for example: tidy the README and fix broken links", text: $controller.request, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .lineLimit(3...8)
                    .commandReturn(enabled: canHire) { controller.beginHiring() }
                    .onKeyPress(.tab) {
                        guard let first = matches.first else { return .ignored }
                        controller.request = "/\(first.name) "
                        return .handled
                    }
            }
            .glass()
            if !matches.isEmpty {
                CommandPicker(commands: matches) { controller.request = "/\($0.name) " }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if let url = Self.chooseDirectory() { controller.workingDirectory = url }
                } label: {
                    Label {
                        Text(controller.workingDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Choose the folder to work in…")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .help(controller.workingDirectory?.path ?? "The folder the office works in")
                HStack(spacing: 8) {
                    Menu {
                        ForEach(Preferences.shared.visibleAccounts(including: controller.configDirectory), id: \.self) { url in
                            Button(UsageStore.shared.summary(url)) { controller.configDirectory = url }
                        }
                    } label: {
                        Label("Account: \(Preferences.accountName(controller.configDirectory))", systemImage: "person.crop.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .fixedSize()
                    .help(controller.configDirectory?.path ?? "~/.claude")
                    Menu {
                        Button("Default") { controller.model = nil }
                        ForEach(controller.primaryModels) { model in
                            Button(model.displayName) { controller.model = model.value }
                        }
                        if !controller.otherModels.isEmpty {
                            Menu("Other Versions") {
                                ForEach(controller.otherModels) { model in
                                    Button(model.displayName) { controller.model = model.value }
                                }
                            }
                        }
                    } label: {
                        Label("Model: \(controller.modelName(controller.model))", systemImage: "cpu")
                    }
                    .menuStyle(.button)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .fixedSize()
                    Menu {
                        ForEach(RunController.budgets, id: \.self) { budget in
                            Button(budget.formatted(.currency(code: "USD"))) { controller.budgetUSD = budget }
                        }
                    } label: {
                        Label("Budget: \(controller.budgetUSD.formatted(.currency(code: "USD")))", systemImage: "gauge.with.dots.needle.33percent")
                    }
                    .menuStyle(.button)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .fixedSize()
                    .help("The most this job may spend before it stops")
                    PermissionModeMenu(controller: controller)
                    Spacer(minLength: 0)
                    Button("Hire staff") { controller.beginHiring() }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .fixedSize()
                        .disabled(!canHire)
                }
            }
            ReadinessRow(controller: controller)
        }
        .frame(maxWidth: 640)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollableIfNeeded()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.checkReadiness()
            controller.clearLimitNoticeIfExpired()
        }
    }

    private var matches: [CommandInfo] {
        CommandPicker.matches(for: controller.request, in: controller.kit?.commands ?? [])
    }

    private var canHire: Bool {
        controller.workingDirectory != nil && controller.readiness == .ready
            && !controller.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct ReadinessRow: View {
    let controller: RunController
    static let installPage = URL(string: "https://code.claude.com/docs/en/setup")!
    static let usagePage = URL(string: "https://claude.ai/settings/usage")!

    var body: some View {
        if let content {
            HStack(spacing: 10) {
                Text(content.message)
                    .font(Typography.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(content.actions.enumerated()), id: \.offset) { index, action in
                    Button(action.title, action: action.run)
                        .buttonStyle(PillButtonStyle(kind: index == 0 ? .primary : .secondary))
                        .fixedSize()
                }
            }
            .glass(radius: 12, padding: 12)
        } else if controller.workingDirectory == nil {
            Text("Choose the folder the office should work in to continue.")
                .font(Typography.caption)
                .foregroundStyle(Color(Palette.muted))
        }
    }

    private struct Action {
        var title: String
        var run: () -> Void
    }

    private var content: (message: String, actions: [Action])? {
        switch controller.readiness {
        case .cliMissing:
            return ("Claude Code isn’t installed.", [
                Action(title: "Install…") { NSWorkspace.shared.open(Self.installPage) },
                Action(title: "Locate…") { locate() },
            ])
        case .cliOutdated(let version):
            return ("Claude Code \(version) has known security issues. Update it to \(ClaudeEnvironment.minimumVersionText) or later.", [
                Action(title: "How to Update…") { NSWorkspace.shared.open(Self.installPage) },
                Action(title: "Check Again") { controller.checkReadiness() },
            ])
        case .notLoggedIn:
            return ("You’re not signed in to Claude Code with the \(Preferences.accountName(controller.configDirectory)) account.", [
                Action(title: "Sign In…") { controller.signIn() },
            ])
        case .checking, .ready:
            guard let notice = controller.limitNotice else { return nil }
            let when = notice.resetsAt.map { " It resets at \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
            return ("Your Claude plan’s limit is reached.\(when)", [
                Action(title: "Open Usage Settings") { NSWorkspace.shared.open(notice.url ?? Self.usagePage) },
            ])
        }
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose the claude command-line tool"
        if panel.runModal() == .OK, let url = panel.url {
            Preferences.shared.cliPath = url.path
            controller.checkReadiness()
        }
    }
}

extension View {
    func scrollableIfNeeded() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView { self }
        }
    }
}
