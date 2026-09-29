import AppKit
import OfficeCore
import RealityKit
import SwiftUI

/// Orbit, pan, pinch, wheel, trackpad scrolling and arrow keys for any of the 3D views.
struct SceneControls: ViewModifier {
    let camera: () -> CameraRig
    var excludedTrailing: CGFloat = 0
    var onScroll: ((NSEvent) -> Bool)?
    var passThrough: () -> Bool = { false }
    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    @State private var monitors: [Any] = []
    @State private var resignObserver: NSObjectProtocol?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { value in
                let delta = CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height)
                lastDrag = value.translation
                if NSEvent.modifierFlags.contains(.shift) {
                    camera().pan(dx: Float(delta.width), dy: Float(delta.height))
                } else {
                    camera().orbit(dx: Float(delta.width), dy: Float(delta.height))
                }
            }.onEnded { _ in lastDrag = .zero })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                camera().zoom(by: Float(lastMagnification / value.magnification))
                lastMagnification = value.magnification
            }.onEnded { _ in lastMagnification = 1 })
            .onAppear {
                guard monitors.isEmpty else { return }
                monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    guard steers(event) else { return event }
                    if let onScroll, onScroll(event) { return nil }
                    if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.option) {
                        camera().pan(dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY))
                    } else {
                        let step = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08)
                        camera().zoom(by: 1 - step)
                    }
                    return nil
                } as Any)
                var panning = false
                monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp]) { event in
                    switch event.type {
                    case .rightMouseDown:
                        panning = steers(event)
                    case .rightMouseDragged where panning:
                        camera().pan(dx: Float(event.deltaX), dy: Float(event.deltaY))
                        return nil
                    default:
                        panning = false
                    }
                    return event
                } as Any)
                monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                    guard let steer = Self.steer(for: event) else { return event }
                    if event.type == .keyUp {
                        CameraRig.steering.remove(steer)
                        return event
                    }
                    guard let window = event.window, Self.isScene(window), !passThrough(),
                          event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                          !(window.firstResponder is NSText), !(window.firstResponder is NSTableView) else { return event }
                    CameraRig.steering.insert(steer)
                    return nil
                } as Any)
                resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { CameraRig.steering.removeAll() }
                }
            }
            .onDisappear {
                monitors.forEach(NSEvent.removeMonitor)
                monitors = []
                if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
                resignObserver = nil
                CameraRig.steering.removeAll()
            }
    }

    private static func isScene(_ window: NSWindow) -> Bool {
        window.isKeyWindow && window.sheetParent == nil && window.identifier?.rawValue.hasPrefix("office") == true
    }

    private func steers(_ event: NSEvent) -> Bool {
        guard let window = event.window, Self.isScene(window), let view = window.contentView else { return false }
        if passThrough() || event.locationInWindow.x > view.bounds.width - excludedTrailing { return false }
        let local = view.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
        return !Self.shelters.values.contains { $0.contains(point) }
    }

    private static func steer(for event: NSEvent) -> CameraRig.Steer? {
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": return .zoomIn
        case "-": return .zoomOut
        default: return nil
        }
    }
}

extension SceneControls {
    @MainActor static var shelters: [UUID: CGRect] = [:]
}

struct ScrollShelter: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SceneControls.shelters[id] = $0 }
            .onDisappear { SceneControls.shelters[id] = nil }
    }
}

extension View {
    func sheltersScroll() -> some View { modifier(ScrollShelter()) }
}

/// A standalone office (a new floor before it joins its building, or a replay).
struct OfficeView: View {
    @Bindable var controller: RunController
    static let panelWidth: CGFloat = 400

