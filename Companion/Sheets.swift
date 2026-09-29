import OfficeCore
import SwiftUI

/// Everything in the building waiting on you, answered one card at a time.
struct QuestionsSheet: View {
    let link: CityLink
    let building: BuildingSnapshot
    var onlyFloor: UUID?
    @Environment(\.dismiss) private var dismiss

    private var waiting: [(floor: FloorSnapshot, question: QuestionSnapshot)] {
        building.floors.filter { onlyFloor == nil || $0.id == onlyFloor }.flatMap { floor in floor.questions.map { (floor, $0) } }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(waiting, id: \.question.id) { item in
                    Section {
                        QuestionCard(link: link, floor: item.floor, question: item.question, send: link.send)
                    } header: {
                        Text("\(item.floor.name) · \(who(item.question.room))")
                    }
                }
            }
            .overlay {
                if waiting.isEmpty {
                    ContentUnavailableView("Nothing waiting", systemImage: "checkmark.circle", description: Text("Everyone in \(building.displayName) has what they need."))
                }
            }
            .navigationTitle(building.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func who(_ room: String) -> String { room == "manager" ? "The manager" : room.capitalized }
}

struct QuestionCard: View {
    let link: CityLink
    let floor: FloorSnapshot
    let question: QuestionSnapshot
    let send: (CompanionCommand.Action) -> Void
    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        if let asked = question.questions {
            ForEach(asked, id: \.question) { item in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = item.header { Text(header).font(.caption.weight(.semibold)).foregroundStyle(Color(Palette.muted)) }
                    Text(item.question).font(.body.weight(.medium))
                    ForEach(item.options, id: \.label) { option in
                        Button {
                            toggle(option.label, in: item)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: isPicked(option.label, in: item) ? (item.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                                                   : (item.multiSelect ? "square" : "circle"))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).foregroundStyle(Color(Palette.text))
                                    if let description = option.description {
                                        Text(description).font(.footnote).foregroundStyle(Color(Palette.muted))
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    let text = Binding(get: { other[item.question] ?? "" }, set: { other[item.question] = $0 })
                    HStack {
                        TextField("Something else", text: text)
                            .textFieldStyle(.roundedBorder)
                        DictationButton(link: link, text: text)
                    }
                }
                .padding(.vertical, 4)
            }
            Button("Send Answer") {
                send(.answer(floor: floor.id, requestID: question.requestID, answers: answers(asked)))
            }
            .buttonStyle(.glassProminent)
            .disabled(!asked.allSatisfy { !answer(for: $0).isEmpty })
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Wants to use \(question.toolName)").font(.body.weight(.medium))
                if let summary = question.summary {
                    Text(summary).font(.system(.footnote, design: .monospaced)).foregroundStyle(Color(Palette.text))
                }
                Text("Allowing here is for this once only. To always allow it, use your Mac.")
                    .font(.footnote).foregroundStyle(Color(Palette.muted))
            }
            HStack {
                Button("Deny", role: .destructive) { send(.deny(floor: floor.id, requestID: question.requestID)) }
                    .buttonStyle(.glass)
                Button("Allow Once") { send(.allow(floor: floor.id, requestID: question.requestID)) }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private func isPicked(_ label: String, in item: AskedQuestion) -> Bool { picked[item.question]?.contains(label) == true }

    private func toggle(_ label: String, in item: AskedQuestion) {
        var chosen = picked[item.question] ?? []
        if item.multiSelect {
            if chosen.remove(label) == nil { chosen.insert(label) }
        } else {
            chosen = [label]
        }
        picked[item.question] = chosen
    }

    /// Typed text wins over a picked option. Multiple choices are joined the way the Mac joins them.
    private func answer(for item: AskedQuestion) -> String {
        let typed = (other[item.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let chosen = picked[item.question] ?? []
        return item.options.map(\.label).filter(chosen.contains).joined(separator: ", ")
    }

    private func answers(_ asked: [AskedQuestion]) -> [String: String] {
        Dictionary(asked.map { ($0.question, answer(for: $0)) }) { first, _ in first }
    }
}

/// A new job for the building, which Reception on the Mac routes to the right floor.
struct NewJobSheet: View {
    let link: CityLink
    let building: BuildingSnapshot
    @State private var request = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top) {
                        TextField("What do you need done in \(building.displayName)?", text: $request, axis: .vertical)
                            .lineLimit(3...8)
                            .focused($focused)
                        DictationButton(link: link, text: $request)
                            .padding(.top, 2)
                    }
                } footer: {
                    Text("Reception picks the right floor, or sets up a new one.")
                }
            }
            .navigationTitle("New Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        link.send(.newJob(building: building.id, request: request))
                        dismiss()
                    }
                    .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
