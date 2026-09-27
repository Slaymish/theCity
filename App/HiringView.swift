import AppKit
import SwiftUI

struct HiringView: View {
    @Bindable var controller: RunController
    var onBack: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if onBack == nil { Wordmark(compact: true) }
            VStack(alignment: .leading, spacing: 10) {
                Text("Hiring for").eyebrow()
                TextField("What should the office do?", text: $controller.request, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .lineLimit(2...5)
                    .disabled(controller.isHiring)
            }
            .glass()
            HStack(spacing: 10) {
                if controller.isHiring {
                    ProgressView().controlSize(.small)
                    Text(controller.hiringIsSlow ? "Still reading. You can pick departments yourself." : "The receptionist is reading your request on this Mac…")
                        .font(Typography.caption)
                        .foregroundStyle(Color(Palette.muted))
                } else {
                    Text(controller.hiringNote ?? "Drag departments to set their working order, or Control-click one to move it.")
                        .font(Typography.caption)
                        .foregroundStyle(Color(Palette.muted))
                }
                Spacer()
                Button("Ask again") { controller.askAgain() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(controller.isHiring || controller.candidates.isEmpty)
                    .help("Run the receptionist again on the request above")
            }
            ScrollView {
                VStack(spacing: 8) {
                    Text("Departments").eyebrow().frame(maxWidth: .infinity, alignment: .leading)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10, alignment: .top)], spacing: 10) {
                        ForEach(controller.candidates) { candidate in
                            CandidateBadge(candidate: candidate, order: order(of: candidate), colour: controller.colour(for: candidate.department.name),
                                           moveUp: { controller.moveUp(candidate) }, moveDown: { controller.moveDown(candidate) }) { controller.toggle(candidate) }
                                .draggable(candidate.id)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let id = items.first else { return false }
                                    withAnimation(OfficeScene.reduceMotion ? nil : .default) { controller.move(id, before: candidate.id) }
                                    return true
                                }
                        }
                    }
                    Text("Tools and skills for this job").eyebrow().frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    KitChooser(controller: controller)
                }
            }
            .frame(maxHeight: onBack == nil ? 440 : 300)
            .disabled(controller.isHiring && !controller.hiringIsSlow)
            HStack {
                Button("Back") { if let onBack { onBack() } else { controller.backToReception() } }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Text(summary).font(Typography.caption).foregroundStyle(Color(Palette.muted))
                Button("Open the office") { controller.openOffice() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(controller.isHiring || controller.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: 640)
        .padding(onBack == nil ? 32 : 0)
    }

    private var summary: String {
        let hired = controller.candidates.filter(\.hired).map { $0.department.name.capitalized }
        return hired.isEmpty ? "Manager only" : hired.joined(separator: " → ")
    }

    private func order(of candidate: Candidate) -> Int? {
        guard candidate.hired else { return nil }
        return controller.candidates.filter(\.hired).firstIndex(of: candidate)
    }
}

struct CandidateBadge: View {
    let candidate: Candidate
    let order: Int?
    let colour: NSColor
    let moveUp: () -> Void
    let moveDown: () -> Void
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(order == nil ? "‒ ‒" : "^ ^")
                    .font(Typography.ui(15, weight: 700))
                    .foregroundStyle(Color(Palette.screenOn))
                    .frame(width: 52, height: 38)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(Palette.screenOff)))
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color(Palette.robot)))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: OfficeScene.bannerSymbol(for: candidate.department.name))
                            .font(Typography.caption)
                            .foregroundStyle(Color(Palette.textOn(colour)))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color(colour)))
                            .offset(x: 6, y: 6)
                    }
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(order.map { "\($0 + 1)" } ?? "")
                    .font(Typography.captionMedium)
                    .foregroundStyle(Color(Palette.textOn(colour)))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(order == nil ? Color(Palette.hairline) : Color(colour)))
            }
            HStack(spacing: 6) {
                Text(candidate.department.name.capitalized).font(Typography.bodyMedium)
                if candidate.department.isBuiltIn {
                    Label("Built-in", systemImage: "building.2")
                        .font(Typography.caption)
                        .foregroundStyle(Color(Palette.muted))
                        .help("Comes with The City and works in every project. Add an agent with the same name to .claude/agents to replace it.")
                }
            }
            Text(candidate.department.description).font(Typography.caption).foregroundStyle(Color(Palette.muted)).lineLimit(3)
            if let reason = candidate.reason {
                Text("“\(reason)”").font(Typography.caption).foregroundStyle(Color(Palette.muted)).lineLimit(3)
            }
            Spacer(minLength: 0)
            Button(action: toggle) {
                if candidate.hired { Label("Hired", systemImage: "checkmark") } else { Text("Hire") }
            }
                .buttonStyle(PillButtonStyle(kind: order == nil ? .secondary : .accent(colour)))
                .accessibilityLabel(candidate.hired ? "Release \(candidate.department.name)" : "Hire \(candidate.department.name)")
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .glass()
        .overlay(alignment: .top) {
            Capsule().fill(Color(order == nil ? Palette.hairline : colour)).frame(width: 36, height: 5).padding(.top, 6)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Move Up", action: moveUp)
            Button("Move Down", action: moveDown)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(candidate.department.name)\(candidate.department.isBuiltIn ? ", built-in" : ""), \(candidate.hired ? "hired, position \((order ?? 0) + 1)" : "not hired")")
        .accessibilityAction(named: "Move Up", moveUp)
        .accessibilityAction(named: "Move Down", moveDown)
    }
}
