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
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 20) {
                Wordmark()
                Text("Every project is a building.")
                    .font(Typography.body)
                    .foregroundStyle(Color(Palette.muted))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Break ground on your first project…") { ProjectPicker.addProject() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(city.groundBreaking != nil)
                // Not `.link`: that's an AppKit control, which the offscreen README reel can't draw.
                Button { city.startDemo() } label: {
                    Text("Watch a demo").font(Typography.caption).underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(Palette.text))
                .disabled(city.groundBreaking != nil)
                    .help("Replays a recording — no tokens used.")
            }
            .padding(24)
            .frame(maxWidth: 400, alignment: .leading)
            .background(Color(Palette.glassTop).opacity(0.96), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color(Palette.hairline), lineWidth: 1))
            .shadow(color: Color(Palette.text).opacity(0.1), radius: 18, y: 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(32)
    }
}

struct CityHUD: View {
    let city: CityStore
    @Environment(\.sceneSafeArea) private var safeArea

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Breadcrumb.here(city)
                Spacer()
                Instruments(city: city, scope: .city(city.buildings), configDirectory: Preferences.shared.configDirectory)
                Button("New project…", systemImage: "plus") { ProjectPicker.addProject() }
                    .buttonStyle(PillButtonStyle())
            }
            Spacer()
            ProjectList(city: city)
        }
        .padding(20)
        .padding(.bottom, safeArea.bottom)
    }
}

/// Every other floor that needs you, across the whole city, most urgent first, in the same corner at every level.
struct DispatchRail: View {
    let city: CityStore
    /// For offscreen renders, whose buildings aren't in the store.
    var buildings: [CityStore.Building]?

    private var here: (building: UUID?, floor: UUID?) {
        switch city.route {
        case .building(let id), .newFloor(let id): (id, nil)
        case .floor(let building, let floor): (building, floor)
        default: (nil, nil)
        }
    }

    private var items: [CityStore.NeedsYou] { city.floorsNeedingYou(in: buildings).filter { $0.floor.id != here.floor } }

