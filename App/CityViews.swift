import AppKit
import OfficeCore
import RealityKit
import SwiftUI

enum ProjectPicker {
    @MainActor static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a project folder. It becomes a building in your city."
        panel.prompt = "Add Project"
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func addProject() {
        guard let url = choose() else { return }
        let store = CityStore.shared
        let isNew = !store.buildings.contains { $0.path == url.path }
        let building = store.addBuilding(at: url)
        if isNew, store.route == .welcome || store.route == .city {
            store.groundBreaking = building.id
        } else {
            store.route = .building(building.id)
        }
    }
}

struct TitleHUD: View {
    let city: CityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Wordmark()
            Text("Every project is a building. Every floor is an office of Claude Code departments you set up once and come back to.")
                .font(Typography.body)
                .foregroundStyle(Color(Palette.muted))
                .frame(maxWidth: 460, alignment: .leading)
            Button("Break ground on your first project…") { ProjectPicker.addProject() }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(city.groundBreaking != nil)
            Button("Watch a Demo") { city.startDemo() }
                .buttonStyle(PillButtonStyle())
                .disabled(city.groundBreaking != nil)

            Text("Replays a recording — no tokens used.")
                .font(Typography.body)
                .foregroundStyle(Color(Palette.muted))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(32)
    }
}

struct CityHUD: View {
    let city: CityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Wordmark(compact: true)
                Spacer()
                UsageHUD(configDirectory: Preferences.shared.configDirectory)
                Button("New project…", systemImage: "plus") { ProjectPicker.addProject() }
                    .buttonStyle(PillButtonStyle())
            }
            NeedsYouList(city: city)
            Spacer()
            ProjectList(city: city)
        }
        .padding(20)
    }
}

/// Floors waiting on you, across the whole city, so nothing is missed while you're elsewhere.
struct NeedsYouList: View {
    let city: CityStore

    var body: some View {
        let waiting = city.buildings.flatMap { building in
            building.floors.compactMap { floor -> (CityStore.Building, CityStore.Floor, Int)? in
                let count = city.sessions[floor.id]?.state.pendingRequests.count ?? 0
                return count > 0 ? (building, floor, count) : nil
            }
        }
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Needs you").eyebrow()
                ForEach(waiting, id: \.1.id) { building, floor, count in
                    Button("\(building.name) · \(floor.name) · \(count)", systemImage: "hand.raised.fill") {
                        city.route = .floor(building: building.id, floor: floor.id)
                    }
                    .buttonStyle(PillButtonStyle(kind: .accent(Palette.manager)))
                }
            }
            .glass()
            .frame(maxWidth: 360, alignment: .leading)
        }
    }
}

/// A keyboard- and VoiceOver-friendly way into every building, alongside the 3D city.
struct ProjectList: View {
    let city: CityStore

    var body: some View {
        HStack(spacing: 8) {
            ForEach(city.buildings) { building in
                let status = city.status(of: building)
                Button {
                    city.route = .building(building.id)
                } label: {
                    Label(building.name, systemImage: status.waiting > 0 ? "hand.raised.fill" : status.working > 0 ? "bolt.fill" : "building.2")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([building.url]) }
                    Button("Remove from City") { city.removeBuilding(building.id) }
                        .disabled(status.working > 0)
                }
                .accessibilityLabel("\(building.name), \(building.floors.count) floors\(status.working > 0 ? ", \(status.working) working" : "")\(status.waiting > 0 ? ", needs you" : "")")
            }
        }
        .modifier(Glass(radius: 24, padding: EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)))
    }
}

struct WorldView: View {
    let city: CityStore
    @State private var world = World()
    @State private var since: Date?
    @Environment(\.colorScheme) private var colorScheme

    private var buildingID: UUID? {
        switch city.route {
        case .building(let id), .floor(let id, _), .newFloor(let id): id
        default: nil
        }
    }

    private var floorID: UUID? {
        if case .floor(_, let floor) = city.route { floor } else { nil }
    }

    private var dark: Bool { colorScheme == .dark && BrandStore.shared.current.supportsDark }

