import AppKit
import OfficeCore
import QuickLook
import SwiftUI

struct AnswerDraft {
    var picked: [String: Set<String>] = [:]
    var other: [String: String] = [:]

    @MainActor mutating func select(_ label: String, in question: AskedQuestion) {
        Haptics.pick()
        other[question.question] = ""
        var set = picked[question.question, default: []]
        if question.multiSelect {
            if !set.insert(label).inserted { set.remove(label) }
        } else {
            set = [label]
        }
        picked[question.question] = set
    }

    func answer(for question: AskedQuestion) -> String? {
        let typed = other[question.question, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let labels = question.options.map(\.label).filter { picked[question.question, default: []].contains($0) }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    func answers(_ questions: [AskedQuestion]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: questions.compactMap { q in answer(for: q).map { (q.question, $0) } })
    }
}

struct QuestionFields: View {
    let question: AskedQuestion
    let numbered: Bool
    let colour: NSColor
    @Binding var draft: AnswerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = question.header { Text(header).eyebrow() }
            Text(question.question).font(Typography.bodyMedium)
            if question.multiSelect {
                Text("Choose any that apply.").font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
            ForEach(Array(question.options.enumerated()), id: \.element.label) { index, option in
                OptionButton(option: option, shortcut: numbered && index < 9 ? index + 1 : nil, colour: colour,
                             selected: draft.picked[question.question, default: []].contains(option.label)) {
                    draft.select(option.label, in: question)
                }
            }
            TextField("Other…", text: Binding(
                get: { draft.other[question.question, default: ""] },
                set: { draft.other[question.question] = $0; if !$0.isEmpty { draft.picked[question.question] = [] } }
            ))
            .textFieldStyle(.plain)
            .font(Typography.caption)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(Palette.hairline), lineWidth: 1))
            .accessibilityLabel("Other answer to: \(question.question)")
        }
    }
}