    var body: some View {
        let items = items
        if !items.isEmpty {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                ViewThatFits(in: .horizontal) {
                    ForEach((1...items.count).reversed(), id: \.self) { shown in
                        HStack(spacing: 8) {
                            ForEach(items.prefix(shown), id: \.floor.id) { chip($0, first: $0.floor.id == items[0].floor.id, now: context.date) }
                            if shown < items.count { more(items.dropFirst(shown), now: context.date) }
                        }
                        .fixedSize()
                    }
                }
                .modifier(Glass(radius: 24, padding: EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Needs you")
        }
    }

    private func name(_ item: CityStore.NeedsYou) -> String {
        item.building.id == here.building ? item.floor.name : "\(item.building.name) · \(item.floor.name)"
    }

    private func age(_ item: CityStore.NeedsYou, now: Date) -> String? {
        guard let since = item.since, now.timeIntervalSince(since) >= FloorSignal.ageAppearsAfter else { return nil }
        return FloorSignal.age(from: since, to: now)
    }

    private func escalated(_ item: CityStore.NeedsYou, now: Date) -> Bool {
        guard item.signal == .blocked, let since = item.since else { return false }
        return now.timeIntervalSince(since) >= FloorSignal.escalateAfter
    }

    private func spoken(_ item: CityStore.NeedsYou, now: Date) -> String {
        "\(item.building.name), \(item.floor.name), \(item.signal.label(count: item.count))\(item.signal.spokenAge(since: item.since, now: now))"
    }

    private func chip(_ item: CityStore.NeedsYou, first: Bool, now: Date) -> some View {
        Button {
            go(to: item)
        } label: {
            Label {
                if escalated(item, now: now) {
                    HStack(spacing: 8) {
                        Text(name(item))
                        Text("\(Int(FloorSignal.escalateAfter / 60))m+")
                            .font(Typography.captionMedium)
                            .foregroundStyle(Color(Palette.textOn(item.signal.colour)))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .background(Capsule().fill(Color(item.signal.colour)))
                            // Drawn into the pill's own padding so an escalated chip stays the height of the others.
                            .padding(.vertical, -4)
                    }
                } else if let age = age(item, now: now) {
                    Text("\(name(item)) \(Text(age).font(Typography.caption).monospacedDigit())")
                } else {
                    Text(name(item))
                }
            } icon: {
                Image(systemName: item.signal.symbol)
            }
        }
        .buttonStyle(PillButtonStyle(kind: escalated(item, now: now) ? .outline(item.signal.colour) : .accent(item.signal.colour)))
        .accessibilityLabel(spoken(item, now: now))
        .help("\(item.building.name) · \(item.floor.name) · \(item.signal.label(count: item.count))\(item.signal.ageSuffix(since: item.since, now: now))\(first ? " (⌘J)" : "")")
    }

    private func more(_ rest: ArraySlice<CityStore.NeedsYou>, now: Date) -> some View {
        Menu("+\(rest.count)") {
            ForEach(rest, id: \.floor.id) { item in
                Button("\(name(item))\(item.signal.ageSuffix(since: item.since, now: now))", systemImage: item.signal.symbol) { go(to: item) }
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PillButtonStyle(kind: .secondary))
        .fixedSize()
        .accessibilityLabel("\(rest.count) more")
        .help("\(rest.count) more floors need you")
    }

    private func go(to item: CityStore.NeedsYou) {
        city.leaveGlance(restoring: false)
        city.route = .floor(building: item.building.id, floor: item.floor.id)
    }
}

/// A keyboard- and VoiceOver-friendly way into every building, alongside the 3D city.
struct ProjectList: View {
    let city: CityStore
    @State private var removing: CityStore.Building?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(city.buildings) { building in
                let status = city.status(of: building)
                let signal = city.signal(of: building)
                Button {
                    city.route = .building(building.id)
                } label: {
                    Label(building.name, systemImage: signal.signal.symbol)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([building.url]) }
                    Button("Remove from City…") { removing = building }
                        .disabled(status.working > 0)
                }
                .accessibilityLabel("\(building.name), \(building.floors.count) floors, \(signal.signal.label(count: signal.count))\(signal.signal.spokenAge(since: signal.since))")
                .help("\(city.statusLine(for: building)). Rooms: \(city.live(on: building.floors).rooms.spoken).")
            }
        }
        .modifier(Glass(radius: 24, padding: EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)))
        .confirmationDialog("Remove \(removing?.name ?? "project") from the city?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { building in
            Button("Remove from City", role: .destructive) { city.removeBuilding(building.id) }
            Button("Keep", role: .cancel) {}
        } message: { building in
            Text("Its \(building.floors.count == 1 ? "floor and team are" : "\(building.floors.count) floors and their teams are") removed. The project folder and its files stay on disk.")
        }
    }
}