    var body: some View {
        let buildingID = buildingID, floorID = floorID
        let session = floorID.flatMap { id in buildingID.flatMap { city.session(for: id, in: $0) } }
        ZStack {
            GeometryReader { geometry in
                RealityView { content in
                    content.add(world.root)
                    content.renderingEffects.antialiasing = .multisample4X
                    world.updates = content.subscribe(to: SceneEvents.Update.self) { [world] event in world.update(event.deltaTime) }
                }
                .realityViewCameraControls(.none)
                .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in tapped(value.entity) })
                .onContinuousHover { phase in
                    if case .active(let point) = phase, world.inBuilding == nil { world.city.hover(at: point) } else { world.city.hover(at: nil) }
                }
                .modifier(SceneControls(camera: { [world] in world.camera },
                                        excludedTrailing: session?.showPanel == true ? OfficeView.panelWidth + 40 : 0,
                                        onScroll: { [city, world] event in
                                            guard case .building = city.route, world.inBuilding != nil, !event.modifierFlags.contains(.option) else { return false }
                                            world.building.scroll(by: Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10))
                                            return true
                                        },
                                        passThrough: { [city] in if case .newFloor = city.route { true } else { false } }))
                .onAppear {
                    world.city.titleMode = city.route == .welcome
                    world.city.build(city.buildings, dark: dark)
                    world.fit(geometry.size)
                    sync(animated: false)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                    guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("office") == true else { return }
                    world.paused = !window.occlusionState.contains(.visible)
                }
                .onChange(of: geometry.size) { world.fit(geometry.size) }
                .onChange(of: city.buildings.map(\.id)) {
                    if city.groundBreaking != nil { world.city.titleMode = false }
                    world.city.build(city.buildings, dark: dark)
                    world.cityRebuilt()
                    if let id = city.groundBreaking { breakGround(id) }
                }
                .onChange(of: city.route) {
                    guard world.city.titleMode, city.route != .welcome else { return }
                    world.city.titleMode = false
                    world.city.build(city.buildings, dark: dark)
                }
                .onChange(of: buildingID) { sync(animated: true) }
                .onChange(of: floorID) {
                    guard world.inBuilding == buildingID, buildingID != nil else { return }
                    if let floorID { world.building.enter(floor: floorID) } else { world.building.leaveFloor() }
                }
                .onChange(of: billboardTitle) { if let buildingID { show(buildingID) } }
                .onChange(of: buildingID.flatMap { city.building($0)?.floors.map(\.id) } ?? []) {
                    guard let buildingID, world.inBuilding == buildingID else { return }
                    show(buildingID)
                    world.cityRebuilt()
                    if let floorID { world.building.enter(floor: floorID) }
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)

            if let buildingID, let session, let floorScene = world.building.scene(for: session.floorID ?? UUID()) {
                OfficeOverlay(controller: session, scene: floorScene, onBack: { city.route = .building(buildingID) },
                              onClose: { city.removeFloor(session.floorID ?? UUID(), in: buildingID) })
            } else if let buildingID, let building = city.building(buildingID) {
                BuildingHUD(city: city, building: building, since: since, scene: world.building)
            } else if city.route == .welcome {
                TitleHUD(city: city)
            } else {
                CityHUD(city: city)
            }
        }
    }

    private func tapped(_ entity: Entity) {
        if let buildingID, world.inBuilding == buildingID {
            if let floorID, world.building.floor(of: entity) == floorID, let session = city.session(for: floorID, in: buildingID) {
                if let room = OfficeScene.room(of: entity), room != "outbox", room != session.selectedRoom { session.select(room: room) } else { session.selectedRoom = nil }
                return
            }
            if let tapped = world.building.floor(of: entity), tapped != floorID {
                city.route = .floor(building: buildingID, floor: tapped)
                return
            }
        }
        guard let target = CityScene.target(of: entity) else { return }
        if target == "lot:new" { return ProjectPicker.addProject() }
        guard let id = UUID(uuidString: String(target.dropFirst("building:".count))), id != buildingID else { return }
        if world.inBuilding == nil {
            world.city.flyTowards(id)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(OfficeScene.reduceMotion ? 0 : 450))
                city.route = .building(id)
            }
        } else {
            city.route = .building(id)
        }
    }

    private var billboardTitle: String? { buildingID.flatMap { city.building($0)?.title } }

    private func show(_ id: UUID) {
        guard let building = city.building(id) else { return }
        let sessions = building.floors.compactMap { floor in city.session(for: floor.id, in: id).map { (floor.id, $0) } }
        world.building.show(building, sessions: sessions, dark: dark)
    }

    private func breakGround(_ id: UUID) {
        world.city.riseBuilding(id)
        world.city.flyTowards(id)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(OfficeScene.reduceMotion ? 0.2 : CityScene.riseTime + 0.3))
            city.groundBreaking = nil
            city.route = .building(id)
        }
    }

    private func sync(animated: Bool) {
        let target = buildingID
        guard target != world.inBuilding else { return }
        if let previous = world.inBuilding {
            city.visit(previous)
            world.leave(animated: animated && target == nil)
        }
        guard let target else { return }
        since = city.visit(target)
        show(target)
        world.enter(target, animated: animated)
        if let floorID { world.building.enter(floor: floorID) }
    }
}