    var body: some View {
        let scene = controller.scene
        let quality = GraphicsQuality.current
        ZStack {
            GeometryReader { geometry in
                RealityView { content in
                    content.add(scene.root)
                    scene.updates = content.subscribe(to: SceneEvents.Update.self) { [scene] event in
                        scene.update(event.deltaTime)
                    }
                } update: { content in
                    content.renderingEffects.antialiasing = quality.antialiasing
                    content.renderingEffects.depthOfField = quality.depthOfField ? .enabled : .disabled
                }
                .realityViewCameraControls(.none)
                .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                    let room = OfficeScene.room(of: value.entity)
                    if room == OfficeScene.kioskRoom { controller.takeOver() } else if let room, room != "outbox", room != controller.selectedRoom { controller.select(room: room) } else { controller.selectedRoom = nil }
                })
                .modifier(SceneControls(camera: { [scene] in scene.camera }, excludedTrailing: controller.showPanel ? Self.panelWidth + 40 : 0,
                                        passThrough: { [controller] in controller.kiosk.isOpen }))
                .onAppear {
                    if RunController.launchArgument("-kiosk-smoke") != nil {
                        Task { @MainActor in
                            for _ in 0..<120 where !controller.kiosk.isOpen { try? await Task.sleep(for: .milliseconds(500)); controller.takeOver() }
                        }
                    }
                    scene.sunEnabled = true
                    scene.fit(geometry.size)
                }
                .onChange(of: geometry.size) { scene.fit(geometry.size) }
                .onReceive(NotificationCenter.default.publisher(for: .resetView)) { _ in scene.camera.recentre() }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
            OfficeOverlay(controller: controller, scene: scene)
        }
    }
}

