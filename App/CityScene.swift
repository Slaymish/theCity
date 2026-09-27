import AppKit
import RealityKit
import SwiftUI

/// Every project is a building on a small street grid; balloons, lit fronts and hover labels show which floors are busy.
@MainActor
final class CityScene {
    let root = Entity()
    let camera = CameraRig(overview: .init(target: .zero, yaw: 0.72, pitch: 0.7, distance: 24))
    var updates: EventSubscription?
    private var lots: [UUID: Lot] = [:]
    private var buildings: [CityStore.Building] = []
    private var viewSize = CGSize(width: 1000, height: 700)
    private var extent: Float = 10
    private var clock: Double = 0
    private var daylightClock: Double = 0
    private var dark = false
    private let lighting = Entity()
    private let sun = Entity()
    private var facades: [UUID: (entity: Entity, height: Float)] = [:]
    private var props: [(entity: Entity, height: Float, radius: Float)] = []
    private var slides: [(entity: Entity, from: Float, to: Float, elapsed: Double, duration: Double)] = []
    private var labelsVisible = true
    private var hovered: UUID?
    private var cars: [(entity: Entity, along: Float)] = []
    private var cover: [String: [simd_float4x4]] = [:]
    private var loop: (origin: Float, length: Float) = (0, 1)
    static let carSpeed: Float = 0.5
    var hostsCamera = true
    var titleMode = false
    private var greeter: Worker?
    private var emptyLot: SIMD3<Float> = .zero
    private var rises: [(entity: Entity, top: Float, height: Float, elapsed: Double)] = []
    static let riseTime: Double = 1.2
    var sunEnabled: Bool {
        get { sun.isEnabled }
        set { sun.isEnabled = newValue }
    }
    static let tile: Float = 2
    static let groundLevel: Float = -0.02

    @MainActor private final class Lot {
        let id: UUID
        let root = Entity()
        let beacon: ModelEntity
        let glow = Entity()
        var label: Entity?
        var labelText = ""
        var waiting = false
        var working = false

        init(id: UUID, beacon: ModelEntity) {
            self.id = id
            self.beacon = beacon
        }
    }

    init() {
        root.addChild(camera.entity)
    }