struct BuildingHUD: View {
    let city: CityStore
    let building: CityStore.Building
    var since: Date?
    let scene: BuildingScene
    @State private var composerSize = CGSize(width: 592, height: 120)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Button("City", systemImage: "chevron.backward") { city.route = .city }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                UsageHUD(configDirectory: Preferences.shared.configDirectory)
                OpenInMenu(directory: building.url)
                Button("New floor…", systemImage: "plus") { city.startNewFloor(in: building.id) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help("Set up a floor yourself instead of asking reception")
            }
            Text(building.name).font(Typography.titleSmall)
            Text(building.floors.isEmpty ? "Tell reception what you need. It sets up a floor with the right team." : "Scroll to move between floors. Click one to go in, or ask reception below.")
                .font(Typography.caption).foregroundStyle(Color(Palette.muted))
            Spacer()
            if let since { SinceYouLeftNote(city: city, building: building, since: since) }
            HStack(alignment: .bottom) {
                Color.clear.frame(width: composerSize.width, height: composerSize.height)
                Spacer(minLength: 12)
                if !building.floors.isEmpty { FloorList(city: city, building: building) }
            }
        }
        .padding(20)
        .overlay {
            GeometryReader { geometry in
                TimelineView(.animation(paused: !scene.lobbyFocused)) { _ in
                    let resting = CGPoint(x: 20 + composerSize.width / 2, y: geometry.size.height - 20 - composerSize.height / 2)
                    let head = scene.lobbyFocused ? scene.receptionistPoint : nil
                    let pinned = head.map { head in
                        CGPoint(x: min(head.x + 60 + composerSize.width / 2, geometry.size.width - 20 - composerSize.width / 2),
                                y: min(max(head.y, 20 + composerSize.height / 2), geometry.size.height - 20 - composerSize.height / 2))
                    }
                    Group {
                        if let draft = city.draft, draft.buildingID == building.id, city.route == .newFloor(building.id) {
                            HiringView(controller: draft) { city.cancelNewFloor() }
                                .frame(width: 620)
                                .glass(padding: 16)
                                .onAppear { scene.receptionist(thinking: false, pointingAt: nil, scaffold: true) }
                                .onDisappear { scene.receptionist(thinking: false, pointingAt: nil, scaffold: false) }
                        } else {
                            ReceptionComposer(city: city, building: building, scene: scene)
                        }
                    }
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { composerSize = $0 }
                        .position(pinned ?? resting)
                        .animation(OfficeScene.reduceMotion ? nil : .easeOut(duration: 0.3), value: pinned == nil)
                }
            }
        }
    }
}

struct SinceYouLeftNote: View {
    let city: CityStore
    let building: CityStore.Building
    let since: Date

    var body: some View {
        let jobs = city.jobs(in: building, since: since)
        let waiting = building.floors.filter { (city.sessions[$0.id]?.state.pendingRequests.count ?? 0) > 0 }
        if !jobs.isEmpty || !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Since you left").eyebrow()
                ForEach(waiting) { floor in
                    line(symbol: "hand.raised.fill", text: "\(floor.name) is waiting for you", floor: floor.id)
                }
                ForEach(jobs.prefix(6)) { job in
                    let cost = job.costUSD.map { " · \($0.formatted(.currency(code: "USD")))" } ?? ""
                    let floor = job.floorID.flatMap { id in building.floors.first { $0.id == id } }
                    line(symbol: job.outcome == "completed" ? "checkmark.circle.fill" : "xmark.circle.fill",
                         text: "\(floor.map { "\($0.name): " } ?? "")\(job.request)\(job.outcome == "completed" ? "" : " (\(job.outcome))")\(cost)",
                         floor: floor?.id)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .glass()
        }
    }