/// Everything drawn over a floor: job card, counter, side panel, outbox and the floor composer.
struct OfficeOverlay: View {
    @Bindable var controller: RunController
    let scene: OfficeScene
    var breadcrumb: Breadcrumb?
    var onClose: (() -> Void)?
    var showsDeskRequests = true
    @State private var outboxCollapsed = false
    @State private var closing: ClosingFloor?
    @State private var bottomHeight: CGFloat = 0
    @Environment(\.sceneSafeArea) private var safeArea
    static var panelWidth: CGFloat { OfficeView.panelWidth }

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Office floor")
                .accessibilityChildren {
                    ForEach(controller.steps) { step in
                        Button("\(step.room.capitalized), \(step.status == .working ? "working" : step.status == .done ? "done" : "waiting")\(step.status == .waiting ? "" : ", " + RunController.spoken(StepPill.worked(step, now: RunController.now())))") {
                            controller.select(room: step.room)
                        }
                    }
                }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    if let breadcrumb {
                        HStack(spacing: 8) {
                            breadcrumb
                            floorMenu
                        }
                    }
                    if !controller.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, controller.state.phase != .idle {
                        JobCard(controller: controller)
                    }
                    Spacer()
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(spacing: 8) {
                        Button(controller.showPanel ? "Hide panel" : "Show panel", systemImage: "sidebar.right") { controller.showPanel.toggle() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .help(controller.showPanel ? "Hide the panel (⌘\\)" : "Show the panel: activity, rooms, and tools and skills (⌘\\)")
                        if controller.isRunning {
                            Button("Cancel") { controller.cancel() }
                                .buttonStyle(PillButtonStyle(kind: .secondary))
                        }
                        if !controller.isDemo {
                            Button("Take over", systemImage: "apple.terminal") { controller.takeOver() }
                                .buttonStyle(PillButtonStyle(kind: .secondary))
                                .disabled(!controller.canTakeOver)
                                .help(controller.canTakeOver ? "Open this floor’s Claude Code session in the terminal kiosk" : "Available once the current job finishes")
                        }
                    }
                    Instruments(city: .shared, scope: .floor(controller), configDirectory: controller.configDirectory)
                    if controller.showPanel {
                        SidePanel(controller: controller)
                            .frame(width: Self.panelWidth)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(20)
            .opacity(controller.kiosk.isOpen ? 0 : 1)
            .allowsHitTesting(!controller.kiosk.isOpen)

            if showsDeskRequests { DeskRequestLayer(controller: controller, scene: scene, bottomInset: bottomHeight + safeArea.bottom) }

            VStack(spacing: 12) {
                Spacer()
                VStack(spacing: 12) {
                    if controller.state.phase == .running {
                        StepBar(steps: controller.steps, raised: Set(controller.state.pendingRequests.map(\.room))) { controller.select(room: $0) }
                    }
                    if case .ended(let outcome) = controller.state.phase {
                        EndCard(controller: controller, outcome: outcome, collapsed: $outboxCollapsed)
                        if controller.floorID != nil { nextJob(compact: true) }
                    } else if controller.state.phase == .idle, !controller.isRunning, controller.floorID != nil {
                        nextJob(compact: false)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 + 20 }
            }
            .padding(.bottom, 20 + safeArea.bottom)
            .padding(.trailing, safeArea.trailing)
            .opacity(controller.kiosk.isOpen ? 0 : 1)
            .allowsHitTesting(!controller.kiosk.isOpen)

            if controller.kiosk.isOpen { KioskLayer(controller: controller, scene: scene) }
        }
        .sheet(isPresented: $controller.showHistory) { HistorySheet(controller: controller) }
        .modifier(CloseFloorConfirmation(floor: $closing, running: controller.isRunning) { _ in onClose?() })
        .confirmationDialog("\(controller.clash?.holder ?? "Another floor") is working in \(controller.clash?.folder ?? "this folder")",
                            isPresented: Binding(get: { controller.clash != nil }, set: { _ in }), presenting: controller.clash) { clash in
            if let base = clash.base { Button("Make a Worktree off \(base)") { controller.answerClash(.worktree) } }
            Button("Share the Folder Anyway") { controller.answerClash(.share) }
            Button("Cancel Job", role: .cancel) { controller.cancel() }
        } message: { clash in
            Text(clash.base == nil
                 ? "This follow-up has to resume where its session ran. Sharing means both jobs edit the same files at once."
                 : "Two jobs in one checkout edit the same files at once. A worktree gives this job its own copy of the branch.")
        }
        .onChange(of: controller.startedAt) { previous, _ in outboxCollapsed = previous != nil }
        .onChange(of: safeArea.trailing, initial: true) {
            scene.trailingInset = safeArea.trailing
            if let room = controller.selectedRoom { scene.focus(room: room) }
        }
        .onChange(of: controller.kiosk.isOpen) {
            if controller.kiosk.isOpen { scene.focusKiosk() } else if let room = controller.selectedRoom { scene.focus(room: room) } else { scene.showOverview() }
        }
        .onChange(of: controller.selectedRoom) {
            guard !controller.kiosk.isOpen else { return }
            if let room = controller.selectedRoom { scene.focus(room: room) } else { scene.showOverview() }
        }
    }

    @ViewBuilder
    private var floorMenu: some View {
        let history = controller.floorID != nil && !controller.history.isEmpty
        let closable = onClose != nil && controller.floorID != nil
        if history || closable {
            Menu {
                if history {
                    Button("History", systemImage: "clock.arrow.circlepath") { controller.showHistory = true }
                }
                if closable, let id = controller.floorID {
                    Button("Close Floor…", systemImage: "xmark") { closing = ClosingFloor(id: id, name: controller.displayTitle) }
                }
            } label: {
                Label("Floor", systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .buttonStyle(PillButtonStyle(kind: .secondary))
            .fixedSize()
            .help("This floor’s history, or close it")
        }
    }

    @ViewBuilder
    private func nextJob(compact: Bool) -> some View {
        if controller.isDemo { DemoEndCard(controller: controller) } else { FloorComposer(controller: controller, compact: compact).disabled(controller.kiosk.isAlive) }
    }
}

struct DemoEndCard: View {
    let controller: RunController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("That was a recording").eyebrow()
            Text("The demo replays a job that already ran. Your own projects run real jobs with Claude Code.")
                .font(Typography.caption).foregroundStyle(Color(Palette.muted))
            HStack(spacing: 8) {
                Button("Break ground on your own project…") { ProjectPicker.addProject() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                if let recording = CityStore.demoRecording {
                    Button("Watch again", systemImage: "arrow.counterclockwise") { controller.replay(recording) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .disabled(controller.isRunning)
                }
            }
        }
        .frame(width: 620, alignment: .leading)
        .glass(padding: 16)
    }
}

struct DeskRequestLayer: View {
    let controller: RunController
    let scene: OfficeScene
    var bottomInset: CGFloat = 0
    @State private var index = 0
    @State private var cardSize = CGSize(width: DeskCard.width, height: 200)
    @State private var returnTo: String??

    var body: some View {
        let pending = controller.state.pendingRequests
        let shown = pending.isEmpty ? nil : pending[min(index, pending.count - 1)]
        let room = shown?.room ?? controller.selectedRoom
        GeometryReader { geometry in
            if let room {
                let limit = geometry.size.width - (controller.showPanel ? OfficeView.panelWidth + 40 : 20)
                // Built outside the timeline, so each frame only moves the card; rebuilt inside, a fresh `NSColor` re-ran the card's body every frame.
                let card = VStack(alignment: .leading, spacing: 8) {
                    if let shown {
                        DeskCard(pending: shown, colour: controller.colour(for: shown.room), controller: controller)
                            .id(shown.id)
                    } else if room != "outbox" {
                        AgentCard(controller: controller, room: room)
                    }
                    if shown != nil, pending.count > 1 {
                        Button("\(pending.count - 1) more waiting", systemImage: "chevron.forward") {
                            index = (min(index, pending.count - 1) + 1) % pending.count
                        }
                        .labelStyle(TrailingIconLabelStyle())
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                TimelineView(.animation(paused: OfficeScene.reduceMotion && scene.camera.motion.settled)) { _ in
                    let start = scene.cardPoint(of: room) ?? CGPoint(x: geometry.size.width / 2 + 40, y: geometry.size.height / 2)
                    card
                        .position(x: min(max(start.x + cardSize.width / 2, cardSize.width / 2 + 20), limit - cardSize.width / 2),
                                  y: min(max(start.y, cardSize.height / 2 + 20), max(cardSize.height / 2 + 20, geometry.size.height - bottomInset - cardSize.height / 2 - 20)))
                }
                .transition(OfficeScene.reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(OfficeScene.reduceMotion ? nil : .easeOut(duration: 0.2), value: shown?.id ?? room)
        .onAppear { follow(shown) }
        .onChange(of: shown?.id) { follow(shown) }
    }

    private func follow(_ shown: PendingRequest?) {
        if let shown {
            if returnTo == nil { returnTo = .some(scene.focusedRoom) }
            scene.focus(room: shown.room)
        } else if let back = returnTo {
            returnTo = nil
            index = 0
            if let room = back { scene.focus(room: room) } else { scene.showOverview() }
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

/// On an idle floor: give the same team a new job, or pick the last one up again.
struct FloorComposer: View {
    let controller: RunController
    let compact: Bool
    @State private var text = ""
    @State private var place: JobPlace?
    @State private var branches: Git.Branches?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                Text(controller.displayTitle).eyebrow()
                Text(controller.hired.isEmpty ? "The manager works this floor alone." : "On staff: " + controller.hired.map { $0.name.capitalized }.joined(separator: ", "))
                    .font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
            PromptEditor(address: [controller.workingDirectory?.lastPathComponent ?? "Project", controller.displayTitle, continues ? "Follow-up on last job" : "New job"],
                         placeholder: continues ? "Ask for a change or a next step…" : "Give this floor a job…",
                         directory: controller.workingDirectory, text: $text,
                         canSend: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && controller.readiness == .ready,
                         commands: controller.kit?.commands ?? [], send: continues ? continueLast : startNew) { withImages in
                if let branches { BranchMenu(branches: branches, selection: $place, usual: controller.branch) }
                if continues {
                    Button("Start a new job", action: withImages(startNew))
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.readiness != .ready)
                    Button("Send", action: withImages(continueLast))
                        .buttonStyle(PillButtonStyle())
                        .disabled(controller.readiness != .ready)
                } else {
                    Button("Start job", action: withImages(startNew))
                        .buttonStyle(PillButtonStyle())
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.readiness != .ready)
                }
            }
            ReadinessRow(controller: controller)
            QueuedJobsRow(controller: controller)
        }
        .frame(width: 620, alignment: .leading)
        .glass(padding: 16)
        .task(id: controller.workingDirectory) { branches = if let folder = controller.workingDirectory { await Git.branches(in: folder) } else { nil } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard controller.readiness != .ready || controller.limitNotice != nil else { return }
            controller.checkReadiness()
            controller.clearLimitNoticeIfExpired()
        }
    }

    private var continues: Bool { compact && controller.canContinue }

    private func continueLast() {
        controller.followUp(text.isEmpty ? "Please continue where you left off." : text)
        text = ""
    }

    private func startNew() {
        controller.newJobOnFloor(text, place: place)
        text = ""
    }
}


struct JobCard: View {
    let controller: RunController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Job ticket").eyebrow()
            Text(controller.request)
                .font(Typography.caption)
                .help(controller.request)
                .textSelection(.enabled)
                .cappedScroll()
            if let branch = controller.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(Typography.caption)
                    .foregroundStyle(Color(Palette.muted))
                    .lineLimit(1)
                    .help("Worked on in \(controller.jobDirectory?.path ?? "the project folder")")
            }
            ForEach(Array(controller.followUps.enumerated()), id: \.offset) { _, text in
                Text("Then: \(text)")
                    .font(Typography.caption)
                    .foregroundStyle(Color(Palette.muted))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            PermissionModeMenu(controller: controller)
        }
        .frame(maxWidth: 300, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 18, trailing: 12))
        .background(TicketShape().fill(Color(Palette.glassTop)))
        .overlay(TicketShape().stroke(Color(Palette.hairline), lineWidth: 1))
    }
}

struct PermissionModeMenu: View {
    let controller: RunController

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases) { mode in
                Button {
                    controller.setPermissionMode(mode)
                } label: {
                    if mode == controller.permissionMode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                }
                .help(mode.detail)
            }
        } label: {
            Label("Permissions: \(controller.permissionMode.title)", systemImage: "checkmark.shield")
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(kind: .secondary))
        .fixedSize()
        .help(controller.permissionMode.detail)
    }
}

struct TicketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 12
        let notch: CGFloat = 3
        let edge = rect.maxY - notch
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: edge))
        let teeth = max(Int(rect.width / (notch * 4)), 1)
        let step = rect.width / CGFloat(teeth)
        for index in (0..<teeth).reversed() {
            let centre = rect.minX + step * (CGFloat(index) + 0.5)
            path.addLine(to: CGPoint(x: centre + notch, y: edge))
            path.addArc(center: CGPoint(x: centre, y: edge), radius: notch, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: edge))
        path.closeSubpath()
        return path
    }
}