struct WorldView: View {
    let city: CityStore
    @State private var world = World()
    @State private var railHeight: CGFloat = 0
    @State private var glanceKeys: Any?
    @State private var autoGlance: Task<Void, Never>?
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
        let session = floorID.flatMap { city.sessions[$0] }
        let quality = GraphicsQuality.current
        ZStack {
            GeometryReader { geometry in
                RealityView { content in
                    content.add(world.root)
                    world.updates = content.subscribe(to: SceneEvents.Update.self) { [world] event in world.update(event.deltaTime) }
                } update: { content in
                    content.renderingEffects.antialiasing = quality.antialiasing
                    content.renderingEffects.depthOfField = quality.depthOfField ? .enabled : .disabled
                }
                .realityViewCameraControls(.none)
                .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in tapped(value.entity) })
                .onContinuousHover { phase in
                    if case .active(let point) = phase, world.inBuilding == nil { world.city.hover(at: point) } else { world.city.hover(at: nil) }
                }
                .modifier(SceneControls(camera: { [world] in world.camera },
                                        excludedTrailing: safeArea.trailing + 20,
                                        onScroll: { [city, world] event in
                                            guard world.inBuilding != nil, event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.option) else { return false }
                                            switch city.route {
                                            case .building: break
                                            case .floor where city.activeSession?.selectedRoom == nil: break
                                            default: return false
                                            }
                                            world.building.scroll(by: Float(event.scrollingDeltaY))
                                            if event.scrollingDeltaX != 0 { world.camera.pan(dx: Float(event.scrollingDeltaX), dy: 0) }
                                            return true
                                        },
                                        passThrough: { [city] in if case .newFloor = city.route { true } else { city.activeSession?.kiosk.isOpen == true } }))
                .onAppear {
                    world.city.titleMode = city.route == .welcome
                    world.rebuildCity(city.buildings, dark: dark)
                    world.fit(geometry.size)
                    sync(animated: false)
                    prewarm(city.buildings.map(\.id))
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                    guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("office") == true else { return }
                    world.paused = !window.occlusionState.contains(.visible)
                }
                .onChange(of: geometry.size) { world.fit(geometry.size) }
                .onReceive(NotificationCenter.default.publisher(for: .resetView)) { _ in world.camera.recentre() }
                .onChange(of: city.buildings.map { [$0.id] + $0.floors.map(\.id) }) { buildingsChanged() }
                .onChange(of: city.route) {
                    guard world.city.titleMode, city.route != .welcome else { return }
                    world.city.titleMode = false
                    world.rebuildCity(city.buildings, dark: dark)
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

            Group {
                if let buildingID, let session, let floorScene = world.building.scene(for: session.floorID ?? UUID()) {
                    OfficeOverlay(controller: session, scene: floorScene, breadcrumb: Breadcrumb.here(city),
                                  onClose: { city.removeFloor(session.floorID ?? UUID(), in: buildingID) })
                } else if let buildingID, let building = city.building(buildingID) {
                    BuildingHUD(city: city, building: building, scene: world.building)
                } else if city.route == .welcome {
                    TitleHUD(city: city)
                } else {
                    CityHUD(city: city)
                }
            }
            .opacity(city.glance ? 0 : 1)
            .allowsHitTesting(!city.glance)

            if city.glance {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { city.leaveGlance() }
                    .ignoresSafeArea()
                    .accessibilityLabel("Leave glance mode")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .onChange(of: city.glance, initial: true) {
            world.city.glancing = city.glance
            glanceKeys.map(NSEvent.removeMonitor)
            glanceKeys = city.glance ? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [city] event in
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifiers == [.command, .option], event.charactersIgnoringModifiers == "g" { return event }
                city.leaveGlance()
                return modifiers.contains(.command) ? event : nil
            } : nil
        }
        .onChange(of: city.floorsNeedingYou().first?.building.id, initial: true) { _, id in world.city.glanceFocus = id }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard Self.isOffice(note) else { return }
            autoGlance?.cancel()
            autoGlance = Task { @MainActor [city] in
                try? await Task.sleep(for: CityStore.glanceAfter)
                if !Task.isCancelled { city.enterGlance() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard Self.isOffice(note) else { return }
            autoGlance?.cancel()
            city.leaveGlance()
        }
        .environment(\.sceneSafeArea, safeArea)
        .overlay(alignment: .bottomLeading) {
            if showsRail {
                DispatchRail(city: city)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { railHeight = $0 }
                    .onDisappear { railHeight = 0 }
                    .padding(20)
                    .padding(.trailing, safeArea.trailing)
            }
        }
        .background {
            // Resolved on press, because a shortcut can keep the action from an earlier render.
            Button("Up One Level") { Breadcrumb.here(city).up?() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(Breadcrumb.here(city).up == nil || session?.kiosk.isOpen == true)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var safeArea: SceneSafeArea {
        let session = floorID.flatMap { city.sessions[$0] }
        return SceneSafeArea(panelOpen: session?.showPanel == true, rail: showsRail && railHeight > 0 ? railHeight + 12 : 0)
    }

    private static func isOffice(_ note: Notification) -> Bool {
        (note.object as? NSWindow)?.identifier?.rawValue.hasPrefix("office") == true
    }

    /// The desk and the kiosk take the whole frame, and the title screen has nothing to dispatch.
    private var showsRail: Bool {
        guard city.route != .welcome else { return false }
        guard let session = floorID.flatMap({ city.sessions[$0] }) else { return true }
        return session.selectedRoom == nil && !session.kiosk.isOpen
    }

    private func buildingsChanged() {
        if city.groundBreaking != nil { world.city.titleMode = false }
        // Rebuilding the whole city freezes the tower view, so wait until the city is seen again.
        if world.inBuilding != nil, city.groundBreaking == nil {
            world.cityStale = true
            return
        }
        world.rebuildCity(city.buildings, dark: dark)
        if let id = city.groundBreaking { breakGround(id) }
    }

    private func tapped(_ entity: Entity) {
        if let buildingID, world.inBuilding == buildingID {
            if floorID != nil, world.building.isReception(entity) {
                world.building.lobbyAfterLeaving = true
                city.route = .building(buildingID)
                return
            }
            if let floorID, world.building.floor(of: entity) == floorID, let session = city.session(for: floorID, in: buildingID) {
                if OfficeScene.room(of: entity) == OfficeScene.kioskRoom { session.takeOver() } else if let room = OfficeScene.room(of: entity), room != "outbox", room != session.selectedRoom { session.select(room: room) } else { session.selectedRoom = nil }
                return
            }
            if let tapped = world.building.floor(of: entity), tapped != floorID {
                city.route = .floor(building: buildingID, floor: tapped)
                return
            }
        }
        guard world.inBuilding == nil, let target = CityScene.target(of: entity) else { return }
        if target == "lot:new" { return ProjectPicker.addProject() }
        guard let id = UUID(uuidString: String(target.dropFirst("building:".count))), id != buildingID else { return }
        prewarm([id])
        // Build the tower now, while the camera is still, so the route change mid-flight only reuses it.
        show(id)
        world.city.flyTowards(id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(OfficeScene.reduceMotion ? 0 : 450))
            city.route = .building(id)
        }
    }

    /// Builds each floor's session and office ahead of entry, a floor at a time, so the tap path only reuses them.
    private func prewarm(_ ids: [UUID]) {
        Task { @MainActor in
            await ModelLibrary.warm(ModelLibrary.officeModels)
            _ = ModelLibrary.environment("studio")
            _ = ModelLibrary.environment("sky")
            for id in ids {
                for floor in city.building(id)?.floors ?? [] where city.sessions[floor.id] == nil {
                    _ = city.session(for: floor.id, in: id)
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
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
        if world.cityStale { world.rebuildCity(city.buildings, dark: dark) }
        if let previous = world.inBuilding {
            city.visit(previous)
            world.leave(animated: animated && target == nil)
        }
        guard let target else { return }
        city.visit(target)
        show(target)
        world.enter(target, animated: animated)
        if let floorID { world.building.enter(floor: floorID) }
    }
}

struct BuildingHUD: View {
    let city: CityStore
    let building: CityStore.Building
    let scene: BuildingScene
    var composer: ReceptionComposer?
    @State private var composerSize = CGSize(width: 592, height: 120)
    @Environment(\.sceneSafeArea) private var safeArea

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                topRow(compact: false, iconsOnly: false)
                topRow(compact: true, iconsOnly: false)
                topRow(compact: true, iconsOnly: true)
            }
            Text(building.floors.isEmpty ? "Tell reception what you need. It sets up a floor with the right team." : "Swipe up or down on the trackpad to move between floors. Click one to go in, or ask reception below.")
                .font(Typography.caption).foregroundStyle(Color(Palette.muted))
            Spacer()
            HStack(alignment: .bottom) {
                Color.clear.frame(width: composerSize.width, height: composerSize.height)
                Spacer(minLength: 12)
                if !building.floors.isEmpty { FloorList(city: city, building: building) }
            }
        }
        .padding(20)
        .padding(.bottom, safeArea.bottom)
        .overlay {
            GeometryReader { geometry in
                // Built outside the timeline, so following the receptionist only moves the panel instead of re-running its body every frame.
                let panel = Group {
                    if let draft = city.draft, draft.buildingID == building.id, city.route == .newFloor(building.id) {
                        HiringView(controller: draft) { city.cancelNewFloor() }
                            .frame(width: 620)
                            .glass(padding: 16)
                            .onAppear { scene.receptionist(thinking: false, pointingAt: nil, scaffold: true) }
                            .onDisappear { scene.receptionist(thinking: false, pointingAt: nil, scaffold: false) }
                    } else {
                        composer ?? ReceptionComposer(city: city, building: building, scene: scene)
                    }
                }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { composerSize = $0 }
                TimelineView(.animation(paused: !scene.watch.lobbyFocused)) { _ in
                    let bottom = geometry.size.height - 20 - safeArea.bottom - composerSize.height / 2
                    let resting = CGPoint(x: 20 + composerSize.width / 2, y: bottom)
                    let head = scene.lobbyFocused ? scene.receptionistPoint : nil
                    let pinned = head.map { head in
                        CGPoint(x: min(head.x + 60 + composerSize.width / 2, geometry.size.width - 20 - composerSize.width / 2),
                                y: min(max(head.y, 20 + composerSize.height / 2), bottom))
                    }
                    panel
                        .position(pinned ?? resting)
                        .animation(OfficeScene.reduceMotion ? nil : .easeOut(duration: 0.3), value: pinned == nil)
                }
            }
        }
    }

    /// Narrower windows first drop the wordmark's name, then the button labels.
    private func topRow(compact: Bool, iconsOnly: Bool) -> some View {
        HStack(alignment: .top) {
            Breadcrumb.here(city).compact(compact)
            Spacer()
            Instruments(city: city, scope: .building(building), configDirectory: Preferences.shared.configDirectory)
            Group {
                OpenInMenu(directory: building.url)
                Button("New floor…", systemImage: "plus") { city.startNewFloor(in: building.id) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help(iconsOnly ? "New floor: set up a floor yourself instead of asking reception" : "Set up a floor yourself instead of asking reception")
            }
            .modifier(IconOnly(on: iconsOnly))
        }
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
                    Label(floor.name, systemImage: city.signal(of: floor).symbol)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .help(floorStatus(floor, session: session))
                .accessibilityLabel("\(floor.name), \(floorStatus(floor, session: session))")
                .contextMenu {
                    Button("Rename…") {
                        newName = floor.name
                        renaming = floor.id
                    }
                    Divider()
                    FloorSettingsMenus(city: city, building: building, floor: floor)
                    Divider()
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

    private func floorStatus(_ floor: CityStore.Floor, session: RunController?) -> String {
        let rooms = city.live(on: [floor]).rooms.spoken
        let signal = city.signal(of: floor)
        let pending = session?.state.pendingRequests ?? []
        let since = signal == .blocked ? pending.map(\.since).min() : floor.unseenSince
        let label = signal == .working ? "Working\(session?.currentStep.map { ": \($0)" } ?? "")" : signal.label(count: pending.count)
        return "\(label)\(signal.spokenAge(since: since)). \(rooms)."
    }
}

/// A floor's account, model and budget, which its next job uses.
struct FloorSettingsMenus: View {
    let city: CityStore
    let building: CityStore.Building
    let floor: CityStore.Floor

    var body: some View {
        let session = city.sessions[floor.id]
        let account = floor.configDirectory.map { URL(fileURLWithPath: $0) } ?? Preferences.shared.configDirectory
        let models = ((session?.kit ?? RunController.cachedKit(for: building.url, configDirectory: account))?.models ?? [])
            .filter { $0.value != "default" }
        Menu("Account: \(Preferences.accountName(account))") {
            ForEach(Preferences.shared.visibleAccounts(including: account), id: \.self) { url in
                Button(UsageStore.shared.summary(url)) { change { $0.configDirectory = url?.path } }
            }
        }
        Menu("Model: \(floor.model.map { value in models.first { $0.value == value }?.displayName ?? value.capitalized } ?? "Default")") {
            Button("Default") { change { $0.model = nil } }
            ForEach(models) { model in
                Button(model.displayName) { change { $0.model = model.value } }
            }
        }
        Menu("Budget: \(floor.budgetUSD.formatted(.currency(code: "USD")))") {
            ForEach(RunController.budgets, id: \.self) { budget in
                Button(budget.formatted(.currency(code: "USD"))) { change { $0.budgetUSD = budget } }
            }
        }
    }

    private func change(_ edit: (inout CityStore.Floor) -> Void) {
        city.changeSettings(of: floor.id, in: building.id, edit)
    }
}

/// The building's front desk: say what you need, and reception sends it to the right floor.
struct ReceptionComposer: View {
    let city: CityStore
    let building: CityStore.Building
    var scene: BuildingScene?
    @State var text = RunController.launchArgument("-request") ?? ""
    @State var suggestion: RoutingSuggestion?
    @State private var thinking = false
    @State private var asked = ""
    @State private var routing: Task<Void, Never>?
    @State private var place: JobPlace?
    @State private var branches: Git.Branches?
    /// The floor a send is waiting on, kept while its Claude Code check fails so its readiness row shows here.
    @State private var target: RunController?
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PromptEditor(address: [building.name, "Reception", "picks the right floor"],
                         placeholder: "What do you need done in \(building.name)?",
                         directory: building.url, text: $text, canSend: canAsk, commands: commands, send: ask) { withImages in
                if let branches { BranchMenu(branches: branches, selection: $place) }
                Button("Ask reception", action: withImages(ask))
                    .buttonStyle(PillButtonStyle())
                    .disabled(!canAsk)
            }
            .onAppear {
                if let request = city.cancelledRequests.removeValue(forKey: building.id) { text = request }
            }
            if thinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("The receptionist is checking which floor fits…").font(Typography.caption).foregroundStyle(Color(Palette.muted))
                }
                suggestionView(RoutingSuggestion(floorID: nil, newFloorName: CityStore.floorName(for: ReceptionDesk.topic(of: text, commands: commands), existing: building.floors.map(\.name)), reason: ""))
                    .disabled(true)
            } else if let suggestion {
                suggestionView(suggestion)
            }
        }
        .frame(width: 620, alignment: .leading)
        .glass(padding: 16)
        .task(id: building.id) { city.loadCommands(for: building) }
        .task(id: building.path) { branches = await Git.branches(in: building.url) }
        .onChange(of: text) { if text != asked { suggestion = nil } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard let target, target.readiness != .ready else { return }
            target.checkReadiness()
        }
        .onChange(of: text.isEmpty) {
            if !text.isEmpty {
                scene?.focusLobby()
                ReceptionDesk.prewarm(floors: building.floors)
                HiringDesk.prewarm(catalogue: AgentCatalogue.load(workingDirectory: building.url))
            } else if suggestion == nil { scene?.leaveLobby() }
        }
        .onChange(of: thinking) { gesture() }
        .onChange(of: suggestion) {
            target = nil
            gesture()
        }
    }

    private func gesture() {
        scene?.receptionist(thinking: thinking, pointingAt: suggestion?.floorID, scaffold: suggestion != nil && suggestion?.floorID == nil)
    }

    private var canAsk: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !thinking && !sending }

    /// A floor whose Claude Code check has failed can't take the job; one still checking is waited on when sending.
    private func canSend(to floorID: UUID) -> Bool {
        guard !sending else { return false }
        guard let readiness = city.sessions[floorID]?.readiness else { return true }
        return readiness == .ready || readiness == .checking
    }

    private var commands: [CommandInfo] { city.commands[building.id] ?? [] }

    @ViewBuilder
    private func suggestionView(_ suggestion: RoutingSuggestion) -> some View {
        let match = suggestion.floorID.flatMap { id in building.floors.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 10) {
            if !suggestion.reason.isEmpty {
                Text("“\(suggestion.reason)”").font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    routeButtons(suggestion, match: match)
                    otherButtons(suggestion, match: match)
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { routeButtons(suggestion, match: match) }.fixedSize()
                    HStack(spacing: 8) { otherButtons(suggestion, match: match) }.fixedSize()
                }
            }
            if match != nil {
                Text("Same team and settings. Starts without the last job’s conversation.")
                    .font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
            if let match, city.sessions[match.id]?.isRunning == true {
                Text("\(match.name) is busy; this will start when its current job finishes.")
                    .font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
            if let session = target ?? match.flatMap({ city.sessions[$0.id] }) {
                ReadinessRow(controller: session)
            }
        }
    }

    @ViewBuilder
    private func routeButtons(_ suggestion: RoutingSuggestion, match: CityStore.Floor?) -> some View {
        if let match {
            Button("New job on \(match.name)", systemImage: "arrow.up.circle.fill") { send(to: match.id) }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend(to: match.id))
            if city.canContinue(match) {
                Button("Continue \(match.name)’s last job") { send(to: match.id, continuing: true) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(!canSend(to: match.id))
            }
        } else {
            Button("Set up “\(suggestion.newFloorName)”", systemImage: "plus.circle.fill") { newFloor(suggestion) }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    @ViewBuilder
    private func otherButtons(_ suggestion: RoutingSuggestion, match: CityStore.Floor?) -> some View {
        if match != nil {
            Button("Set up “\(suggestion.newFloorName)” instead") { newFloor(suggestion) }
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        let others = building.floors.filter { $0.id != match?.id }
        if !others.isEmpty {
            Menu("Another floor") {
                ForEach(others) { floor in
                    Button(floor.name + (city.sessions[floor.id]?.isRunning == true ? " (busy, will queue)" : "")) { send(to: floor.id) }
                        .disabled(!canSend(to: floor.id))
                }
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle(kind: .secondary))
            .fixedSize()
        }
    }

    private func ask() {
        guard canAsk else { return }
        if let (floor, rest) = ReceptionDesk.directFloor(in: text, floors: building.floors), !rest.isEmpty {
            text = rest
            return send(to: floor.id)
        }
        asked = text
        let request = text
        let topic = ReceptionDesk.topic(of: request, commands: commands)
        if let (command, arguments) = SlashCommand.parse(request, commands: commands), arguments.isEmpty {
            suggestion = RoutingSuggestion(floorID: nil, newFloorName: CityStore.floorName(for: topic, existing: building.floors.map(\.name)),
                                           reason: "Choose a floor to run /\(command.name), or set up a new one.")
            return
        }
        thinking = true
        let floors = building.floors
        routing?.cancel()
        routing = Task {
            let result = await ReceptionDesk.route(request: topic, floors: floors)
            guard !Task.isCancelled else { return }
            if asked == request { suggestion = result }
            thinking = false
        }
    }

    private func stopRouting() {
        routing?.cancel()
        routing = nil
        thinking = false
        asked = ""
    }

    private func send(to floorID: UUID, continuing: Bool = false) {
        guard let session = city.session(for: floorID, in: building.id) else { return }
        stopRouting()
        sending = true
        let request = text
        Task {
            // Wait for the launch check, so a job isn't sent to a floor whose Claude Code is missing or signed out.
            let readiness = await session.settledReadiness()
            sending = false
            guard readiness == .ready else {
                target = session
                return
            }
            city.send(request, toFloor: floorID, in: building.id, continuing: continuing, place: place)
            text = ""
            suggestion = nil
            target = nil
            scene?.leaveLobby()
        }
    }

    private func newFloor(_ chosen: RoutingSuggestion) {
        stopRouting()
        city.startNewFloor(in: building.id, request: text, name: chosen.newFloorName, preset: FloorPreset.named(chosen.presetID), place: place)
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
            Text(running ? "Its current job will be cancelled. Past jobs stay in the building's history." : "The floor and its team are removed from the building, along with its worktree if that has no uncommitted changes. Past jobs stay in the building's history.")
        }
    }
}

private struct IconOnly: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.labelStyle(.iconOnly) } else { content }
    }
}
