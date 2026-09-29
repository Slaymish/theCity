#if os(macOS)
import AppKit
#else
import UIKit
#endif
import OfficeCore
import RealityKit
import SwiftUI

/// What a storey needs from whoever runs its floor: the Mac's `RunController`, or the phone's mirror of one.
@MainActor
protocol Storey: AnyObject {
    var scene: OfficeScene { get }
    var isRunning: Bool { get }
    var waitingCount: Int { get }
    var waitingSince: Date? { get }
    var roomCounts: RoomCounts { get }
}

/// The parts of a project a tower is built from.
struct TowerPlan: Equatable {
    struct Floor: Equatable {
        var id: UUID
        var name: String
        var lastOutcome: String?
        var unseen = false
        var unseenSince: Date?
        var queued = 0
    }

    var id: UUID
    var name: String
    var title: String?
    var floors: [Floor]
}

extension TowerPlan.Floor {
    @MainActor
    func signal(_ storey: (any Storey)?) -> FloorSignal {
        FloorSignal.of(pending: storey?.waitingCount ?? 0, unseen: unseen, outcome: lastOutcome, running: storey?.isRunning == true, queued: queued)
    }

    @MainActor
    func since(_ storey: (any Storey)?) -> Date? {
        switch signal(storey) {
        case .blocked: storey?.waitingSince
        case .failed, .ready: unseenSince
        default: nil
        }
    }
}