struct StepBar: View {
    let steps: [Step]
    var raised: Set<String> = []
    let select: (String) -> Void

    var body: some View {
        if !steps.isEmpty {
            TimelineView(.animation(minimumInterval: 0.1, paused: !steps.contains { $0.status == .working })) { _ in
                HStack(spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        Button { select(step.room) } label: {
                            StepPill(number: index + 1, step: step, now: RunController.now(), raised: raised.contains(step.room))
                        }
                        .buttonStyle(.plain)
                        .help("Inspect \(step.room.capitalized)")
                    }
                }
            }
            .modifier(Glass(radius: 26, padding: EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)))
        }
    }
}

struct StepPill: View {
    let number: Int
    let step: Step
    let now: Date
    var raised = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if raised {
                    Image(systemName: RoomState.waiting.symbol)
                        .symbolEffect(.pulse, isActive: !OfficeScene.reduceMotion)
                } else {
                    Text(step.isContractor ? "+" : "\(number)")
                }
            }
                .font(Typography.captionMedium)
                .foregroundStyle(Color(Palette.textOn(step.colour)))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(step.colour)))
            Text(step.isContractor ? "Contractor" : step.room.capitalized)
                .help(step.room)
                .font(Typography.captionMedium)
                .foregroundStyle(step.status == .working ? Color(Palette.textOn(step.colour)) : Color(step.status == .waiting ? Palette.muted : Palette.text))
            if step.status != .waiting {
                Text(RunController.clock(worked))
                    .font(Typography.code)
                    .foregroundStyle(step.status == .working ? Color(Palette.textOn(step.colour)) : Color(Palette.muted))
            }
        }
        .padding(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 13))
        .background(Capsule().fill(step.status == .working ? Color(step.colour) : Color.clear))
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.isContractor ? "Contractor" : step.room.capitalized), \(raised ? "needs you, " : "")\(statusText)")
    }

    private var statusText: String {
        switch step.status {
        case .waiting: "waiting"
        case .working: "working for \(Int(worked)) seconds"
        case .done: "done in \(Int(worked)) seconds"
        }
    }

    private var worked: TimeInterval { Self.worked(step, now: now) }

    static func worked(_ step: Step, now: Date) -> TimeInterval {
        step.workedFor + (step.startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }
}