struct RequestCard: View {
    let pending: PendingRequest
    let colour: NSColor
    let isFront: Bool
    let controller: RunController
    @State private var draft = AnswerDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(controller.displayName(pending.room)) asks")
                .help(pending.room)
                .font(Typography.captionMedium)
                .foregroundStyle(Color(Palette.textOn(colour)))
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(Capsule().fill(Color(colour)))
            switch pending.request.kind {
            case .question(let questions):
                ForEach(Array(questions.enumerated()), id: \.element.question) { index, question in
                    QuestionFields(question: question, numbered: isFront && index == 0, colour: colour, draft: $draft)
                }
                HStack {
                    Spacer()
                    Button("Send answer") { controller.answer(pending, answers: draft.answers(questions)) }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(isFront ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        .disabled(!questions.allSatisfy { draft.answer(for: $0) != nil })
                }
            case .approval(let summary):
                Text("May I use \(controller.friendly(pending.request.toolName))?").font(Typography.bodyMedium)
                Text(summary)
                    .font(Typography.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glass(radius: 9, padding: 8)
                let rules = pending.request.suggestedRules
                if !rules.isEmpty {
                    Text("Always allow remembers this for \(controller.workingDirectory?.lastPathComponent ?? "this folder").")
                        .font(Typography.caption)
                        .foregroundStyle(Color(Palette.muted))
                        .help("Saves \(rules.joined(separator: ", ")) to .claude/settings.local.json")
                }
                HStack {
                    Spacer()
                    Button("Deny") { controller.deny(pending) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .keyboardShortcut(isFront ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                    if !rules.isEmpty {
                        Button("Always allow") { controller.allow(pending, always: true) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                    Button("Allow") { controller.allow(pending) }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(isFront ? KeyboardShortcut(.return, modifiers: .command) : nil)
                }
                if controller.permissionMode != .auto {
                    Button("Allow and switch this job to Auto") { controller.allowAndSwitchToAuto(pending) }
                        .buttonStyle(.link)
                        .font(Typography.caption)
                        .help(PermissionMode.auto.detail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 12, padding: 12)
    }
}

struct DeskCard: View {
    let pending: PendingRequest
    let colour: NSColor
    let controller: RunController
    @State private var draft = AnswerDraft()
    @State private var stamped: Stamp?
    static let width: CGFloat = 360

    enum Stamp { case allowed, alwaysAllowed, auto, denied }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WaitingAge(since: pending.since)
            switch pending.request.kind {
            case .question(let questions):
                Text("\(controller.displayName(pending.room)) asks")
                    .help(pending.room)
                    .font(Typography.captionMedium)
                    .foregroundStyle(Color(Palette.textOn(colour)))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(Color(colour)))
                let fields = VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(questions.enumerated()), id: \.element.question) { index, question in
                        QuestionFields(question: question, numbered: index == 0, colour: colour, draft: $draft)
                    }
                }
                ViewThatFits(in: .vertical) {
                    fields
                    ScrollView { fields }.sheltersScroll()
                }
                HStack {
                    Spacer()
                    Button("Send answer") { controller.answer(pending, answers: draft.answers(questions)) }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!questions.allSatisfy { draft.answer(for: $0) != nil })
                }
            case .approval(let summary):
                Text("\(Text(controller.displayName(pending.room)).bold()) would like to \(verb):")
                    .font(Typography.bodyMedium)
                    .help(pending.room)
                Text(summary)
                    .font(Typography.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cappedScroll()
                    .glass(radius: 9, padding: 8)
                let rules = pending.request.suggestedRules
                HStack {
                    Button("Deny") { stamp(.denied) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .keyboardShortcut(.delete, modifiers: .command)
                    if !rules.isEmpty {
                        Button("Always allow in \(controller.workingDirectory?.lastPathComponent ?? "this folder")") { stamp(.alwaysAllowed) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .lineLimit(1)
                            .help("Saves \(rules.joined(separator: ", ")) to .claude/settings.local.json")
                    }
                    Spacer(minLength: 0)
                    Button("Allow") { stamp(.allowed) }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .disabled(stamped != nil)
                if !rules.isEmpty {
                    Text("Always allow saves \(rules.joined(separator: ", ")) to this project’s .claude/settings.local.json.")
                        .font(Typography.caption)
                        .foregroundStyle(Color(Palette.muted))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if controller.permissionMode != .auto {
                    Button("Allow and switch this job to Auto") { stamp(.auto) }
                        .buttonStyle(.link)
                        .font(Typography.caption)
                        .help(PermissionMode.auto.detail)
                        .disabled(stamped != nil)
                }
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .glass(radius: 12, padding: 12)
        .overlay {
            if let stamped {
                Text(stamped == .denied ? "Denied" : stamped == .alwaysAllowed ? "Always allowed" : "Allowed")
                    .font(Typography.titleLarge)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(stamped == .denied ? Palette.error : Palette.text))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 16)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(stamped == .denied ? Palette.error : Palette.text), lineWidth: 4))
                    .rotationEffect(.degrees(-12))
                    .transition(OfficeScene.reduceMotion ? .identity : .scale(scale: 1.6).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(controller.displayName(pending.room)) needs you")
    }

    private var verb: String {
        pending.request.toolName == "Bash" ? "run" : "use \(controller.friendly(pending.request.toolName))"
    }

    private func stamp(_ kind: Stamp) {
        Haptics.stamp()
        Sound.play(kind == .denied ? .deny : .stamp)
        withAnimation(OfficeScene.reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.35)) { stamped = kind }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(OfficeScene.reduceMotion ? 0 : 350))
            switch kind {
            case .allowed: controller.allow(pending)
            case .alwaysAllowed: controller.allow(pending, always: true)
            case .auto: controller.allowAndSwitchToAuto(pending)
            case .denied: controller.deny(pending)
            }
        }
    }
}

struct OptionButton: View {
    let option: QuestionOption
    let shortcut: Int?
    let colour: NSColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                if let shortcut {
                    Text("⌘\(shortcut)").font(Typography.code).foregroundStyle(secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(Typography.controlQuiet)
                    if let description = option.description {
                        Text(description).font(Typography.caption).foregroundStyle(secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .foregroundStyle(selected ? Color(Palette.textOn(colour)) : Color(Palette.text))
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color(colour) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(Palette.hairline), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut.map { KeyboardShortcut(KeyEquivalent(Character("\($0)")), modifiers: .command) })
        .accessibilityLabel([option.label, option.description].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var secondary: Color {
        selected ? Color(Palette.textOn(colour)) : Color(Palette.muted)
    }
}

/// Jobs that arrived while the floor was busy, held after one that didn't finish until the user sends them on.
struct QueuedJobsRow: View {
    let controller: RunController

    var body: some View {
        if controller.queueHeld, !controller.queued.isEmpty {
            let count = controller.queued.count
            HStack(spacing: 8) {
                Button("Start \(count) Queued Job\(count == 1 ? "" : "s")", systemImage: "play.fill") { controller.resumeQueue() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(controller.readiness != .ready)
                Button("Discard Queue", systemImage: "trash") { controller.discardQueue() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            .disabled(controller.isRunning)
            .help(controller.queued.map(\.text).joined(separator: "\n"))
        }
    }
}

struct EndCard: View {
    let controller: RunController
    let outcome: RunOutcome
    @Binding var collapsed: Bool
    @State private var followUp = ""
    @State private var reading = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if collapsed {
                Button { collapsed = false } label: {
                    HStack(spacing: 8) {
                        Text(barText).font(Typography.captionMedium).lineLimit(1)
                        if let record = controller.recordLine {
                            Text(record).font(Typography.caption).foregroundStyle(Color(Palette.muted)).lineLimit(1)
                        }
                        Image(systemName: "chevron.up").font(Typography.caption)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 15)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(Glass(radius: 24, padding: EdgeInsets()))
                .accessibilityLabel("\(barText). Expand the outbox.")
            } else {
                expanded
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            collapsed.toggle()
            return .handled
        }
        .onAppear { focused = true }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).eyebrow()
                Spacer()
                Button("Read in full", systemImage: "doc.text.magnifyingglass") { reading = true }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button { collapsed = true } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(Palette.muted))
                    .help("Collapse (Space)")
                    .accessibilityLabel("Collapse the outbox")
            }
            ViewThatFits(in: .vertical) {
                summaryText.fixedSize(horizontal: false, vertical: true)
                ScrollView { summaryText }.frame(height: 320).sheltersScroll()
            }
            .frame(maxHeight: 320)
            if !links.isEmpty {
                HStack(spacing: 8) {
                    ForEach(links, id: \.self) { url in
                        Button("Open \(url.host() ?? "link")") { NSWorkspace.shared.open(url) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }
            }
            if case .failed(.budgetExhausted, _) = outcome, let next = RunController.budgets.first(where: { $0 > controller.budgetUSD }) {
                Button("Raise to \(next.formatted(.currency(code: "USD"))) and Continue") {
                    controller.budgetUSD = next
                    controller.followUp("Please continue where you left off.")
                }
                .buttonStyle(PillButtonStyle())
            }
            if case .failed = outcome {
                ReadinessRow(controller: controller)
            }
            if canTryAgain {
                Button("Try again", systemImage: "arrow.clockwise") { controller.tryAgain() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(controller.readiness != .ready || controller.isRunning)
            }
            QueuedJobsRow(controller: controller)
            if !controller.jobFiles.isEmpty {
                Text("Files").eyebrow()
                ForEach(controller.jobFiles, id: \.self) { path in
                    FileRow(path: path, workingDirectory: controller.workingDirectory)
                }
            }
            if canFollowUp {
                PromptEditor(address: [controller.workingDirectory?.lastPathComponent ?? "Project", "Follow-up on this job"],
                             placeholder: "Ask for a change or a next step…",
                             directory: controller.workingDirectory, text: $followUp,
                             canSend: !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                             commands: controller.kit?.commands ?? [], send: send) { withImages in
                    Button("Send", action: withImages(send))
                        .buttonStyle(PillButtonStyle())
                        .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 620, alignment: .leading)
        .glass(padding: 16)
        .sheet(isPresented: $reading) { reader }
    }

    private var reader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).eyebrow()
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                Button("Done") { reading = false }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(rendered).font(Typography.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)
            }
        }
        .padding(24)
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 720)
    }

    private var summaryText: some View {
        Text(rendered).font(Typography.body).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rendered: AttributedString {
        (try? AttributedString(markdown: message, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message)
    }

    private var links: [URL] {
        guard case .failed = outcome,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: message, range: NSRange(message.startIndex..., in: message)).compactMap(\.url)
    }

    private var barText: String {
        let file = controller.jobFiles.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        let cost = controller.state.tally.costUSD.map { $0.formatted(.currency(code: "USD")) }
        return ([title, file, cost] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    private var canFollowUp: Bool {
        guard controller.floorID == nil, controller.state.sessionID != nil, !controller.isAccountFailure else { return false }
        switch outcome {
        case .completed, .cancelled, .failed(.budgetExhausted, _), .failed(.runError, _): return true
        case .failed: return false
        }
    }

    private var canTryAgain: Bool {
        guard !controller.isDemo, case .failed(let reason, _) = outcome else { return false }
        if case .budgetExhausted = reason { return false }
        return true
    }

    private func send() {
        controller.followUp(followUp)
        followUp = ""
    }

    private var title: String { RunController.title(for: outcome) }

    private var message: String { RunController.message(for: outcome, budget: controller.budgetUSD) }
}

struct HistorySheet: View {
    let controller: RunController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History · \(controller.displayTitle)").eyebrow()
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                Button("Done") { controller.showHistory = false }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(jobs.enumerated()), id: \.offset) { index, job in
                        if index > 0 { Divider() }
                        ForEach(job) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(label(entry)) · \(entry.date.formatted(date: .abbreviated, time: .shortened))").eyebrow()
                                Text(rendered(entry.text)).font(Typography.body).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.trailing, 12)
            }
        }
        .padding(24)
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 720)
    }

    private var jobs: [[HistoryEntry]] {
        controller.history.reduce(into: []) { groups, entry in
            if let last = groups.last?.last, last.job == entry.job { groups[groups.count - 1].append(entry) } else { groups.append([entry]) }
        }
    }

    private func label(_ entry: HistoryEntry) -> String {
        switch entry.kind {
        case .request: entry.title ?? "New job"
        case .followUp: entry.title ?? "Follow-up"
        case .outcome: entry.title ?? "Outcome"
        }
    }

    private var transcript: String {
        jobs.map { job in
            job.map { "\(label($0)) (\($0.date.formatted(date: .abbreviated, time: .shortened)))\n\($0.text)" }.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n")
    }

    private func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct FileRow: View {
    let path: String
    let workingDirectory: URL?
    @State private var preview: URL?
    @FocusState private var focused: Bool

    var body: some View {
        let url = URL(fileURLWithPath: path)
        let exists = FileManager.default.fileExists(atPath: path)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(Typography.captionMedium)
                Text(relativePath).font(Typography.code).foregroundStyle(Color(Palette.muted)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if exists {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            } else {
                Text("No longer on disk").font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
        }
        .contentShape(Rectangle())
        .focusable(exists)
        .focused($focused)
        .onTapGesture(count: 2) { if exists { NSWorkspace.shared.open(url) } }
        .onKeyPress(.space) {
            guard exists else { return .ignored }
            preview = preview == nil ? url : nil
            return .handled
        }
        .quickLookPreview($preview)
        .draggable(url)
        .contextMenu {
            if exists {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Quick Look") { preview = url }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                ShareLink(item: url)
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
        .help(exists ? "Double-click to open, Space for Quick Look" : path)
    }

    private var relativePath: String { ProjectPath.relative(path, to: workingDirectory) }
}
