import AppKit
import OfficeCore
import RealityKit
import SwiftUI

/// A project's tower: its floors are the live office scenes, stacked, with one camera for the whole building.
@MainActor
final class BuildingScene {
    let root = Entity()
    private let tower = Entity()
    var showsGround = true
    private var rise: (from: Float, to: Float, elapsed: Double)?
    private var risen: Float = 1
    let camera = CameraRig(overview: .init(target: [0, 6, 0], yaw: 0.62, pitch: 0.2, distance: 60))
    var updates: EventSubscription?
    private(set) var buildingID: UUID?
    private var building: CityStore.Building?
    private(set) var activeFloor: UUID?
    private var storeys: [(id: UUID, scene: OfficeScene, index: Int)] = []
    private var labels: [UUID: (entity: Entity, text: String)] = [:]
    private var crown: [Entity] = []
    private var lobby: Pod?
    private var liftButtons: [ModelEntity] = []
    private var scaffold: Entity?
    private(set) var lobbyFocused = false {
        didSet { if !lobbyFocused { storeysHidden = false } }
    }
    private var storeysHidden = false {
        didSet { if storeysHidden != oldValue { hideStoreysForLobby() } }
    }
    private var liftSpot: SIMD3<Float> = .zero
    private var lobbyParts: [Entity] = []
    private let lobbyLight = Entity()
    private let groundLight = Entity()
    private let emptySun = Entity()
    private var daylightClock: Double = 0
    private var viewSize = CGSize(width: 1000, height: 700)
    private var labelClock: Double = 0
    private var dark = false
    static let storeyHeight = OfficeScene.wallHeight + OfficeScene.floorThickness
    private static let roofThickness: Float = 0.4

    init() {
        root.addChild(camera.entity)
        root.addChild(tower)
    }