    func build(_ buildings: [CityStore.Building], dark: Bool) {
        self.dark = dark
        self.buildings = buildings
        root.children.removeAll()
        if hostsCamera { root.addChild(camera.entity) }
        let firstBuild = lots.isEmpty && facades.isEmpty && greeter == nil
        lots = [:]
        facades = [:]
        props = []
        slides = []
        rises = []
        greeter = nil
        cover = [:]

        let plots = buildings.count + 1
        let blocks = max(Int(ceil(sqrt(Double(plots)))), 2)
        let cells = blocks * 2 + 1
        extent = Float(cells) * Self.tile
        let origin = -Float(cells - 1) / 2 * Self.tile

        root.addChild(Self.ground(dark: dark))

        var plotIndex = 0
        for row in 0..<cells {
            for column in 0..<cells {
                let position = SIMD3<Float>(origin + Float(column) * Self.tile, 0, origin + Float(row) * Self.tile)
                let roadRow = row % 2 == 0, roadColumn = column % 2 == 0
                if roadRow || roadColumn {
                    let piece = ModelLibrary.entity(roadRow && roadColumn ? "road_junction" : "road_straight")
                    piece.position = position
                    if roadRow && !roadColumn { piece.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0]) }
                    root.addChild(piece)
                    continue
                }
                let base = ModelLibrary.entity("base")
                base.position = position
                root.addChild(base)
                if plotIndex < buildings.count {
                    addBuilding(buildings[plotIndex], at: position)
                } else if plotIndex == buildings.count {
                    addEmptyLot(at: position)
                } else {
                    addPark(at: position, seed: plotIndex)
                }
                plotIndex += 1
            }
        }
        addCars(origin: origin, cells: cells)
        addTreeRing(halfWidth: extent / 2)
        addCountryside(halfWidth: extent / 2)
        for (name, placements) in cover {
            root.addChild(Foliage.instanced(name, placements, casts: !["grass_tuft", "flowers_A", "flowers_B", "pebbles"].contains(name)))
        }
        setUpLighting()
        camera.overview = overviewPose()
        if firstBuild { camera.reset(to: titleMode ? titlePose() : camera.overview, animated: false) }
        applyReceivers()
        refresh()
    }

    private func addBuilding(_ building: CityStore.Building, at position: SIMD3<Float>) {
        let model = Facade.tower(building, dark: dark)
        model.position = position + [0, 0.1, 0]
        model.name = "building:\(building.id.uuidString)"
        let bounds = model.visualBounds(relativeTo: nil)
        model.components.set(CollisionComponent(shapes: [.generateBox(size: bounds.extents).offsetBy(translation: bounds.center - model.position)]))
        model.components.set(InputTargetComponent())
        root.addChild(model)
        facades[building.id] = (model, bounds.extents.y)
        let beacon = ModelEntity(mesh: .generateSphere(radius: 0.14), materials: [OfficeScene.material(Palette.resolved(Palette.manager, dark: dark))])
        beacon.scale = [1, 1.15, 1]
        beacon.position = [position.x, bounds.max.y + 0.45, position.z]
        let string = ModelEntity(mesh: .generateBox(width: 0.012, height: 0.4, depth: 0.012),
                                 materials: [OfficeScene.material(Palette.resolved(Palette.text, dark: dark))])
        string.position = [0, -0.33, 0]
        beacon.addChild(string)
        beacon.isEnabled = false
        root.addChild(beacon)
        let lot = Lot(id: building.id, beacon: beacon)
        lot.glow.position = [position.x, bounds.center.y, position.z + bounds.extents.z / 2 + 0.35]
        root.addChild(lot.glow)
        lot.root.position = [position.x, bounds.max.y + 0.75, position.z]
        root.addChild(lot.root)
        for (index, offset) in [SIMD3<Float>(-0.8, 0.1, 0.8), [0.8, 0.1, 0.8]].enumerated() where index < 2 {
            let bush = ModelLibrary.entity("bush")
            bush.position = position + offset
            bush.scale = [1.4, 1.4, 1.4]
            addProp(bush)
        }
        if CityStore.shared.hasParcel(building) {
            let parcel = OfficeScene.makeFolder()
            parcel.scale = SIMD3(repeating: 0.45)
            parcel.position = position + [0, 0.14, 0.85]
            root.addChild(parcel)
        }
        addStreetlight(at: position)
        lot.root.isEnabled = false
        lots[building.id] = lot
    }

    func facade(of id: UUID) -> (position: SIMD3<Float>, size: SIMD3<Float>)? {
        guard let facade = facades[id] else { return nil }
        let bounds = facade.entity.visualBounds(relativeTo: root)
        return ([facade.entity.position.x, 0.1, facade.entity.position.z], bounds.extents)
    }

    func sinkFacade(_ id: UUID, down: Bool, animated: Bool) {
        guard let facade = facades[id] else { return }
        let top: Float = 0.1, bottom = top - facade.height - 0.05
        slides.removeAll { $0.entity === facade.entity }
        let from = facade.entity.position.y, to = down ? bottom : top
        if animated && !OfficeScene.reduceMotion {
            slides.append((facade.entity, from, to, 0, World.slide))
        } else {
            facade.entity.position.y = to
        }
    }

    func hideOccluders(eye: SIMD3<Float>?, target: SIMD3<Float>, keeping kept: UUID?) {
        for (id, facade) in facades where id != kept {
            guard let eye else {
                facade.entity.isEnabled = true
                continue
            }
            facade.entity.isEnabled = !Self.blocks(facade.entity.position, radius: Self.tile * 0.75, height: facade.height, eye: eye, target: target)
        }
        for prop in props {
            guard let eye else {
                prop.entity.isEnabled = true
                continue
            }
            let beside = simd_distance(SIMD2(prop.entity.position.x, prop.entity.position.z), SIMD2(eye.x, eye.z)) < prop.radius + Self.tile * 0.3 && eye.y < prop.height + 0.4
            prop.entity.isEnabled = !beside && !Self.blocks(prop.entity.position, radius: prop.radius + Self.tile * 0.15, height: prop.height, eye: eye, target: target)
        }
    }

    private static func blocks(_ position: SIMD3<Float>, radius: Float, height: Float, eye: SIMD3<Float>, target: SIMD3<Float>) -> Bool {
        let centre = SIMD2(position.x, position.z)
        let from = SIMD2(eye.x, eye.z), to = SIMD2(target.x, target.z)
        let line = to - from
        let along = simd_dot(centre - from, line) / max(simd_length_squared(line), 0.0001)
        let nearest = from + line * min(max(along, 0), 1)
        return along > -0.2 && along < 1 && simd_distance(centre, nearest) < radius && eye.y < height + 0.4
    }

    private func addProp(_ entity: Entity) {
        root.addChild(entity)
        let bounds = entity.visualBounds(relativeTo: root)
        props.append((entity, bounds.max.y, max(bounds.extents.x, bounds.extents.z) / 2))
    }

    func setLabelsVisible(_ visible: Bool) {
        labelsVisible = visible
        for lot in lots.values {
            lot.root.isEnabled = visible && hovered == lot.id
            lot.beacon.isEnabled = visible && lot.waiting
        }
    }

    func closeUpPose(of id: UUID) -> CameraRig.Pose? {
        guard let lot = lots[id] else { return nil }
        return .init(target: lot.beacon.position - [0, 1.45, 0], yaw: 0.72, pitch: 0.45, distance: 7)
    }

    private func addEmptyLot(at position: SIMD3<Float>) {
        emptyLot = position
        addStreetlight(at: position)
        let pad = ModelEntity(mesh: .generateBox(width: 1.6, height: 0.04, depth: 1.6, cornerRadius: 0.2),
                              materials: [OfficeScene.material(Palette.resolved(Palette.sceneFloor, dark: dark))])
        pad.position = position + [0, 0.12, 0]
        pad.name = "lot:new"
        pad.components.set(CollisionComponent(shapes: [.generateBox(width: 1.8, height: 1.5, depth: 1.8).offsetBy(translation: [0, 0.75, 0])]))
        pad.components.set(InputTargetComponent())
        root.addChild(pad)
        let sign = Pod.banner(symbol: "signpost.right.fill", title: "For sale", colour: Palette.primaryFill, dark: dark)
        sign.position = [-0.35, 0.14, 0.35]
        sign.scale = SIMD3(repeating: 0.28)
        pad.addChild(sign)
        for offset in [SIMD3<Float>(0.55, 0.02, 0.6), [0.62, 0.02, 0.25], [-0.6, 0.02, -0.55]] {
            let cone = ModelEntity(mesh: .generateCone(height: 0.22, radius: 0.07),
                                   materials: [OfficeScene.material(Palette.resolved(Palette.primaryFill, dark: dark))])
            cone.position = offset + [0, 0.11, 0]
            pad.addChild(cone)
        }
        if titleMode {
            let robot = ModelLibrary.entity("robot")
            robot.position = position + [0.85, 0.1, 0.85]
            robot.scale = SIMD3(repeating: 0.42)
            robot.orientation = simd_quatf(angle: 0.72, axis: [0, 1, 0])
            root.addChild(robot)
            let worker = Worker(robot: robot, screen: nil, colour: Palette.primaryFill, room: "reception")
            worker.waving = true
            greeter = worker
        }
    }

    func titlePose() -> CameraRig.Pose {
        .init(target: emptyLot + [0, 0.5, 0], yaw: 0.72, pitch: 0.42, distance: 9)
    }

    func riseBuilding(_ id: UUID) {
        guard let facade = facades[id] else { return }
        facade.entity.position.y = 0.1 - facade.height
        if OfficeScene.reduceMotion {
            facade.entity.position.y = 0.1
        } else {
            rises.append((facade.entity, 0.1, facade.height, 0))
        }
        Sound.play(.thunk, after: .milliseconds(OfficeScene.reduceMotion ? 0 : 900))
        Sound.play(.bell, volume: 0.6, after: .milliseconds(OfficeScene.reduceMotion ? 150 : 1150))
    }

    private func addPark(at position: SIMD3<Float>, seed: Int) {
        for index in 0..<4 {
            let bush = ModelLibrary.entity("bush")
            let angle = Float(index + seed) * 1.7
            bush.position = position + [cos(angle) * 0.55, 0.1, sin(angle) * 0.55]
            bush.scale = [2, 2, 2]
            addProp(bush)
        }
        let bench = ModelLibrary.entity("bench")
        bench.position = position + [0, 0.1, 0]
        root.addChild(bench)
        var generator = SeededGenerator(seed: UInt64(seed))
        for index in 0..<36 {
            let angle = Float.random(in: 0...(2 * .pi), using: &generator), reach = Float.random(in: 0.3...0.78, using: &generator)
            let spot = position + [cos(angle) * reach, 0.1, sin(angle) * reach]
            let name = index % 6 == 0 ? (index % 12 == 0 ? "flowers_A" : "flowers_B") : "grass_tuft"
            cover[name, default: []].append(Foliage.placement(spot, yaw: angle * 3, scale: Float.random(in: 1.3...1.8, using: &generator)))
        }
        addStreetlight(at: position)
    }

    private func addStreetlight(at position: SIMD3<Float>) {
        let light = ModelLibrary.entity("streetlight")
        light.position = position + [0.85, 0.1, -0.85]
        NightLight.add(to: light, at: [-0.21, 0.87, 0], colour: Palette.streetlight, intensity: 40000, radius: 2.4, bulb: 0.03)
        addProp(light)
    }

    static func ground(dark: Bool) -> ModelEntity {
        let ground = ModelEntity(mesh: .generateCylinder(height: 0.1, radius: 400),
                                 materials: [OfficeScene.material(Palette.resolved(Palette.grass, dark: dark))])
        ground.position = [0, groundLevel - 0.05, 0]
        return ground
    }

    private func addTreeRing(halfWidth: Float) {
        var generator = SeededGenerator(seed: 7)
        for row in 0..<2 {
            let inset = halfWidth + 1 + Float(row) * 1.3
            let count = Int(inset * 8 / 1.4)
            for index in 0..<count {
                let along = (Float(index) + (row == 0 ? 0 : 0.5)) / Float(count) * 8 - 4
                let side = Int(floor((along + 4) / 2)) % 4
                let t = (along + 4).truncatingRemainder(dividingBy: 2) - 1
                let edge: SIMD2<Float> = switch side {
                case 0: [t * inset, -inset]
                case 1: [inset, t * inset]
                case 2: [-t * inset, inset]
                default: [-inset, -t * inset]
                }
                let jitter = SIMD2<Float>(Float.random(in: -0.3...0.3, using: &generator), Float.random(in: -0.3...0.3, using: &generator))
                let tree = ModelLibrary.entity("tree")
                tree.position = [edge.x + jitter.x, Self.groundLevel, edge.y + jitter.y]
                tree.scale = SIMD3(repeating: Float.random(in: 3.2...4.4, using: &generator))
                tree.orientation = simd_quatf(angle: Float.random(in: 0...(2 * .pi), using: &generator), axis: [0, 1, 0])
                addProp(tree)
            }
        }
    }

    /// Meadow, woodland and rocks beyond the tree ring, thinning out towards the horizon.
    private func addCountryside(halfWidth: Float) {
        var generator = SeededGenerator(seed: 11)
        let reach = halfWidth + 20
        func scatter(_ names: [String], tries: Int, from inner: Float, falloff: Float, scale: ClosedRange<Float>) {
            for _ in 0..<tries {
                let point = SIMD2<Float>(Float.random(in: -reach...reach, using: &generator), Float.random(in: -reach...reach, using: &generator))
                let beyond = max(abs(point.x), abs(point.y)) - inner
                guard beyond > 0, Float.random(in: 0...1, using: &generator) < exp(-beyond / falloff) else { continue }
                let name = names[Int.random(in: 0..<names.count, using: &generator)]
                cover[name, default: []].append(Foliage.placement([point.x, Self.groundLevel, point.y],
                                                                  yaw: Float.random(in: 0...(2 * .pi), using: &generator),
                                                                  scale: Float.random(in: scale, using: &generator)))
            }
        }
        scatter(["grass_tuft"], tries: 16000, from: halfWidth + 0.2, falloff: 8, scale: 1.2...1.8)
        scatter(["flowers_A", "flowers_B"], tries: 1600, from: halfWidth + 0.4, falloff: 5, scale: 1.4...1.9)
        scatter(["pebbles"], tries: 900, from: halfWidth + 0.2, falloff: 6, scale: 1.2...2)
        scatter(["rock_single_A", "rock_single_B", "rock_single_C", "rock_single_D", "rock_single_E"], tries: 500,
                from: halfWidth + 0.6, falloff: 8, scale: 0.8...2)
        scatter(["tree_single_A", "tree_single_B"], tries: 900, from: halfWidth + 4, falloff: 7, scale: 1.5...2.1)
        scatter(["trees_A_small", "trees_B_small", "trees_A_medium", "trees_B_medium"], tries: 700, from: halfWidth + 4.5, falloff: 9, scale: 1.3...1.8)
    }

    private func addCars(origin: Float, cells: Int) {
        let models = ["car_taxi", "car_sedan", "car_hatchback"]
        cars = []
        loop = (origin - 0.4, -2 * (origin - 0.4))
        let count = min(max(cells / 2, 3), 4)
        for index in 0..<count {
            let car = ModelLibrary.entity(models[index % models.count])
            NightLight.add(to: car, at: [0, 0.15, 0.6], colour: Palette.streetlight, intensity: 8000, radius: 1.2, bulb: 0)
            root.addChild(car)
            cars.append((car, Float(index) / Float(count) * loop.length * 4))
        }
        advanceCars(0)
    }

    private func advanceCars(_ dt: Double) {
        let perimeter = loop.length * 4
        for index in cars.indices {
            cars[index].along = (cars[index].along + Self.carSpeed * Float(dt)).truncatingRemainder(dividingBy: perimeter)
            let along = cars[index].along
            let side = Int(along / loop.length) % 4
            let t = along.truncatingRemainder(dividingBy: loop.length)
            let low = loop.origin, high = loop.origin + loop.length
            let (position, heading): (SIMD2<Float>, SIMD2<Float>) = switch side {
            case 0: ([low + t, low], [1, 0])
            case 1: ([high, low + t], [0, 1])
            case 2: ([high - t, high], [-1, 0])
            default: ([low, high - t], [0, -1])
            }
            cars[index].entity.position = [position.x, 0.1, position.y]
            cars[index].entity.orientation = simd_quatf(angle: atan2(heading.x, heading.y), axis: [0, 1, 0])
        }
    }

    func hover(at point: CGPoint?) {
        var found: UUID?
        if let point {
            let focal = Float(viewSize.height) / 2 / tan(26 * .pi / 360)
            var best = Float.infinity
            for (id, facade) in facades {
                let bounds = facade.entity.visualBounds(relativeTo: root)
                guard let (screen, depth) = camera.project(bounds.center, in: viewSize) else { continue }
                let distance = simd_distance(screen, SIMD2(Float(point.x), Float(point.y)))
                if distance < max(bounds.extents.x, bounds.extents.y) / 2 / depth * focal, distance < best {
                    best = distance
                    found = id
                }
            }
        }
        guard found != hovered else { return }
        hovered = found
        for lot in lots.values { lot.root.isEnabled = labelsVisible && lot.id == found }
    }

    private func setUpLighting() {
        root.addChild(lighting)
        sun.components.set(DirectionalLightComponent.Shadow(maximumDistance: 40, depthBias: 1.5))
        root.addChild(sun)
        applyDaylight()
    }

    static func skyExposure(_ cycle: DayCycle) -> Float { cycle.mix(day: 0.2, night: -3) }

    private func applyDaylight() {
        let cycle = DayCycle.now
        if let environment = ModelLibrary.environment("sky") {
            lighting.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: Self.skyExposure(cycle)))
        }
        var light = DirectionalLightComponent(color: cycle.sunColour, intensity: cycle.mix(day: 2800, night: 1100))
        light.isRealWorldProxy = false
        sun.components.set(light)
        sun.look(at: .zero, from: cycle.sun([-8, 14, 6]), relativeTo: nil)
        for facade in facades.values { Facade.light(facade.entity, glow: 0.6 * cycle.lamps) }
        for lot in lots.values where lot.working { lot.glow.components.set(lotGlow(cycle)) }
        NightLight.apply(cycle, under: root)
        SceneGrade.update(cycle)
    }

    private func lotGlow(_ cycle: DayCycle) -> PointLightComponent {
        PointLightComponent(color: Palette.resolved(Palette.lamp, dark: dark), intensity: cycle.mix(day: 5000, night: 9000), attenuationRadius: 2.2)
    }

    private func applyReceivers() {
        let receiver = ImageBasedLightReceiverComponent(imageBasedLight: lighting)
        for entity in root.descendants where entity.components.has(ModelComponent.self) {
            entity.components.set(receiver)
            if !entity.components.has(BillboardComponent.self), !entity.components.has(MeshInstancesComponent.self) {
                entity.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: true))
            }
        }
    }

    func overviewPose() -> CameraRig.Pose {
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let vertical: Float = 26 * .pi / 180
        let horizontal = 2 * atan(tan(vertical / 2) * aspect)
        let radius = extent * 0.62
        return .init(target: [0, 0.6, 0], yaw: 0.72, pitch: 0.7, distance: radius / sin(min(vertical, horizontal) / 2))
    }

    func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewSize = size
        camera.overview = overviewPose()
        camera.reset(to: titleMode ? titlePose() : camera.overview)
    }

    func flyTowards(_ id: UUID) {
        guard let pose = closeUpPose(of: id) else { return }
        camera.reset(to: pose)
    }

    static func target(of entity: Entity) -> String? {
        var node: Entity? = entity
        while let current = node {
            if current.name.hasPrefix("building:") || current.name.hasPrefix("lot:") { return current.name }
            node = current.parent
        }
        return nil
    }

    func update(_ dt: Double) {
        camera.smoothTime = OfficeScene.reduceMotion ? 0.12 : 0.5
        camera.update(Float(dt))
        for index in slides.indices {
            slides[index].elapsed += dt
            let slide = slides[index]
            let t = Float(min(slide.elapsed / slide.duration, 1))
            slide.entity.position.y = slide.from + (slide.to - slide.from) * t * t * (3 - 2 * t)
        }
        slides.removeAll { $0.elapsed >= $0.duration }
        for index in rises.indices {
            rises[index].elapsed += dt
            let rise = rises[index]
            let t = Float(min(rise.elapsed / Self.riseTime, 1))
            let ease = { (x: Float) in 1 - (1 - x) * (1 - x) * (1 - x) }
            let progress = t < 0.75 ? 1.05 * ease(t / 0.75) : 1.05 - 0.05 * ease((t - 0.75) / 0.25)
            rise.entity.position.y = rise.top - rise.height * (1 - progress)
        }
        rises.removeAll { $0.elapsed >= Self.riseTime }
        greeter?.update(dt, reduceMotion: OfficeScene.reduceMotion)
        if titleMode, !OfficeScene.reduceMotion {
            var pose = camera.goal
            pose.yaw += Float(dt) * 0.05
            camera.reset(to: pose)
        }
        clock += dt
        let still = OfficeScene.reduceMotion
        for lot in lots.values where lot.waiting {
            lot.beacon.position.y = lot.root.position.y - 0.3 + (still ? 0 : sin(Float(clock) * 2) * 0.06)
        }
        advanceCars(still ? 0 : dt)
        daylightClock += dt
        if daylightClock > DayCycle.tick {
            daylightClock = 0
            applyDaylight()
        }
        if clock.truncatingRemainder(dividingBy: 1) < dt { refresh() }
    }

    func refresh() {
        let city = CityStore.shared
        for building in buildings {
            guard let lot = lots[building.id] else { continue }
            let status = city.status(of: building)
            let colour = status.waiting > 0 ? Palette.manager : status.working > 0 ? Palette.primaryFill : Palette.muted
            let symbol = status.waiting > 0 ? "hand.raised.fill" : status.working > 0 ? "bolt.fill" : "building.2.fill"
            let floors = building.floors.isEmpty ? "Empty lot" : "\(building.floors.count) floor\(building.floors.count == 1 ? "" : "s")"
            let detail = status.waiting > 0 ? "Needs you" : status.working > 0 ? "\(status.working) working" : building.floors.isEmpty ? floors : "\(floors) · all quiet"
            let text = "\(building.name) · \(detail)"
            lot.waiting = status.waiting > 0
            lot.beacon.isEnabled = labelsVisible && lot.waiting
            if lot.working != (status.working > 0) {
                lot.working = status.working > 0
                if lot.working {
                    lot.glow.components.set(lotGlow(.now))
                } else {
                    lot.glow.components.remove(PointLightComponent.self)
                }
            }
            guard text != lot.labelText else { continue }
            lot.labelText = text
            lot.label?.removeFromParent()
            if let label = Billboard.make(BubbleView(symbol: symbol, text: text, colour: colour), dark: dark) {
                label.scale = [0.5, 0.5, 0.5]
                lot.root.addChild(label)
                lot.label = label
            }
        }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