@Observable @MainActor
final class BuildingWatch {
    var lobbyFocused = false
}

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
    private var builtShell: String?
    private var builtFloors: [UUID] = []
    let watch = BuildingWatch()
    private var plan: TowerPlan?
    /// Where labels read a floor's latest name and session between shows; without them, the ones it was shown with.
    var latestPlan: (UUID) -> TowerPlan? = { _ in nil }
    var latestStorey: (UUID) -> (any Storey)? = { _ in nil }
    var pulsingFloor: () -> UUID? = { nil }
    private(set) var activeFloor: UUID?
    private var storeys: [(id: UUID, scene: OfficeScene, index: Int)] = []
    private var sessions: [UUID: any Storey] = [:]
    private var labels: [UUID: (entity: Entity, text: String)] = [:]
    private var receptionLabel: Entity?
    private var edges: [UUID: (entity: Entity, key: String)] = [:]
    private var pulsing: UUID?
    private var pulseClock: Double = 0
    /// Set before routing back to the building, so leaving the floor lands on reception.
    var lobbyAfterLeaving = false
    private var crown: [Entity] = []
    private var fitOut: [Int: Entity] = [:]
    private let haze = Horizon.haze()
    private var lobby: Pod?
    private var liftButtons: [ModelEntity] = []
    private var litButton: Int?
    private var billboardsWalked = 0
    private var liftParts: [Entity] = []
    private var roof: Entity?
    private var projectSign: Entity?
    private var signsHidden: Bool?
    private var scaffold: Entity?
    private(set) var lobbyFocused = false {
        didSet {
            if !lobbyFocused { storeysHidden = false }
            if watch.lobbyFocused != lobbyFocused { watch.lobbyFocused = lobbyFocused }
        }
    }
    private var storeysHidden = false {
        didSet { if storeysHidden != oldValue { hideStoreysForLobby() } }
    }
    private var liftSpot: SIMD3<Float> = .zero
    private var lobbyParts: [Entity] = []
    private let lobbyLight = Entity()
    private let groundLight = Entity()
    private let emptySun = Entity()
    private var emptyReach: Float = 30 {
        didSet { if emptyReach != oldValue { emptySun.components.set(Sun.shadow(reach: emptyReach)) } }
    }
    /// Lights the tower with the city's sun, so the city around it keeps its lighting.
    var outdoorSun = false {
        didSet {
            guard outdoorSun != oldValue else { return }
            storeys.forEach { $0.scene.sunStyle = outdoorSun ? .city : .storey }
            applyDaylight()
        }
    }
    private var daylightClock: Double = 0
    private var viewSize = CGSize(width: 1000, height: 700)
    private var labelClock: Double = 0
    private var dark = false
    static let storeyHeight = OfficeScene.wallHeight + OfficeScene.floorThickness
    /// How long the tower takes to rise out of the ground, which is also the city's slide into a building.
    static let slide: Double = 0.6
    private static let roofThickness: Float = 0.4
    private static let highlightWidth: Float = 0.15
    private static let highlightGlow: Float = 2
    static let edgeGlow: Float = 1

    init() {
        root.addChild(camera.entity)
        root.addChild(tower)
    }

    /// Rebuilding the shell (lobby, glazing, roof, sign and floor labels) is the slow part of entering a building,
    /// so it's kept while the building's floors, names, theme and brand stay the same, and only the offices are re-slotted.
    func show(_ building: TowerPlan, storeys sessions: [(UUID, any Storey)], dark: Bool) {
        let shell = "\(building.id)|\(building.name)|\(building.title ?? "")|\(dark)|\(BrandStore.shared.selectedID)"
        let ids = sessions.map(\.0)
        let grows = shell == builtShell && !builtFloors.isEmpty && ids.count == builtFloors.count + 1 && Array(ids.dropLast()) == builtFloors
        let rebuild = !grows && (shell != builtShell || ids != builtFloors)
        let onScreen = root.isEnabled && buildingID == building.id
        self.dark = dark
        buildingID = building.id
        plan = building
        for storey in storeys where !sessions.contains(where: { $0.1.scene === storey.scene }) {
            storey.scene.root.removeFromParent()
            storey.scene.root.components.remove(OpacityComponent.self)
        }
        if rebuild {
            tower.children.removeAll()
            labels = [:]
            receptionLabel = nil
            edges = [:]
        }
        storeys = []
        self.sessions = Dictionary(sessions, uniquingKeysWith: { $1 })
        for (index, (id, session)) in sessions.enumerated() {
            let scene = session.scene
            scene.adopt(camera: camera)
            if scene.root.parent !== tower {
                scene.root.removeFromParent()
                tower.addChild(scene.root)
            }
            scene.root.position = [0, Float(index + 1) * Self.storeyHeight, 0]
            scene.isActive = false
            scene.fit(viewSize)
            scene.sunEnabled = index == 0
            scene.sunStyle = outdoorSun ? .city : .storey
            storeys.append((id, scene, index))
        }
        if rebuild {
            buildShell(building, floors: sessions.count)
            builtShell = shell
        } else if grows {
            addStorey(floors: sessions.count)
        }
        builtFloors = ids
        setOverview()
        if activeFloor == nil || !storeys.contains(where: { $0.id == activeFloor }) {
            activeFloor = nil
            lobbyFocused = false
            camera.reset(to: camera.overview, animated: onScreen)
        }
    }

    private func buildShell(_ building: TowerPlan, floors: Int) {
        lobbyParts = buildLobby(width: OfficeScene.footprint.x, depth: OfficeScene.footprint.y, floors: floors)
        lobbyParts.forEach { $0.isEnabled = true }
        tower.addChild(lobbyLight)
        let receiver = ImageBasedLightReceiverComponent(imageBasedLight: lobbyLight)
        for entity in lobbyParts.flatMap({ [$0] + $0.descendants }) where entity.components.has(ModelComponent.self) {
            entity.components.set(receiver)
            entity.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: true))
        }
        let ground = Horizon.ground(dark: dark)
        ground.position.y = -0.36
        tower.addChild(groundLight)
        ground.components.set(ImageBasedLightReceiverComponent(imageBasedLight: groundLight))
        ground.isEnabled = showsGround
        tower.addChild(ground)
        if showsGround { tower.addChild(haze) }
        if floors == 0 {
            emptySun.components.set(Sun.shadow(reach: emptyReach))
            tower.addChild(emptySun)
        }
        fitOut = [:]
        for level in 0...floors {
            // Every upper storey's fit-out is the same, so storeys above the first clone it and share its meshes.
            let storey = level > 1 ? fitOut[0]!.clone(recursive: true) : fitOut(level: level, doorway: level == 0)
            storey.position.y = Float(level) * Self.storeyHeight
            if level <= 1 {
                storey.components.set(receiver)
                storey.descendants.forEach { $0.components.set(receiver) }
            }
            tower.addChild(storey)
            if level == 0 { lobbyParts.append(storey) } else { fitOut[level - 1] = storey }
        }
        applyDaylight()
        let height = Float(floors + 1) * Self.storeyHeight
        let roof = ModelEntity(mesh: ModelLibrary.box(width: OfficeScene.footprint.x + 0.8, height: Self.roofThickness, depth: OfficeScene.footprint.y + 0.8, cornerRadius: 0.2),
                               materials: [OfficeScene.material(Palette.resolved(Palette.walls, dark: dark))])
        roof.position = [0, roofTop - Self.roofThickness / 2, 0]
        roof.isEnabled = floors > 0
        tower.addChild(roof)
        self.roof = roof
        crown = [roof]
        projectSign = nil
        if let sign = Billboard.make(ProjectBillboardView(title: building.title ?? building.name, folder: building.name), dark: dark) {
            sign.position = [0, height + 2.6, 0]
            tower.addChild(sign)
            crown.append(sign)
            projectSign = sign
        }
        signsHidden = nil
        refreshLabels(force: true)
        if let label = Billboard.make(BubbleView(symbol: "bell.fill", text: "Reception", colour: Palette.muted), dark: dark) {
            label.position = labelPosition(-1)
            label.scale = [1.3, 1.3, 1.3]
            Self.makeTappable(label)
            label.isEnabled = activeFloor != nil && !storeysHidden
            tower.addChild(label)
            receptionLabel = label
        }
    }

    private func labelPosition(_ index: Int) -> SIMD3<Float> {
        [-OfficeScene.footprint.x / 2 - 1.2, Float(index + 1) * Self.storeyHeight + 1.2, OfficeScene.footprint.y / 2 + 1.5]
    }

    private static func makeTappable(_ label: ModelEntity) {
        guard let extents = label.model?.mesh.bounds.extents else { return }
        label.components.set(CollisionComponent(shapes: [.generateBox(width: extents.x, height: extents.y, depth: extents.x)]))
        label.components.set(InputTargetComponent())
    }

    private func addStorey(floors: Int) {
        let receiver = ImageBasedLightReceiverComponent(imageBasedLight: lobbyLight)
        liftParts.forEach { $0.removeFromParent() }
        lobbyParts.removeAll { part in liftParts.contains { $0 === part } }
        liftParts = liftPanel(floors: floors)
        for part in liftParts {
            part.components.set(receiver)
            part.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: true))
            tower.addChild(part)
        }
        lobbyParts += liftParts
        lightLift()
        let active = activeFloor.flatMap { id in storeys.first { $0.id == id }?.index }
        if let template = fitOut[0] {
            let storey = template.clone(recursive: true)
            storey.position.y = Float(floors) * Self.storeyHeight
            storey.isEnabled = active.map { floors - 1 <= $0 } ?? true
            tower.addChild(storey)
            fitOut[floors - 1] = storey
        }
        if let active, let top = storeys.last, top.index > active { top.scene.root.isEnabled = false }
        roof?.position.y = roofTop - Self.roofThickness / 2
        roof?.isEnabled = activeFloor == nil && !storeysHidden
        projectSign?.position.y = Float(floors + 1) * Self.storeyHeight + 2.6
        scaffold?.removeFromParent()
        scaffold = nil
        applyDaylight()
        if storeysHidden { hideStoreysForLobby() }
        signsHidden = nil
        refreshLabels(force: false)
        applyRise()
    }

    private func setOverview() {
        camera.overview = overviewPose()
        camera.distanceRange = CameraRig.distanceRange.lowerBound...max(CameraRig.distanceRange.upperBound, camera.overview.distance)
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
        let floor = model(ModelLibrary.box(width: width, height: OfficeScene.floorThickness, depth: depth, cornerRadius: 0.2), Palette.walls)
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
        let core = model(ModelLibrary.box(width: 3.6, height: OfficeScene.wallHeight, depth: 1.6), Palette.walls)
        core.position = shaft + [0, OfficeScene.wallHeight / 2, 0]
        parts.append(core)
        for side: Float in [-1, 1] {
            let leaf = model(ModelLibrary.box(width: 0.88, height: 3, depth: 0.06, cornerRadius: 0.02), Palette.tray)
            leaf.position = shaft + [side * 0.46, 1.5, 0.82]
            parts.append(leaf)
        }
        liftParts = liftPanel(floors: floors)
        parts += liftParts

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

    private func liftPanel(floors: Int) -> [Entity] {
        func model(_ mesh: MeshResource, _ token: NSColor) -> ModelEntity {
            ModelEntity(mesh: mesh, materials: [OfficeScene.material(Palette.resolved(token, dark: dark))])
        }
        var parts: [Entity] = []
        let panel = model(ModelLibrary.box(width: 0.34, height: 0.3 + Float(max(floors, 1)) * 0.16, depth: 0.05, cornerRadius: 0.04), Palette.robot)
        panel.position = liftSpot + [1.3, 1.5, 0.82]
        parts.append(panel)
        liftButtons = []
        for index in 0..<max(floors, 1) {
            let button = model(.generateCylinder(height: 0.04, radius: 0.045), Palette.muted)
            liftButtons.append(button)
            button.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            button.position = panel.position + [0, (Float(index) - Float(max(floors, 1) - 1) / 2) * 0.16, 0.04]
            parts.append(button)
        }
        return parts
    }

    /// Glazing in the far walls' openings, slab edges, skirting, a corner plant and the lights under this storey's slab.
    private func fitOut(level: Int, doorway: Bool) -> Entity {
        let width = OfficeScene.footprint.x, depth = OfficeScene.footprint.y
        let group = Entity()
        func add(_ mesh: MeshResource, _ material: RealityKit.Material, _ position: SIMD3<Float>) {
            let part = ModelEntity(mesh: mesh, materials: [material])
            part.position = position
            group.addChild(part)
        }
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: Palette.resolved(Palette.glazing, dark: dark))
        glass.roughness = 0.1
        glass.metallic = 0.35
        let frame = OfficeScene.material(Palette.resolved(Palette.mullion, dark: dark))
        let skirting = OfficeScene.material(Palette.resolved(Palette.desk, dark: dark))
        let sill: Float = 1.3, lintel: Float = 4.2, pier: Float = 1.2, wall: Float = 0.35
        for (length, back) in [(width, true), (depth, false)] {
            let windows = max(Int(length / 6), 2), bay = length / Float(windows)
            for index in 0..<windows where !(doorway && !back && index == windows - 1) {
                let open = bay - pier, along = -length / 2 + Float(index) * bay + pier + open / 2
                let pane: MeshResource = back ? ModelLibrary.box(width: open, height: lintel - sill, depth: 0.05) : ModelLibrary.box(width: 0.05, height: lintel - sill, depth: open)
                let bar: MeshResource = back ? ModelLibrary.box(width: 0.06, height: lintel - sill, depth: 0.1) : ModelLibrary.box(width: 0.1, height: lintel - sill, depth: 0.06)
                let centre: SIMD3<Float> = back ? [along, (sill + lintel) / 2, -depth / 2 - wall / 2] : [-width / 2 - wall / 2, (sill + lintel) / 2, along]
                add(pane, glass, centre)
                add(bar, frame, centre)
            }
            let run: MeshResource = back ? ModelLibrary.box(width: length, height: 0.14, depth: 0.04) : ModelLibrary.box(width: 0.04, height: 0.14, depth: length)
            add(run, skirting, back ? [0, 0.07, -depth / 2 + 0.02] : [-width / 2 + 0.02, 0.07, 0])
        }
        let edge: Float = 0.12
        add(ModelLibrary.box(width: width + edge * 2, height: OfficeScene.floorThickness + 0.04, depth: edge), frame, [0, -OfficeScene.floorThickness / 2, depth / 2 + edge / 2])
        add(ModelLibrary.box(width: edge, height: OfficeScene.floorThickness + 0.04, depth: depth + edge), frame, [width / 2 + edge / 2, -OfficeScene.floorThickness / 2, edge / 2])
        var light = OfficeScene.material(Palette.resolved(Palette.lamp, dark: dark))
        light.emissiveColor = .init(color: Palette.resolved(Palette.lamp, dark: dark))
        light.emissiveIntensity = 1
        if level > 0 {
            for x in [-width / 3, 0, width / 3] {
                for z in [-depth / 4, depth / 4] {
                    add(ModelLibrary.box(width: 2, height: 0.05, depth: 0.5, cornerRadius: 0.02), light, [x, -OfficeScene.floorThickness - 0.03, z])
                }
            }
        }
        if level > 0 {
            let plant = ModelLibrary.entity("cactus_medium_A")
            plant.position = [-width / 2 + 0.7, 0, -depth / 2 + 0.7]
            group.addChild(plant)
        }
        return group
    }

    private func applyDaylight() {
        let cycle = DayCycle.now
        if let environment = ModelLibrary.environment("studio") {
            lobbyLight.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: OfficeScene.studioExposure(cycle)))
        }
        if let environment = ModelLibrary.environment("sky") {
            groundLight.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: Horizon.skyExposure(cycle)))
        }
        (outdoorSun ? Sun.city : Sun.emptyLot).apply(to: emptySun, cycle: cycle)
        Horizon.tint(haze, sky: cycle.sky(dark: dark))
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
        setOverview()
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
        receptionLabel?.isEnabled = true
        for other in storeys {
            other.scene.sunEnabled = other.id == id
            other.scene.isActive = other.id == id
            labels[other.id]?.entity.isEnabled = true
        }
        reveal(through: storey.index)
        refreshEdges()
        camera.reset(to: floorPose(storey.scene))
    }

    // Storeys above the one in view are hidden: they sit between the camera and the floor.
    private func reveal(through top: Int) {
        for storey in storeys {
            storey.scene.root.isEnabled = storey.index <= top
            fitOut[storey.index]?.isEnabled = storey.index <= top
            edges[storey.id]?.entity.isEnabled = storey.index <= top
        }
    }

    private func refreshEdges() {
        guard let buildingID, let building = latestPlan(buildingID) ?? plan else { return }
        for storey in storeys {
            guard let floor = building.floors.first(where: { $0.id == storey.id }) else { continue }
            edge(storey.id, index: storey.index, signal: floor.signal(latestStorey(storey.id) ?? sessions[storey.id]))
        }
    }

    private func edge(_ id: UUID, index: Int, signal: FloorSignal) {
        let open = id == activeFloor
        let key = "\(signal)|\(open)"
        guard edges[id]?.key != key else { return }
        edges[id]?.entity.removeFromParent()
        edges[id] = nil
        guard open || signal != .quiet else { return }
        let glow = ModelLibrary.material(Palette.resolved(signal.colour, dark: dark), roughness: nil, emissive: open ? Self.highlightGlow : Self.edgeGlow)
        let edge = open ? Self.highlightWidth * 2 : Self.highlightWidth
        let width = OfficeScene.footprint.x, depth = OfficeScene.footprint.y, height = OfficeScene.floorThickness
        let frame = Entity()
        let strips: [(Float, Float, Float, Float)] = [(width + 2 * edge, edge, 0, -(depth + edge) / 2), (width + 2 * edge, edge, 0, (depth + edge) / 2),
                                                      (edge, depth, -(width + edge) / 2, 0), (edge, depth, (width + edge) / 2, 0)]
        for (w, d, x, z) in strips {
            let strip = ModelEntity(mesh: ModelLibrary.box(width: w, height: height, depth: d), materials: [glow])
            strip.position = [x, -height / 2, z]
            frame.addChild(strip)
        }
        frame.position.y = Float(index + 1) * Self.storeyHeight
        frame.isEnabled = fitOut[index]?.isEnabled ?? true
        if storeysHidden { frame.components.set(OpacityComponent(opacity: 0)) }
        tower.addChild(frame)
        edges[id] = (frame, key)
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
        }
        applyRise()
    }

    private func applyRise() {
        let t = risen * risen * (3 - 2 * risen)
        tower.position.y = -(1 - t) * (towerHeight + 1)
        tower.isEnabled = risen > 0
        // Billboards ignore depth. Hide them while underground so they cannot show through the facade.
        let hidden = risen < 1
        guard hidden != signsHidden || (hidden && Billboard.made != billboardsWalked) else { return }
        signsHidden = hidden
        billboardsWalked = Billboard.made
        for sign in tower.descendants where sign.components.has(BillboardComponent.self) {
            if hidden {
                if sign.components[OpacityComponent.self]?.opacity != 0 { sign.components.set(OpacityComponent(opacity: 0)) }
            } else if sign.components.has(OpacityComponent.self) {
                sign.components.remove(OpacityComponent.self)
            }
        }
    }

    func focusLobby() {
        lobbyFocused = true
        camera.focus(on: [0, 1.6, 0.5], facing: 0.3, distance: 13, pitch: 0.28)
    }

    // Opacity rather than isEnabled, so storey 0's sun keeps lighting the lobby.
    private func hideStoreysForLobby() {
        guard !storeys.isEmpty else { return }
        for storey in storeys {
            for part in [storey.scene.root, fitOut[storey.index], edges[storey.id]?.entity].compactMap({ $0 }) {
                if storeysHidden {
                    part.components.set(OpacityComponent(opacity: 0))
                } else {
                    part.components.remove(OpacityComponent.self)
                }
            }
            labels[storey.id]?.entity.isEnabled = !storeysHidden
        }
        crown.forEach { $0.isEnabled = !storeysHidden && activeFloor == nil }
        receptionLabel?.isEnabled = !storeysHidden && activeFloor != nil
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

    private func lightLift() {
        for (position, button) in liftButtons.enumerated() {
            var material = OfficeScene.material(Palette.resolved(position == litButton ? Palette.lamp : Palette.muted, dark: dark))
            if position == litButton {
                material.emissiveColor = .init(color: Palette.resolved(Palette.lamp, dark: dark))
                material.emissiveIntensity = 2
            }
            button.model?.materials = [material]
        }
    }

    func receptionist(thinking: Bool, pointingAt floor: UUID?, scaffold building: Bool) {
        lobby?.worker.setMood(thinking ? .working : .idle)
        let index = floor.flatMap { id in storeys.first { $0.id == id }?.index }
        lobby?.worker.waving = !thinking && (index != nil || building)
        litButton = index
        lightLift()
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
                let pole = ModelEntity(mesh: ModelLibrary.box(width: 0.2, height: height, depth: 0.2), materials: [wood])
                pole.position = [x, height / 2, z]
                frame.addChild(pole)
            }
        }
        for level in [height * 0.45, height] {
            for (w, d, x, z) in [(width, Float(0.25), Float(0), -depth / 2), (width, 0.25, 0, depth / 2), (0.25, depth, -width / 2, 0), (0.25, depth, width / 2, 0)] {
                let plank = ModelEntity(mesh: ModelLibrary.box(width: w, height: 0.15, depth: d), materials: [wood])
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
        receptionLabel?.isEnabled = false
        crown.forEach { $0.isEnabled = true }
        lobbyParts.forEach { $0.isEnabled = true }
        scaffold?.isEnabled = true
        for storey in storeys {
            storey.scene.sunEnabled = storey.index == 0
            storey.scene.root.isEnabled = true
            fitOut[storey.index]?.isEnabled = true
            edges[storey.id]?.entity.isEnabled = true
            storey.scene.isActive = false
            labels[storey.id]?.entity.isEnabled = true
        }
        refreshEdges()
        if lobbyAfterLeaving {
            lobbyAfterLeaving = false
            focusLobby()
        } else {
            camera.reset(to: camera.overview)
        }
    }

    /// Vertical trackpad scrolling in the building view slides the camera up and down the tower.
    func scroll(by delta: Float) {
        camera.lift(to: (camera.goal.target.y + delta * 0.04).clamped(to: 1...max(towerHeight - 2, 1)))
        guard let active = storeys.first(where: { $0.id == activeFloor }) else { return }
        reveal(through: max(active.index, Int((camera.goal.target.y / Self.storeyHeight).rounded(.down)) - 1))
    }

    func floor(of entity: Entity) -> UUID? {
        guard !storeysHidden else { return nil }
        if let label = labels.first(where: { $0.value.entity === entity }) { return label.key }
        var node: Entity? = entity
        while let current = node {
            if let storey = storeys.first(where: { $0.scene.root === current }) { return storey.id }
            node = current.parent
        }
        return nil
    }

    func isReception(_ entity: Entity) -> Bool {
        !storeysHidden && entity === receptionLabel
    }

    func scene(for id: UUID) -> OfficeScene? { storeys.first { $0.id == id }?.scene }

    func update(_ dt: Double) {
        camera.smoothTime = OfficeScene.reduceMotion ? 0.12 : 0.5
        camera.update(Float(dt))
        if lobbyFocused { storeysHidden = camera.entity.position(relativeTo: tower).y > Self.storeyHeight - OfficeScene.floorThickness }
        if let current = rise {
            let elapsed = current.elapsed + dt
            let t = Float(min(elapsed / Self.slide, 1))
            risen = current.from + (current.to - current.from) * t
            rise = t >= 1 ? nil : (current.from, current.to, elapsed)
            applyRise()
        }
        let shadowExtent = simd_length(SIMD3(OfficeScene.footprint.x, towerHeight, OfficeScene.footprint.y)) / 2
        emptyReach = Sun.reach(distance: camera.current.distance, extent: shadowExtent)
        for storey in storeys where storey.scene.root.isEnabled {
            storey.scene.shadowExtent = shadowExtent
            storey.scene.update(dt)
        }
        if showsGround {
            let eye = camera.entity.position(relativeTo: tower), target = camera.current.target
            let reach = simd_distance(SIMD2(eye.x, eye.z), SIMD2(target.x, target.z))
            Horizon.place(haze, eye: eye, ground: -0.36, start: reach + OfficeScene.footprint.x * 2)
        }
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
        pulseClock += dt
        for (id, label) in labels {
            let scale = SIMD3(repeating: 1.3 * (id == pulsing ? FloorSignal.pulse(pulseClock, still: OfficeScene.reduceMotion) : 1))
            if label.entity.scale != scale { label.entity.scale = scale }
        }
    }

    private func refreshLabels(force: Bool) {
        guard let buildingID, let building = latestPlan(buildingID) ?? plan else { return }
        pulsing = pulsingFloor()
        for storey in storeys {
            guard let floor = building.floors.first(where: { $0.id == storey.id }) else { continue }
            let session = latestStorey(storey.id) ?? sessions[storey.id]
            let signal = floor.signal(session)
            edge(storey.id, index: storey.index, signal: signal)
            let count = signal == .blocked ? session?.waitingCount ?? 1 : 1
            let text = "\(floor.name) · \(signal.label(count: count))\(signal.ageSuffix(since: floor.since(session)))"
            let rooms = session?.roomCounts ?? RoomCounts()
            let key = "\(signal)|\(text)|\(rooms.waiting)|\(rooms.working)"
            if !force, labels[storey.id]?.text == key { continue }
            labels[storey.id]?.entity.removeFromParent()
            let bubble = BubbleView(symbol: signal.symbol, text: text, colour: signal.colour, rooms: rooms, glyph: signal.glyph)
            guard let label = Billboard.make(bubble, dark: dark) else { continue }
            label.position = labelPosition(storey.index)
            label.scale = [1.3, 1.3, 1.3]
            Self.makeTappable(label)
            label.isEnabled = !storeysHidden
            if signsHidden == true { label.components.set(OpacityComponent(opacity: 0)) }
            tower.addChild(label)
            labels[storey.id] = (label, key)
        }
    }
}