    func show(_ building: CityStore.Building, sessions: [(UUID, RunController)], dark: Bool) {
        self.dark = dark
        buildingID = building.id
        self.building = building
        for storey in storeys where !sessions.contains(where: { $0.0 == storey.id }) {
            storey.scene.root.removeFromParent()
            storey.scene.root.components.remove(OpacityComponent.self)
        }
        tower.children.removeAll()
        storeys = []
        labels = [:]
        for (index, (id, session)) in sessions.enumerated() {
            let scene = session.scene
            scene.adopt(camera: camera)
            scene.root.removeFromParent()
            scene.root.position = [0, Float(index + 1) * Self.storeyHeight, 0]
            scene.isActive = false
            scene.fit(viewSize)
            scene.sunEnabled = index == 0
            tower.addChild(scene.root)
            storeys.append((id, scene, index))
        }
        lobbyParts = buildLobby(width: OfficeScene.footprint.x, depth: OfficeScene.footprint.y, floors: sessions.count)
        lobbyParts.forEach { $0.isEnabled = true }
        tower.addChild(lobbyLight)
        let receiver = ImageBasedLightReceiverComponent(imageBasedLight: lobbyLight)
        for entity in lobbyParts.flatMap({ [$0] + $0.descendants }) where entity.components.has(ModelComponent.self) {
            entity.components.set(receiver)
            entity.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: true))
        }
        let ground = CityScene.ground(dark: dark)
        ground.position.y = -0.36
        tower.addChild(groundLight)
        ground.components.set(ImageBasedLightReceiverComponent(imageBasedLight: groundLight))
        ground.isEnabled = showsGround
        tower.addChild(ground)
        if sessions.isEmpty {
            emptySun.components.set(DirectionalLightComponent.Shadow(maximumDistance: 30, depthBias: 2))
            tower.addChild(emptySun)
        }
        applyDaylight()
        let height = Float(sessions.count + 1) * Self.storeyHeight
        let roof = ModelEntity(mesh: .generateBox(width: OfficeScene.footprint.x + 0.8, height: Self.roofThickness, depth: OfficeScene.footprint.y + 0.8, cornerRadius: 0.2),
                               materials: [OfficeScene.material(Palette.resolved(Palette.walls, dark: dark))])
        roof.position = [0, roofTop - Self.roofThickness / 2, 0]
        roof.isEnabled = !sessions.isEmpty
        tower.addChild(roof)
        crown = [roof]
        if let sign = Billboard.make(ProjectBillboardView(title: building.title ?? building.name, folder: building.name), dark: dark) {
            sign.position = [0, height + 2.6, 0]
            tower.addChild(sign)
            crown.append(sign)
        }
        refreshLabels(force: true)
        camera.overview = overviewPose()
        if activeFloor == nil || !storeys.contains(where: { $0.id == activeFloor }) {
            activeFloor = nil
            lobbyFocused = false
            camera.reset(to: camera.overview, animated: false)
        }
    }

    private func buildLobby(width: Float, depth: Float, floors: Int) -> [Entity] {
        func model(_ mesh: MeshResource, _ token: NSColor) -> ModelEntity {
            ModelEntity(mesh: mesh, materials: [OfficeScene.material(Palette.resolved(token, dark: dark))])
        }
        func prop(_ name: String, _ position: SIMD3<Float>, yaw: Float = 0, scale: Float = 1) -> Entity {
            let entity = ModelLibrary.entity(name)
            entity.position = position
            entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            entity.scale = SIMD3(repeating: scale)
            return entity
        }
        var parts: [Entity] = []
        let floor = model(.generateBox(width: width, height: OfficeScene.floorThickness, depth: depth, cornerRadius: 0.2), Palette.walls)
        floor.position = [0, -OfficeScene.floorThickness / 2, 0]
        parts.append(floor)
        parts += OfficeScene.walls(width: width, depth: depth, doorway: true) { model($0, Palette.walls) } as [Entity]

        let desk = Pod(room: "reception", colour: Palette.primaryFill, at: [0, 0, 0.5], variant: 2, dark: dark)
        desk.root.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
        desk.hangBanner(symbol: "bell.fill", title: "Reception", dark: dark)
        desk.banner?.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        parts.append(desk.root)
        lobby = desk

        let shaft = SIMD3<Float>(width / 2 - 2.6, 0, -depth / 2 + 0.8)
        liftSpot = shaft
        let core = model(.generateBox(width: 3.6, height: OfficeScene.wallHeight, depth: 1.6), Palette.walls)
        core.position = shaft + [0, OfficeScene.wallHeight / 2, 0]
        parts.append(core)
        for side: Float in [-1, 1] {
            let leaf = model(.generateBox(width: 0.88, height: 3, depth: 0.06, cornerRadius: 0.02), Palette.tray)
            leaf.position = shaft + [side * 0.46, 1.5, 0.82]
            parts.append(leaf)
        }
        let panel = model(.generateBox(width: 0.34, height: 0.3 + Float(max(floors, 1)) * 0.16, depth: 0.05, cornerRadius: 0.04), Palette.robot)
        panel.position = shaft + [1.3, 1.5, 0.82]
        parts.append(panel)
        liftButtons = []
        for index in 0..<max(floors, 1) {
            let button = model(.generateCylinder(height: 0.04, radius: 0.045), Palette.muted)
            liftButtons.append(button)
            button.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            button.position = panel.position + [0, (Float(index) - Float(max(floors, 1) - 1) / 2) * 0.16, 0.04]
            parts.append(button)
        }

        let doorZ = depth / 2 - (depth / Float(max(Int(depth / 6), 2)) - 1.2) / 2
        parts.append(prop("couch_pillows", [-width / 2 + 2.2, 0, doorZ - 4.2], yaw: .pi / 2))
        parts.append(prop("cactus_medium_A", [-width / 2 + 1.2, 0, doorZ - 2], scale: 1.1))
        let lamp = prop("lamp_standing", [-width / 2 + 1.1, 0, doorZ - 6.3], scale: 0.75)
        OfficeScene.addLampLight(to: lamp, standing: true)
        parts.append(lamp)
        parts.append(prop("cactus_small_B", [shaft.x - 2.4, 0, shaft.z + 0.4]))
        parts.forEach { tower.addChild($0) }
        return parts
    }

    private func applyDaylight() {
        let cycle = DayCycle.now
        if let environment = ModelLibrary.environment("studio") {
            lobbyLight.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: OfficeScene.studioExposure(cycle)))
        }
        if let environment = ModelLibrary.environment("sky") {
            groundLight.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: CityScene.skyExposure(cycle)))
        }
        var light = DirectionalLightComponent(color: cycle.sunColour, intensity: cycle.mix(day: 2400, night: 600))
        light.isRealWorldProxy = false
        emptySun.components.set(light)
        emptySun.look(at: .zero, from: cycle.sun([-8, 12, 6]), relativeTo: nil)
        for part in lobbyParts { NightLight.apply(cycle, under: part) }
    }

    private var towerHeight: Float { Float(storeys.count + 1) * Self.storeyHeight }
    private var roofTop: Float { towerHeight - OfficeScene.floorThickness + (storeys.isEmpty ? 0 : Self.roofThickness) }

    func overviewPose() -> CameraRig.Pose {
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let vertical: Float = 26 * .pi / 180
        let horizontal = 2 * atan(tan(vertical / 2) * aspect)
        let tall = towerHeight + 4
        let distance = max(tall / 2 / tan(vertical / 2), (OfficeScene.footprint.x + 6) / 2 / tan(horizontal / 2)) * 1.25
        return .init(target: [0, tall / 2 - 1.5, 0], yaw: 0.62, pitch: 0.2, distance: distance)
    }

    func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewSize = size
        storeys.forEach { $0.scene.fit(size) }
        camera.overview = overviewPose()
        if activeFloor == nil { camera.reset(to: camera.overview) }
        else if let storey = storeys.first(where: { $0.id == activeFloor }), storey.scene.focusedRoom == nil {
            camera.reset(to: floorPose(storey.scene))
        }
    }

    private func floorPose(_ scene: OfficeScene) -> CameraRig.Pose {
        var pose = scene.overviewPose()
        // Aim at the floor's risen height, or entering straight from the city targets the still-sunk tower.
        pose.target.y -= tower.position.y
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let vertical: Float = 26 * .pi / 180
        let horizontal = 2 * atan(tan(vertical / 2) * aspect)
        pose.distance = 0.5 * simd_length(OfficeScene.footprint) / sin(min(vertical, horizontal) / 2)
        return pose
    }

    func enter(floor id: UUID) {
        guard let storey = storeys.first(where: { $0.id == id }) else { return }
        if activeFloor != id { Sound.play(.ding, volume: 0.6) }
        activeFloor = id
        lobbyFocused = false
        scaffold?.isEnabled = false
        crown.forEach { $0.isEnabled = false }
        // Only storeys above the active one are hidden: they sit between the camera and the floor.
        for other in storeys {
            other.scene.sunEnabled = other.id == id
            other.scene.root.isEnabled = other.index <= storey.index
            other.scene.isActive = other.id == id
            labels[other.id]?.entity.isEnabled = other.index < storey.index
        }
        camera.reset(to: floorPose(storey.scene))
    }

    var footprint: SIMD2<Float> {
        OfficeScene.footprint
    }

    func raise(_ up: Bool, animated: Bool) {
        let to: Float = up ? 1 : 0
        if animated && !OfficeScene.reduceMotion {
            rise = (risen, to, 0)
        } else {
            rise = nil
            risen = to
            applyRise()
        }
    }

    private func applyRise() {
        let t = risen * risen * (3 - 2 * risen)
        tower.position.y = -(1 - t) * (towerHeight + 1)
        tower.isEnabled = risen > 0
    }

    func focusLobby() {
        lobbyFocused = true
        camera.focus(on: [0, 1.6, 0.5], facing: 0.3, distance: 13, pitch: 0.28)
    }

    // Opacity rather than isEnabled, so storey 0's sun keeps lighting the lobby.
    private func hideStoreysForLobby() {
        guard !storeys.isEmpty else { return }
        for storey in storeys {
            if storeysHidden {
                storey.scene.root.components.set(OpacityComponent(opacity: 0))
            } else {
                storey.scene.root.components.remove(OpacityComponent.self)
            }
            labels[storey.id]?.entity.isEnabled = showsLabel(storey.index)
        }
        crown.forEach { $0.isEnabled = !storeysHidden && activeFloor == nil }
    }

    private func showsLabel(_ index: Int) -> Bool {
        !storeysHidden && (activeFloor.flatMap { id in storeys.first { $0.id == id }?.index }.map { index < $0 } ?? true)
    }

    func leaveLobby() {
        guard lobbyFocused else { return }
        lobbyFocused = false
        if activeFloor == nil { camera.reset(to: camera.overview) }
    }

    var receptionistPoint: CGPoint? {
        guard let lobby, let (screen, _) = camera.project(lobby.worker.headPosition, in: viewSize) else { return nil }
        return CGPoint(x: CGFloat(screen.x), y: CGFloat(screen.y))
    }

    func receptionist(thinking: Bool, pointingAt floor: UUID?, scaffold building: Bool) {
        lobby?.worker.setMood(thinking ? .working : .idle)
        let index = floor.flatMap { id in storeys.first { $0.id == id }?.index }
        lobby?.worker.waving = !thinking && (index != nil || building)
        for (position, button) in liftButtons.enumerated() {
            var material = OfficeScene.material(Palette.resolved(position == index ? Palette.lamp : Palette.muted, dark: dark))
            if position == index {
                material.emissiveColor = .init(color: Palette.resolved(Palette.lamp, dark: dark))
                material.emissiveIntensity = 2
            }
            button.model?.materials = [material]
        }
        if lobbyFocused, !thinking {
            if index != nil {
                camera.focus(on: (SIMD3<Float>(0, 0, 0.5) + liftSpot) / 2 + [0, 1.8, 0], facing: 0.3, distance: 20, pitch: 0.14)
            } else if !building {
                focusLobby()
            }
        }
        scaffold?.removeFromParent()
        scaffold = nil
        guard building, !thinking else { return }
        if lobbyFocused {
            lobbyFocused = false
            camera.reset(to: camera.overview)
        }
        let frame = Entity()
        let wood = OfficeScene.material(Palette.resolved(Palette.desk, dark: dark))
        let width = footprint.x, depth = footprint.y, height = Self.storeyHeight - 1
        for x in [-width / 2, width / 2] {
            for z in [-depth / 2, depth / 2] {
                let pole = ModelEntity(mesh: .generateBox(width: 0.2, height: height, depth: 0.2), materials: [wood])
                pole.position = [x, height / 2, z]
                frame.addChild(pole)
            }
        }
        for level in [height * 0.45, height] {
            for (w, d, x, z) in [(width, Float(0.25), Float(0), -depth / 2), (width, 0.25, 0, depth / 2), (0.25, depth, -width / 2, 0), (0.25, depth, width / 2, 0)] {
                let plank = ModelEntity(mesh: .generateBox(width: w, height: 0.15, depth: d), materials: [wood])
                plank.position = [x, level, z]
                frame.addChild(plank)
            }
        }
        frame.position = [0, roofTop, 0]
        tower.addChild(frame)
        scaffold = frame
    }

    func leaveFloor() {
        if let storey = storeys.first(where: { $0.id == activeFloor }) { storey.scene.showOverview() }
        activeFloor = nil
        crown.forEach { $0.isEnabled = true }
        lobbyParts.forEach { $0.isEnabled = true }
        scaffold?.isEnabled = true
        for storey in storeys {
            storey.scene.sunEnabled = storey.index == 0
            storey.scene.root.isEnabled = true
            storey.scene.isActive = false
            labels[storey.id]?.entity.isEnabled = true
        }
        camera.reset(to: camera.overview)
    }

    /// Scrolling in the building view steps the camera up and down the tower, one storey at a time.
    func scroll(by delta: Float) {
        camera.lift(to: (camera.goal.target.y + delta * 0.04).clamped(to: 1...max(towerHeight - 2, 1)))
    }

    func floor(of entity: Entity) -> UUID? {
        guard !storeysHidden else { return nil }
        var node: Entity? = entity
        while let current = node {
            if let storey = storeys.first(where: { $0.scene.root === current }) { return storey.id }
            node = current.parent
        }
        return nil
    }

    func scene(for id: UUID) -> OfficeScene? { storeys.first { $0.id == id }?.scene }

    func update(_ dt: Double) {
        camera.smoothTime = OfficeScene.reduceMotion ? 0.12 : 0.5
        camera.update(Float(dt))
        if lobbyFocused { storeysHidden = camera.entity.position(relativeTo: tower).y > Self.storeyHeight - OfficeScene.floorThickness }
        if let current = rise {
            let elapsed = current.elapsed + dt
            let t = Float(min(elapsed / World.slide, 1))
            risen = current.from + (current.to - current.from) * t
            rise = t >= 1 ? nil : (current.from, current.to, elapsed)
            applyRise()
        }
        for storey in storeys where storey.scene.root.isEnabled { storey.scene.update(dt) }
        lobby?.worker.update(dt, reduceMotion: OfficeScene.reduceMotion)
        daylightClock += dt
        if daylightClock > DayCycle.tick {
            daylightClock = 0
            applyDaylight()
        }
        labelClock += dt
        if labelClock > 1 {
            labelClock = 0
            refreshLabels(force: false)
        }
    }

    private func refreshLabels(force: Bool) {
        guard let buildingID, let building = CityStore.shared.building(buildingID) ?? self.building else { return }
        for storey in storeys {
            guard let floor = building.floors.first(where: { $0.id == storey.id }) else { continue }
            let session = CityStore.shared.sessions[storey.id]
            let waiting = session?.state.pendingRequests.count ?? 0
            let (symbol, status): (String, String) =
                waiting > 0 ? ("hand.raised.fill", "Needs you") :
                session?.isRunning == true ? ("bolt.fill", "Working") :
                floor.lastOutcome == "completed" ? ("checkmark.circle.fill", "Done") : ("moon.zzz.fill", "Quiet")
            let text = "\(floor.name) · \(status)"
            if !force, labels[storey.id]?.text == text { continue }
            labels[storey.id]?.entity.removeFromParent()
            let colour = waiting > 0 ? Palette.manager : session?.isRunning == true ? Palette.primaryFill : Palette.muted
            guard let label = Billboard.make(BubbleView(symbol: symbol, text: text, colour: colour), dark: dark) else { continue }
            label.position = [-OfficeScene.footprint.x / 2 - 1.2, Float(storey.index + 1) * Self.storeyHeight + 1.2, OfficeScene.footprint.y / 2 + 1.5]
            label.scale = [1.3, 1.3, 1.3]
            label.isEnabled = showsLabel(storey.index)
            tower.addChild(label)
            labels[storey.id] = (label, text)
        }
    }
}