    private func line(symbol: String, text: String, floor: UUID?) -> some View {
        Button {
            if let floor { city.route = .floor(building: building.id, floor: floor) }
        } label: {
            Label(text, systemImage: symbol)
                .font(Typography.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(floor == nil)
        .help(text)
    }
}

struct FloorList: View {
    let city: CityStore
    let building: CityStore.Building
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var closing: ClosingFloor?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(building.floors.reversed()) { floor in
                let session = city.sessions[floor.id]
                Button {
                    city.route = .floor(building: building.id, floor: floor.id)
                } label: {
                    Label(floor.name, systemImage: (session?.state.pendingRequests.isEmpty == false) ? "hand.raised.fill" : session?.isRunning == true ? "bolt.fill" : "square.stack.3d.up")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .contextMenu {
                    Button("Rename…") {
                        newName = floor.name
                        renaming = floor.id
                    }
                    Button("Close Floor…") { closing = ClosingFloor(id: floor.id, name: floor.name) }
                }
            }
        }
        .modifier(Glass(radius: 24, padding: EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)))
        .alert("Rename floor", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { city.renameFloor(renaming, in: building.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .modifier(CloseFloorConfirmation(floor: $closing, running: closing.map { city.sessions[$0.id]?.isRunning == true } ?? false) {
            city.removeFloor($0.id, in: building.id)
        })
    }
}

/// The building's front desk: say what you need, and reception sends it to the right floor.
struct ReceptionComposer: View {
    let city: CityStore
    let building: CityStore.Building
    var scene: BuildingScene?
    @State private var text = RunController.launchArgument("-request") ?? ""
    @State private var suggestion: RoutingSuggestion?
    @State private var thinking = false
    @State private var asked = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PromptEditor(address: [building.name, "Reception", "picks the right floor"],
                         placeholder: "What do you need done in \(building.name)?",
                         directory: building.url, text: $text, canSend: canAsk, send: ask) { withImages in
                Button("Ask reception", action: withImages(ask))
                    .buttonStyle(PillButtonStyle())
                    .disabled(!canAsk)
            }
            if thinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("The receptionist is checking which floor fits…").font(Typography.caption).foregroundStyle(Color(Palette.muted))
                }
            } else if let suggestion {
                suggestionView(suggestion)
            }
        }
        .frame(width: 620, alignment: .leading)
        .glass(padding: 16)
        .onChange(of: text) { if text != asked { suggestion = nil } }
        .onChange(of: text.isEmpty) {
            if !text.isEmpty { scene?.focusLobby() } else if suggestion == nil { scene?.leaveLobby() }
        }
        .onChange(of: thinking) { gesture() }
        .onChange(of: suggestion) { gesture() }
    }

    private func gesture() {
        scene?.receptionist(thinking: thinking, pointingAt: suggestion?.floorID, scaffold: suggestion != nil && suggestion?.floorID == nil)
    }

    private var canAsk: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !thinking }

    @ViewBuilder
    private func suggestionView(_ suggestion: RoutingSuggestion) -> some View {
        let match = suggestion.floorID.flatMap { id in building.floors.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 10) {
            Text("“\(suggestion.reason)”").font(Typography.caption).foregroundStyle(Color(Palette.muted))
            HStack(spacing: 8) {
                if let match {
                    Button("Send to \(match.name)", systemImage: "arrow.up.circle.fill") { send(to: match.id) }
                        .buttonStyle(PillButtonStyle())
                    Button("Set up “\(suggestion.newFloorName)” instead") { newFloor(suggestion.newFloorName) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                } else {
                    Button("Set up “\(suggestion.newFloorName)”", systemImage: "plus.circle.fill") { newFloor(suggestion.newFloorName) }
                        .buttonStyle(PillButtonStyle())
                }
                let others = building.floors.filter { $0.id != match?.id }
                if !others.isEmpty {
                    Menu("Another floor") {
                        ForEach(others) { floor in
                            Button(floor.name + (city.sessions[floor.id]?.isRunning == true ? " (busy, will queue)" : "")) { send(to: floor.id) }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .fixedSize()
                }
            }
            if let match, city.sessions[match.id]?.isRunning == true {
                Text("\(match.name) is busy; this will start when its current job finishes.")
                    .font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
        }
    }

    private func ask() {
        guard canAsk else { return }
        if let (floor, rest) = directFloor(), !rest.isEmpty {
            text = rest
            return send(to: floor.id)
        }
        asked = text
        thinking = true
        let request = text
        let floors = building.floors
        Task {
            let result = await ReceptionDesk.route(request: request, floors: floors)
            if asked == request { suggestion = result }
            thinking = false
        }
    }

    /// "@Floor name request" skips routing; the longest matching floor name wins.
    private func directFloor() -> (CityStore.Floor, String)? {
        guard text.hasPrefix("@") else { return nil }
        let body = text.dropFirst()
        let match = building.floors
            .filter { body.lowercased().hasPrefix($0.name.lowercased()) }
            .max { $0.name.count < $1.name.count }
        return match.map { ($0, body.dropFirst($0.name.count).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func send(to floorID: UUID) {
        city.send(text, toFloor: floorID, in: building.id)
        text = ""
        suggestion = nil
        scene?.leaveLobby()
    }

    private func newFloor(_ name: String) {
        city.startNewFloor(in: building.id, request: text, name: name)
        text = ""
        suggestion = nil
    }
}

struct ClosingFloor: Equatable {
    let id: UUID
    let name: String
}

/// Asks before a floor and its team are closed, and warns when that cancels a job.
struct CloseFloorConfirmation: ViewModifier {
    @Binding var floor: ClosingFloor?
    let running: Bool
    let close: (ClosingFloor) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Close \(floor?.name ?? "floor")?", isPresented: Binding(get: { floor != nil }, set: { if !$0 { floor = nil } }), presenting: floor) { floor in
            Button(running ? "Cancel Job and Close" : "Close Floor", role: .destructive) { close(floor) }
            Button("Keep", role: .cancel) {}
        } message: { _ in
            Text(running ? "Its current job will be cancelled. Past jobs stay in the building's history." : "The floor and its team are removed from the building. Past jobs stay in the building's history.")
        }
    }
}