struct SidePanel: View {
    @Bindable var controller: RunController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                tab(controller.state.pendingRequests.isEmpty ? "Activity" : "Needs you · \(controller.state.pendingRequests.count)", .requests)
                tab("Room", .room)
                tab("Tools & skills", .kit)
            }
            .padding(4)
            .overlay(Capsule().strokeBorder(Color(Palette.hairline), lineWidth: 1))
            switch controller.panelTab {
            case .requests:
                if controller.state.pendingRequests.isEmpty {
                    ActivityFeed(controller: controller)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(controller.state.pendingRequests, id: \.id) { pending in
                                RequestCard(pending: pending, colour: controller.colour(for: pending.room),
                                            isFront: false, controller: controller)
                            }
                        }
                    }
                }
            case .room:
                RoomInspector(controller: controller)
            case .kit:
                KitPanel(controller: controller)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glass()
    }

    private func tab(_ title: String, _ value: RunController.PanelTab) -> some View {
        Button(title) { controller.panelTab = value }
            .buttonStyle(PillButtonStyle(kind: .tab(active: controller.panelTab == value)))
            .accessibilityAddTraits(controller.panelTab == value ? .isSelected : [])
    }
}

struct ActivityFeed: View {
    let controller: RunController

    var body: some View {
        if controller.activity.isEmpty {
            Text("Nothing needs you right now. Questions and approvals will appear here.")
                .font(Typography.caption)
                .foregroundStyle(Color(Palette.muted))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(controller.activity) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(Color(controller.colour(for: item.room))).frame(width: 22, height: 22)
                                Text(item.text).font(Typography.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(item.id)
                        }
                    }
                }
                .onChange(of: controller.activity.count) {
                    if let last = controller.activity.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

struct RoomInspector: View {
    let controller: RunController

    var body: some View {
        if let room = controller.selectedRoom {
            let handoffs = handoffs(for: room)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(room == "manager" ? "Manager" : room.capitalized)
                        .font(Typography.captionMedium)
                        .foregroundStyle(Color(Palette.textOn(controller.colour(for: room))))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(Color(controller.colour(for: room))))
                    if room == "manager" {
                        Text("The manager runs the job and briefs each department. Has briefed \(controller.state.handoffs.count) department\(controller.state.handoffs.count == 1 ? "" : "s") so far.")
                            .font(Typography.caption)
                            .foregroundStyle(Color(Palette.muted))
                    } else if handoffs.isEmpty {
                        Text("This room hasn’t been given any work yet.")
                            .font(Typography.caption)
                            .foregroundStyle(Color(Palette.muted))
                    }
                    ForEach(handoffs, id: \.toolUseID) { handoff in
                        HandoffDetail(handoff: handoff, showRoom: room == "contractor", friendly: controller.friendly, timing: controller.timings[handoff.toolUseID])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Click a room or a step to see its brief, the tools it used and its report.")
                .font(Typography.caption)
                .foregroundStyle(Color(Palette.muted))
        }
    }

    private func handoffs(for room: String) -> [Handoff] {
        guard room == "contractor" else { return controller.state.handoffs(in: room) }
        let hired = Set(controller.hired.map(\.name))
        return controller.state.handoffs.values.filter { !hired.contains($0.room) }.sorted { $0.toolUseID < $1.toolUseID }
    }
}

struct HandoffDetail: View {
    let handoff: Handoff
    let showRoom: Bool
    let friendly: (String) -> String
    var timing: HandoffTiming?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(showRoom ? "\(handoff.room): \(handoff.brief ?? "")" : handoff.brief ?? "Brief").font(Typography.bodyMedium)
            Text(status).eyebrow()
            if !figures.isEmpty {
                Text(figures).font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
            if let prompt = handoff.prompt {
                Text(prompt).font(Typography.caption).foregroundStyle(Color(Palette.muted)).textSelection(.enabled)
                    .cappedScroll()
            }
            if !handoff.tools.isEmpty {
                Text("Tools").eyebrow()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(handoff.tools.enumerated()), id: \.offset) { _, tool in
                        Text("\(friendly(tool.name))  \(tool.summary ?? "")")
                            .font(Typography.code)
                            .help(tool.summary ?? tool.name)
                    }
                }
                .cappedScroll(pinnedToTail: true)
            }
            if let report = handoff.report {
                Text("Report").eyebrow()
                Text(report).font(Typography.caption).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(radius: 12, padding: 10)
    }

    private var status: String {
        switch (handoff.phase, handoff.outcome) {
        case (.requested, _): "Handed over"
        case (.working, _): "Working" + (handoff.step.map { " · \($0)" } ?? "")
        case (.finished, .failed?): "Failed"
        case (.finished, .killed?): "Stopped"
        case (.finished, _): handoff.isBackground ? "Finished in the background" : "Finished"
        }
    }

    private var figures: String {
        let worked = timing.map { $0.worked(now: RunController.now()) } ?? 0
        return [handoff.model.map(ModelName.display), handoff.tokens.map { "\(StatusFormat.tokens($0)) tokens" },
                handoff.toolCallCount > 0 ? "\(handoff.toolCallCount) tool\(handoff.toolCallCount == 1 ? "" : "s")" : nil,
                worked >= 1 ? "worked \(RunController.clock(worked))" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct EventLogList: View {
    let entries: [LogEntry]
    @State private var expanded: Set<UUID> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(String(format: "+%.1fs", entry.elapsed))  \(tag(entry))")
                                .font(Typography.eyebrow)
                                .foregroundStyle(colour(entry))
                            Text(expanded.contains(entry.id) ? entry.text : entry.preview)
                                .font(Typography.code)
                                .lineLimit(expanded.contains(entry.id) ? nil : 2)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !expanded.insert(entry.id).inserted { expanded.remove(entry.id) }
                        }
                    }
                }
            }
            .onAppear { if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: entries.count) {
                if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func tag(_ entry: LogEntry) -> String {
        switch entry.kind {
        case .event(let tag): tag
        case .malformed(let reason): "malformed: \(reason)"
        case .app: "app"
        case .sent: "sent to CLI"
        }
    }

    private func colour(_ entry: LogEntry) -> Color {
        switch entry.kind {
        case .event: Color(Palette.muted)
        case .malformed: Color(Palette.error)
        case .app, .sent: Color(Palette.text)
        }
    }
}
