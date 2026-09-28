import AppKit
import OfficeCore
import SwiftUI

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

    func cappedScroll(pinnedToTail: Bool = false) -> some View {
        HeightCap {
            ViewThatFits(in: .vertical) {
                self
                ScrollView { frame(maxWidth: .infinity, alignment: .leading) }
                    .defaultScrollAnchor(pinnedToTail ? .bottom : nil)
            }
        }
    }
}

struct HeightCap: Layout {
    static let maxHeight: CGFloat = 240

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: capped(proposal).height))
    }

    // An outer ScrollView proposes no height, which would let ViewThatFits always pick the unscrolled branch.
    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width, height: min(proposal.height ?? .infinity, Self.maxHeight))
    }
}

struct AccountMenu: View {
    @Bindable var controller: RunController

    var body: some View {
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
    }
}

struct ModelMenu: View {
    @Bindable var controller: RunController

    var body: some View {
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
    }
}

struct BudgetMenu: View {
    @Bindable var controller: RunController

    var body: some View {
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
    }
}
