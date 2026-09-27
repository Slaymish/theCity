import OfficeCore
import SwiftUI

/// Where a new job runs: on a branch (in whichever folder has it checked out, or a worktree made for it), or in a fresh worktree Claude makes.
enum JobPlace: Hashable {
    case branch(String)
    case newWorktree
}

struct BranchMenu: View {
    let branches: Git.Branches
    @Binding var selection: JobPlace?
    /// The floor's own branch, shown while nothing is picked; nil means the project folder's current branch.
    var usual: String?

    var body: some View {
        Menu {
            ForEach(ordered, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { selection != .newWorktree && shown == name }, set: { _ in selection = .branch(name) }))
            }
            Divider()
            Toggle("New worktree", isOn: Binding(get: { selection == .newWorktree }, set: { _ in selection = .newWorktree }))
        } label: {
            Label("Branch: \(selection == .newWorktree ? "New worktree" : shown ?? "Detached")", systemImage: "arrow.triangle.branch")
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(kind: .secondary))
        .fixedSize()
        .help("The branch this job works on. Follow-ups carry on where the last job ran.")
        .onAppear {
            if selection == nil, usual == nil, let current = branches.current { selection = .branch(current) }
        }
    }

    private var shown: String? {
        if case .branch(let name) = selection { return name }
        return usual ?? branches.current
    }

    private var ordered: [String] {
        let first = [usual, branches.current].compactMap { $0 }.filter(branches.local.contains)
        return (first + branches.local).reduce(into: []) { list, name in if !list.contains(name) { list.append(name) } }
    }
}
