import AppKit
import OfficeCore
import RealityKit
import SwiftUI

@MainActor
final class OfficeScene {
    let root = Entity()
    private(set) var camera: CameraRig
    private var ownsCamera = true
    var isActive = true
    private(set) var focusedRoom: String?
    var updates: EventSubscription?

    private static let podSpacingX: Float = 7
    private static let rowZ: Float = 4
    private static let hopTime: Double = 1.1
    static let wallHeight: Float = 5.2
    static let floorThickness: Float = 0.3
    static let footprint = SIMD2<Float>(3 * podSpacingX + 4, rowZ * 2 + 9)
    private static let loftHeight: Float = 3.4
    private static let loftFront: Float = -3.5
    static let kioskRoom = "kiosk"
    static let kioskScreen = SIMD2<Float>(1.4, 0.9)
    static let kioskScreenCorner: Float = 0.05
    static let kioskScreenDepth: Float = 0.04
    // RealityKit clamps a box's corner radius to half its smallest side.
    static var kioskScreenRadius: Float { min(kioskScreenCorner, kioskScreenDepth / 2) }

    private var dark = true
    private var themed: [(ModelEntity, NSColor)] = []
    private var pods: [String: Pod] = [:]
    private var lofted: Set<String> = []
    private var order: [String] = []
    private var terminals: [String: Terminal] = [:]
    private var signs: [Entity] = []
    private var outboxBanner: Entity?
    private var lines: [String: (entity: ModelEntity, server: String)] = [:]
    private var flights: [Flight] = []
    private var folders: [String: ModelEntity] = [:]
    private var outboxItems: [ModelEntity] = []
    private var outboxSpot: SIMD3<Float> = .zero
    private var kioskScreen: ModelEntity?
    private var kioskLive = false
    private var jobFolder: ModelEntity?
    private var records: [Entity] = []
    static let wallKeeps = 12
    private var carried: (ModelEntity, Pod)?
    private var width: Float = 21
    private var viewSize = CGSize(width: 1000, height: 700)
    private let lighting = Entity()
    private let sun = Entity()
    private var daylightClock: Double = 0
    private var idleClock: Double = 0
    private var nextStroll = Double.random(in: 18...35)
    private var strolling: Pod?
    private var strollTask: Task<Void, Never>?

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {
        camera = CameraRig(overview: .init(target: [0, 0.5, 0], yaw: 0.62, pitch: 0.62, distance: 34))
        root.addChild(camera.entity)
    }

    // MARK: Building

    /// Hands camera control to a building, so moving between floors and robots is one continuous shot.
    func adopt(camera shared: CameraRig) {
        guard ownsCamera else { return }
        camera.entity.removeFromParent()
        camera = shared
        ownsCamera = false
    }

    func build(hired: [Department], servers: [McpServer], colour: (String) -> NSColor, dark: Bool) {
        self.dark = dark
        root.children.removeAll()
        if ownsCamera { root.addChild(camera.entity) }
        themed = []
        pods = [:]
        lofted = []
        order = hired.map(\.name)
        terminals = [:]
        signs = []
        lines = [:]
        flights = []
        folders = [:]
        outboxItems = []
        focusedRoom = nil

        let floor = themedModel(.generateBox(width: Self.footprint.x, height: Self.floorThickness, depth: Self.footprint.y, cornerRadius: 0.3), Palette.sceneFloor)
        floor.position = [0, -Self.floorThickness / 2, 0]
        root.addChild(floor)
        buildWalls(width: Self.footprint.x, depth: Self.footprint.y)

        let ground = min(hired.count, 3)
        let loftSpots = Self.loftLayout(count: hired.count - ground)
        if !loftSpots.isEmpty { buildLoft() }
        for (index, department) in hired.enumerated() {
            let position: SIMD3<Float>, scale: Float
            if index < ground {
                position = [(Float(index) - Float(ground - 1) / 2) * Self.podSpacingX, 0, -Self.rowZ]
                scale = 1
            } else {
                (position, scale) = loftSpots[index - ground]
                lofted.insert(department.name)
            }
            addPod(department.name, title: department.name.capitalized, number: "\(index + 1)", colour: colour(department.name),
                   at: position, variant: index)
            pods[department.name]?.root.scale = SIMD3(repeating: scale)
        }
        addPod("manager", title: "Manager", number: "M", colour: Palette.manager, at: [0, 0, Self.rowZ], variant: 3)
        addOutbox(at: [Self.podSpacingX, 0, Self.rowZ])
        addKiosk(at: [Self.podSpacingX / 2, 0, Self.rowZ])
        servers.forEach { _ = terminal(for: $0.name) }

        let folder = Self.makeFolder()
        folder.position = pods["manager"]!.deskTop + [0.3, 0, 0.6]
        root.addChild(folder)
        jobFolder = folder

        setUpLighting()
        if ownsCamera {
            camera.overview = overviewPose()
            camera.reset(to: camera.overview, animated: false)
            fit(viewSize)
        }
        applyReceivers()
        lightsOn()
    }

    private func addPod(_ room: String, title: String, number: String, colour: NSColor, at position: SIMD3<Float>, variant: Int) {
        let pod = Pod(room: room, colour: colour, at: position, variant: variant, dark: dark)
        root.addChild(pod.root)
        themed.append((pod.tile, colour))
        pod.hangBanner(symbol: Self.bannerSymbol(for: room), title: title, dark: dark)
        pods[room] = pod
    }

    private static func loftLayout(count: Int) -> [(SIMD3<Float>, Float)] {
        guard count > 0 else { return [] }
        let span = footprint.x - 1.6, depth = footprint.y / 2 + loftFront, centreX: Float = 0.8
        let rows = (1...count).max { a, b in loftScale(count, rows: a, span: span, depth: depth) < loftScale(count, rows: b, span: span, depth: depth) } ?? 1
        let columns = (count + rows - 1) / rows
        let scale = loftScale(count, rows: rows, span: span, depth: depth)
        let spacing = min(podSpacingX, span / Float(columns))
        return (0..<count).map { index in
            let row = index / columns
            let inRow = min(columns, count - row * columns)
            let x = centreX + (Float(index % columns) - Float(inRow - 1) / 2) * spacing
            let z = -footprint.y / 2 + depth * (Float(row) + 0.5) / Float(rows)
            return ([x, loftHeight, z], scale)
        }
    }

    private static func loftScale(_ count: Int, rows: Int, span: Float, depth: Float) -> Float {
        let columns = Float((count + rows - 1) / rows)
        return min(0.75, span / columns / 5.7, depth / Float(rows) / 5.4, (wallHeight - loftHeight) / 3.3)
    }

    private func buildLoft() {
        let depth = Self.footprint.y / 2 + Self.loftFront, left = -Self.footprint.x / 2
        let deck = themedModel(.generateBox(width: Self.footprint.x, height: 0.2, depth: depth, cornerRadius: 0.05), Palette.sceneFloor)
        deck.position = [0, Self.loftHeight - 0.1, -Self.footprint.y / 2 + depth / 2]
        root.addChild(deck)
        let stairWidth: Float = 0.8, steps = 10, tread: Float = 0.4
        for x in [-Self.podSpacingX / 2, Self.podSpacingX / 2, -left - 0.15] {
            let post = themedModel(.generateBox(width: 0.14, height: Self.loftHeight + 0.9, depth: 0.14), Palette.desk)
            post.position = [x, (Self.loftHeight + 0.9) / 2, Self.loftFront - 0.1]
            root.addChild(post)
        }
        let railLength = Self.footprint.x - stairWidth
        let rail = themedModel(.generateBox(width: railLength, height: 0.08, depth: 0.1, cornerRadius: 0.03), Palette.desk)
        rail.position = [left + stairWidth + railLength / 2, Self.loftHeight + 0.9, Self.loftFront - 0.1]
        root.addChild(rail)
        for index in 0..<steps {
            let rise = Self.loftHeight * Float(index + 1) / Float(steps)
            let step = themedModel(.generateBox(width: stairWidth, height: rise, depth: tread), Palette.desk)
            step.position = [left + stairWidth / 2, rise / 2, Self.loftFront + tread * (Float(steps - index) - 0.5)]
            root.addChild(step)
        }
    }

    private func addOutbox(at position: SIMD3<Float>) {
        let tile = themedModel(.generateBox(width: 5.4, height: 0.08, depth: 5.2, cornerRadius: 0.25), Palette.tray)
        tile.position = position + [0, 0.04, 0]
        tile.name = "room:outbox"
        root.addChild(tile)
        let cabinet = ModelLibrary.entity("cabinet_small_decorated")
        cabinet.position = position + [0, 0.08, -0.6]
        cabinet.scale = [1.3, 1.3, 1.3]
        root.addChild(cabinet)
        outboxSpot = position + [0, 0.08 + 1.62 * 1.3 + 0.05, -0.6]
        let tray = ModelEntity(mesh: .generateBox(width: 1.1, height: 0.1, depth: 0.8, cornerRadius: 0.04),
                               materials: [Self.material(Palette.tray)])
        tray.position = outboxSpot
        root.addChild(tray)
        outboxSpot.y += 0.08
        let plant = ModelLibrary.entity("cactus_medium_A")
        plant.position = position + [1.6, 0.08, 1.2]
        root.addChild(plant)
        let banner = Pod.banner(symbol: "tray.full.fill", title: "Outbox", colour: Palette.folder, dark: dark)
        banner.position += position
        root.addChild(banner)
        outboxBanner = banner
    }

    private func addKiosk(at position: SIMD3<Float>) {
        let size = SIMD3<Float>(1.6, 2.2, 0.6)
        let body = themedModel(.generateBox(width: size.x, height: size.y, depth: size.z, cornerRadius: 0.12), Palette.tray)
        body.position = position + [0, size.y / 2, 0]
        body.name = "room:\(Self.kioskRoom)"
        body.components.set(CollisionComponent(shapes: [.generateBox(size: size)]))
        body.components.set(InputTargetComponent())
        root.addChild(body)
        let screen = ModelEntity(mesh: .generateBox(width: Self.kioskScreen.x, height: Self.kioskScreen.y, depth: Self.kioskScreenDepth, cornerRadius: Self.kioskScreenCorner),
                                 materials: [UnlitMaterial(color: Palette.resolved(kioskLive ? Palette.screenOn : Palette.screenOff, dark: dark))])
        screen.position = position + [0, size.y - 0.1 - Self.kioskScreen.y / 2, size.z / 2 + 0.01]
        root.addChild(screen)
        kioskScreen = screen
    }

    func setKioskLive(_ live: Bool) {
        kioskLive = live
        kioskScreen?.model?.materials = [UnlitMaterial(color: Palette.resolved(live ? Palette.screenOn : Palette.screenOff, dark: dark))]
    }

    /// Cutaway walls on the back and left edges, with window openings the sky shows through.
    private func buildWalls(width: Float, depth: Float) {
        for piece in Self.walls(width: width, depth: depth, make: { self.themedModel($0, Palette.walls) }) { root.addChild(piece) }
    }

    static func walls(width: Float, depth: Float, doorway: Bool = false, make: (MeshResource) -> ModelEntity) -> [ModelEntity] {
        let height = wallHeight
        let thickness: Float = 0.35
        let sill: Float = 1.3
        let lintel: Float = 4.2
        var pieces: [ModelEntity] = []
        func wall(along length: Float, windows: Int, door: Bool, place: (ModelEntity, Float, Float) -> Void) {
            let bay = length / Float(windows)
            let pier: Float = 1.2
            for index in 0..<windows {
                let start = -length / 2 + Float(index) * bay
                let pierPiece = make(.generateBox(width: pier, height: height, depth: thickness))
                place(pierPiece, start + pier / 2, height / 2)
                let open = bay - pier
                if !(door && index == windows - 1) {
                    let below = make(.generateBox(width: open, height: sill, depth: thickness))
                    place(below, start + pier + open / 2, sill / 2)
                }
                let above = make(.generateBox(width: open, height: height - lintel, depth: thickness))
                place(above, start + pier + open / 2, lintel + (height - lintel) / 2)
            }
            let end = make(.generateBox(width: pier, height: height, depth: thickness))
            place(end, length / 2 - pier / 2, height / 2)
        }
        wall(along: width, windows: max(Int(width / 6), 2), door: false) { piece, x, y in
            piece.position = [x, y, -depth / 2 - thickness / 2]
            pieces.append(piece)
        }
        wall(along: depth, windows: max(Int(depth / 6), 2), door: doorway) { piece, z, y in
            piece.position = [-width / 2 - thickness / 2, y, z]
            piece.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
            pieces.append(piece)
        }
        return pieces
    }

    static func bannerSymbol(for room: String) -> String {
        let name = room.lowercased()
        if name == "manager" { return "person.crop.circle.fill" }
        if name == "contractor" { return "person.badge.plus" }
        if name.contains("research") { return "magnifyingglass" }
        if ["build", "engineer", "dev", "code"].contains(where: name.contains) { return "hammer.fill" }
        if ["review", "qa", "test", "audit"].contains(where: name.contains) { return "checkmark.seal.fill" }
        if name.contains("secur") { return "lock.shield.fill" }
        if ["design", "ux", "ui", "brand"].contains(where: name.contains) { return "paintpalette.fill" }
        return "briefcase.fill"
    }

    var sunEnabled: Bool {
        get { sun.isEnabled }
        set { sun.isEnabled = newValue }
    }

    private func setUpLighting() {
        root.addChild(lighting)
        sun.components.set(DirectionalLightComponent.Shadow(maximumDistance: 60, depthBias: 2))
        root.addChild(sun)
        applyDaylight()
    }

    static func studioExposure(_ cycle: DayCycle) -> Float { cycle.mix(day: 0.9, night: -1.6) }

    private func applyDaylight() {
        let cycle = DayCycle.now
        lighting.components.removeAll()
        if let environment = ModelLibrary.environment("studio") {
            lighting.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: Self.studioExposure(cycle)))
        }
        var light = DirectionalLightComponent(color: cycle.sunColour, intensity: cycle.mix(day: 2600, night: 700))
        light.isRealWorldProxy = false
        sun.components.set(light)
        sun.look(at: .zero, from: cycle.sun([-16, 14, -18]), relativeTo: nil)
        NightLight.apply(cycle, under: root)
        SceneGrade.update(cycle)
    }

    /// A warm glow under a lamp's shade, in the lamp model's own units.
    static func addLampLight(to lamp: Entity, standing: Bool) {
        NightLight.add(to: lamp, at: [0, standing ? 2.15 : 0.8, 0], colour: Palette.resolved(Palette.lamp, dark: false), intensity: standing ? 9000 : 5000,
                       radius: standing ? 5 : 3, bulb: 0.08)
    }

    private func applyReceivers() {
        let receiver = ImageBasedLightReceiverComponent(imageBasedLight: lighting)
        // Runs after every batch of stream events, so only entities added since the last pass are touched.
        for entity in [root] + root.descendants where entity.components.has(ModelComponent.self) {
            if entity.components[ImageBasedLightReceiverComponent.self]?.imageBasedLight === lighting { continue }
            entity.components.set(receiver)
            if !entity.components.has(BillboardComponent.self) {
                entity.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: true))
            }
        }
    }

    func setDark(_ dark: Bool) {
        guard dark != self.dark else { return }
        self.dark = dark
        for (entity, token) in themed {
            entity.model?.materials = [Self.material(Palette.resolved(token, dark: dark))]
        }
        setKioskLive(kioskLive)
        setUpLighting()
    }

    private func lightsOn() {
        guard !Self.reduceMotion else { return }
        for (index, room) in order.enumerated() {
            pods[room]?.flash(after: .milliseconds(90 * index))
            if isActive { Sound.play(.tick, volume: 0.35, rate: 1 + 0.12 * Float(index), after: .milliseconds(90 * index)) }
        }
    }

    // MARK: Camera

    func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewSize = size
        guard isActive else { return }
        let aspect = Float(size.width / size.height)
        let vertical: Float = 26 * .pi / 180
        let horizontal = 2 * atan(tan(vertical / 2) * aspect)
        let radius = 0.5 * simd_length(Self.footprint)
        var pose = overviewPose()
        pose.distance = radius / sin(min(vertical, horizontal) / 2) * 1.0
        camera.overview = pose
        if focusedRoom == nil { camera.reset(to: pose) } else if focusedRoom == Self.kioskRoom { focusKiosk() }
    }

    func overviewPose() -> CameraRig.Pose {
        .init(target: root.position(relativeTo: nil) + [0, 0.5, 0], yaw: 0.62, pitch: 0.62, distance: 34)
    }

    var trailingInset: CGFloat = 0

    func focus(room: String) {
        guard let pod = pods[room] ?? pods["contractor"] else { return }
        focusedRoom = room
        signs.forEach { $0.isEnabled = false }
        terminals.values.forEach { $0.setLabelVisible(false) }
        for (name, other) in pods {
            let asking = [.question, .approval].contains(other.worker.mood)
            other.setLabelsVisible(name == room && !asking, focused: name == room, overview: false)
        }
        outboxBanner?.isEnabled = false
        let settled: Float = 0.28
        let yaw: Float = .pi / 2 - 0.55, distance: Float = 8.5
        let worldPerPoint = viewSize.height > 0 ? 2 * distance * tan(13 * .pi / 180) / Float(viewSize.height) : 0
        let shift = SIMD3<Float>(cos(yaw), 0, -sin(yaw)) * Float(trailingInset / 2) * worldPerPoint
        camera.focus(on: pod.worker.headPosition - [0, 0.6, 0] + shift, facing: yaw, distance: distance,
                     pitch: settled + (Self.reduceMotion ? 0 : 2 * .pi / 180))
        guard !Self.reduceMotion else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.focusedRoom == room else { return }
            var pose = self.camera.goal
            pose.pitch = settled
            self.camera.reset(to: pose)
        }
    }

    /// Flies straight at the kiosk until its screen fills most of the window.
    func focusKiosk() {
        guard let screen = kioskScreen else { return }
        focusedRoom = Self.kioskRoom
        signs.forEach { $0.isEnabled = false }
        terminals.values.forEach { $0.setLabelVisible(false) }
        pods.values.forEach { $0.setLabelsVisible(false, overview: false) }
        outboxBanner?.isEnabled = false
        let spread = 2 * tan(13 * Float.pi / 180), aspect = Float(viewSize.width / max(viewSize.height, 1)), fill: Float = 0.85
        let distance = max(Self.kioskScreen.y / (spread * fill), Self.kioskScreen.x / (spread * aspect * fill))
        camera.focus(on: screen.position(relativeTo: nil) + [0, 0, 0.02], facing: 0, distance: distance, pitch: 0)
    }

    /// Where the kiosk's screen sits in the view once the camera arrives.
    func kioskScreenRect() -> CGRect? {
        guard focusedRoom == Self.kioskRoom, viewSize.height > 0 else { return nil }
        let focal = Float(viewSize.height) / 2 / tan(13 * .pi / 180)
        let size = Self.kioskScreen * focal / camera.goal.distance
        let width = CGFloat(size.x.rounded()), height = CGFloat(size.y.rounded())
        return CGRect(x: ((viewSize.width - width) / 2).rounded(), y: ((viewSize.height - height) / 2).rounded(), width: width, height: height)
    }

    func showOverview() {
        focusedRoom = nil
        signs.forEach { $0.isEnabled = true }
        terminals.values.forEach { $0.setLabelVisible(true) }
        pods.values.forEach { $0.setLabelsVisible(true) }
        outboxBanner?.isEnabled = true
        camera.reset(to: camera.overview)
    }

    func update(_ dt: Double) {
        let reduce = Self.reduceMotion
        if ownsCamera {
            camera.smoothTime = reduce ? 0.12 : 0.45
            camera.update(Float(dt))
        }
        for pod in pods.values {
            pod.worker.update(dt, reduceMotion: reduce)
            pod.tickClock(dark: dark)
        }
        advanceFlights(dt)
        carry()
        daylightClock += dt
        if daylightClock > DayCycle.tick {
            daylightClock = 0
            applyDaylight()
        }
        strollIfIdle(dt)
        Sound.setPatter(isActive && root.isEnabled && pods.values.contains { $0.worker.mood == .working }, for: self)
    }

    private func strollIfIdle(_ dt: Double) {
        let busy = !flights.isEmpty || carried != nil || strolling != nil
            || pods.values.contains { ![.idle, .done].contains($0.worker.mood) || $0.worker.isWalking }
        guard !Self.reduceMotion, !busy, isActive || root.isEnabled else { idleClock = 0; return }
        idleClock += dt
        guard idleClock > nextStroll else { return }
        idleClock = 0
        nextStroll = Double.random(in: 18...35)
        guard let pod = pods.filter({ $0.key != "manager" && $0.key != "contractor" && !lofted.contains($0.key) }).values.randomElement() else { return }
        let seat = pod.worker.seatPosition
        let aisle = SIMD3<Float>(seat.x + Float.random(in: 0.5...3), 0, Self.rowZ - 0.4)
        strolling = pod
        pod.worker.walk(through: [[seat.x, 0, 2.6], aisle]) { [weak self] in
            pod.worker.stretching = true
            self?.strollTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                pod.worker.stretching = false
                pod.worker.walk(through: [[seat.x, 0, 2.6], seat]) { self?.strolling = nil }
            }
        }
    }

    private func endStroll() {
        strollTask?.cancel()
        strollTask = nil
        strolling?.worker.sitDown()
        strolling = nil
        idleClock = 0
    }

    /// Which desk is under the pointer, projecting each robot's head with the rig's current pose and lens.
    func room(at point: CGPoint) -> String? {
        let focal = Float(viewSize.height) / 2 / tan(26 * .pi / 360)
        var best: (String, Float)?
        for (room, pod) in pods {
            guard let (screen, depth) = project(pod.worker.headPosition) else { continue }
            let distance = simd_distance(screen, SIMD2(Float(point.x), Float(point.y)))
            let reach = 2.2 / depth * focal
            if distance < reach, distance < (best?.1 ?? .infinity) { best = (room, distance) }
        }
        return best?.0
    }

    /// Where a card beside this room's robot starts, clear of the robot however close the camera is.
    func cardPoint(of room: String) -> CGPoint? {
        guard let pod = pods[room] ?? pods["contractor"], let (screen, depth) = project(pod.worker.headPosition) else { return nil }
        let clearance = max(40, CGFloat(camera.pixels(pod.worker.worldHalfWidth, atDepth: depth, in: viewSize)) + 20)
        return CGPoint(x: CGFloat(screen.x) + clearance, y: CGFloat(screen.y))
    }

    private func project(_ point: SIMD3<Float>) -> (SIMD2<Float>, Float)? {
        camera.project(point, in: viewSize)
    }

    static func room(of entity: Entity) -> String? {
        var current: Entity? = entity
        while let node = current {
            if node.name.hasPrefix("room:") { return String(node.name.dropFirst(5)) }
            current = node.parent
        }
        return nil
    }

    // MARK: Events

    func apply(_ events: [OfficeEvent]) {
        endStroll()
        if events.isEmpty { return reset() }
        for event in events {
            switch event {
            case .runStarted:
                reset()
            case .managerActive(let active):
                pods["manager"]?.worker.setMood(active ? .working : .idle)
            case .handoff(let id, let room, _):
                guard let manager = pods["manager"] else { break }
                let folder = Self.makeFolder()
                root.addChild(folder)
                folders[id] = folder
                jobFolder?.isEnabled = false
                fly(folder, from: manager.deskTop + [0.3, 0, 0.6], to: pod(for: room).deskTop + [0.3, 0, 0.6])
                if isActive { Sound.play(.whoosh, volume: 0.5) }
            case .roomStarted(_, let room):
                pod(for: room).worker.setCaption(ToolCaption.thinking)
                pod(for: room).worker.setMood(.working)
            case .roomActivity(let room, let tool, _):
                let pod = pod(for: room)
                pod.showBubble(symbol: Self.symbol(for: tool), text: Wording.verb(tool), dark: dark)
            case .roomCaption(let room, let caption):
                pod(for: room).worker.setCaption(caption)
            case .roomFinished(_, let room, let outcome):
                let pod = pod(for: room)
                pod.worker.setMood(outcome == .completed ? .done : .error)
                pod.showBubble(symbol: nil, text: nil, dark: dark)
            case .handback(let id, _, let isError):
                guard let folder = folders.removeValue(forKey: id), let manager = pods["manager"] else { break }
                if isError { folder.model?.materials = [Self.material(Palette.error)] }
                fly(folder, from: folder.position, to: manager.deskTop + [0.3, 0, 0.6]) { [weak self] in
                    folder.removeFromParent()
                    if let self, self.folders.isEmpty { self.jobFolder?.isEnabled = true }
                }
            case .handRaised(let request, let room):
                let pod = pod(for: room)
                let isQuestion = if case .question = request.kind { true } else { false }
                pod.worker.setMood(isQuestion ? .question : .approval)
                let text = isQuestion ? "Has a question" : "Needs approval"
                Sound.play(isActive ? .boop : .ping, volume: 0.7)
                pod.showBubble(symbol: "hand.raised.fill", text: text, dark: dark)
            case .handLowered(_, let room):
                let pod = pod(for: room)
                if [.question, .approval].contains(pod.worker.mood) {
                    pod.worker.setMood(.working)
                    let answer = Self.makeFolder()
                    root.addChild(answer)
                    fly(answer, from: pod.worker.headPosition - root.position(relativeTo: nil) + [0.8, 0.8, 0], to: pod.deskTop + [0.3, 0, 0.6]) {
                        answer.removeFromParent()
                    }
                }
                pod.showBubble(symbol: nil, text: nil, dark: dark)
            case .skillLoaded(let room, let skill):
                pod(for: room).addBook(skill, dark: dark)
            case .serviceCall(let id, let room, let server, let active):
                let terminal = terminal(for: server)
                if active {
                    let line = Self.connector(from: root.convert(position: pod(for: room).worker.headPosition, from: nil), to: terminal.root.position + [0, 2.2, 0])
                    root.addChild(line)
                    lines[id] = (line, server)
                } else {
                    lines.removeValue(forKey: id)?.entity.removeFromParent()
                }
                terminal.setActive(lines.values.contains { $0.server == server })
            case .tallyChanged:
                break
            case .runEnded(let outcome):
                for pod in pods.values {
                    pod.worker.setMood(.idle)
                    pod.showBubble(symbol: nil, text: nil, dark: dark)
                }
                jobFolder?.isEnabled = true
                switch outcome {
                case .completed:
                    guard let manager = pods["manager"], let jobFolder else { break }
                    let artefact = Self.makeFolder()
                    root.addChild(artefact)
                    jobFolder.isEnabled = false
                    deliver(artefact, by: manager)
                case .cancelled, .failed:
                    jobFolder?.model?.materials = [Self.material(Palette.error)]
                    pods["manager"]?.worker.setMood(.error)
                }
            }
        }
        applyReceivers()
    }

    private func reset() {
        folders.values.forEach { $0.removeFromParent() }
        folders = [:]
        flights = []
        lines.values.forEach { $0.entity.removeFromParent() }
        lines = [:]
        terminals.values.forEach { $0.setActive(false) }
        for pod in pods.values {
            pod.worker.setMood(.idle)
            pod.worker.resetClock()
            pod.showBubble(symbol: nil, text: nil, dark: dark)
            pod.clearBooks()
        }
        jobFolder?.model?.materials = [Self.material(Palette.folder)]
        if let manager = pods["manager"] { jobFolder?.position = manager.deskTop + [0.3, 0, 0.6] }
        jobFolder?.isEnabled = true
    }

    static let outboxKeeps = 5

    func showRecords(_ jobs: [JobRecord], fastest: TimeInterval?) {
        records.forEach { $0.removeFromParent() }
        records = []
        let depth = Self.rowZ * 2 + 9
        for (index, job) in jobs.suffix(Self.wallKeeps).enumerated() {
            guard let card = Billboard.make(FramedJobView(job: job), dark: dark, faceCamera: false) else { continue }
            card.scale = SIMD3(repeating: 0.2)
            card.position = [-width / 2 + 0.6 + Float(index) * 1.05, 0.72, -depth / 2 + 0.03]
            root.addChild(card)
            records.append(card)
        }
        if jobs.count > Self.wallKeeps {
            let binder = ModelEntity(mesh: .generateBox(width: 0.14, height: 0.42, depth: 0.34, cornerRadius: 0.02),
                                     materials: [Self.material(Palette.resolved(Palette.tray, dark: dark))])
            binder.position = [width / 2 + 1.2, 0.29, -depth / 2 + 0.4]
            root.addChild(binder)
            records.append(binder)
            if let label = Billboard.make(BubbleView(symbol: "books.vertical.fill", text: "Records · \(jobs.count) jobs", colour: Palette.tray), dark: dark) {
                label.position = binder.position + [0, 0.7, 0]
                label.scale = SIMD3(repeating: 0.45)
                root.addChild(label)
                records.append(label)
                signs.append(label)
            }
        }
        guard let fastest, let manager = pods["manager"] else { return }
        let gold = Self.material(Palette.resolved(Palette.folder, dark: dark))
        let trophy = Entity()
        trophy.position = manager.deskTop + [0.3, 0, -0.7]
        let base = ModelEntity(mesh: .generateBox(width: 0.2, height: 0.06, depth: 0.2, cornerRadius: 0.02),
                               materials: [Self.material(Palette.resolved(Palette.desk, dark: dark))])
        base.position = [0, 0.03, 0]
        let stem = ModelEntity(mesh: .generateCylinder(height: 0.12, radius: 0.025), materials: [gold])
        stem.position = [0, 0.12, 0]
        let cup = ModelEntity(mesh: .generateCylinder(height: 0.16, radius: 0.1), materials: [gold])
        cup.position = [0, 0.26, 0]
        [base, stem, cup].forEach { trophy.addChild($0) }
        root.addChild(trophy)
        records.append(trophy)
        if let label = Billboard.make(BubbleView(symbol: "trophy.fill", text: "Fastest job · \(RunController.clock(fastest))", colour: Palette.folder), dark: dark) {
            label.position = trophy.position + [0, 0.8, 0]
            label.scale = SIMD3(repeating: 0.45)
            root.addChild(label)
            records.append(label)
            signs.append(label)
        }
        applyReceivers()
    }

    private func deliver(_ artefact: ModelEntity, by manager: Pod) {
        let start = manager.deskTop + [0.3, 0, 0.6]
        guard !Self.reduceMotion, !manager.worker.isWalking else {
            fly(artefact, from: start, to: nextOutboxSlot()) { [weak self] in self?.land(artefact) }
            return
        }
        let seat = manager.worker.seatPosition
        let outbox = outboxSpot - manager.root.position
        let aisle: Float = 2.3
        artefact.position = start
        carried = (artefact, manager)
        manager.worker.walk(through: [[seat.x, 0, aisle], [outbox.x, 0, aisle], [outbox.x, 0, outbox.z + 1.5]]) { [weak self] in
            guard let self else { return }
            self.carried = nil
            self.fly(artefact, from: artefact.position, to: self.nextOutboxSlot(), height: 0.5) { self.land(artefact) }
            manager.worker.walk(through: [[outbox.x, 0, aisle], [seat.x, 0, aisle], seat])
        }
    }

    private func nextOutboxSlot() -> SIMD3<Float> {
        outboxSpot + [0, Float(min(outboxItems.count, Self.outboxKeeps - 1)) * 0.1, 0]
    }

    private func land(_ artefact: ModelEntity) {
        outboxItems.append(artefact)
        while outboxItems.count > Self.outboxKeeps { outboxItems.removeFirst().removeFromParent() }
        for (index, item) in outboxItems.enumerated() { item.position = outboxSpot + [0, Float(index) * 0.1, 0] }
        Sound.play(.drop)
        Sound.play(.bell, volume: 0.6, after: .milliseconds(250))
    }

    private func carry() {
        guard let (folder, manager) = carried else { return }
        let robot = manager.worker.root
        let forward = robot.orientation.act([0, 0, 1])
        folder.position = manager.root.position + robot.position + forward * 0.65 + [0, 1.05, 0]
        folder.orientation = robot.orientation
    }

    private func pod(for room: String) -> Pod {
        if let pod = pods[room] { return pod }
        if let pod = pods["contractor"] { return pod }
        addPod("contractor", title: "Contractor", number: "+", colour: Palette.muted, at: [-Self.podSpacingX, 0, Self.rowZ], variant: 2)
        applyReceivers()
        return pods["contractor"]!
    }

    // MARK: Folders in flight

    private struct Flight {
        let entity: Entity
        let from: SIMD3<Float>
        let to: SIMD3<Float>
        var height: Float = 3.2
        var elapsed: Double = 0
        var landed = false
        let done: (() -> Void)?
    }

    private func fly(_ entity: Entity, from: SIMD3<Float>, to: SIMD3<Float>, height: Float = 3.2, done: (() -> Void)? = nil) {
        entity.position = from
        if Self.reduceMotion {
            entity.position = to
            done?()
            return
        }
        flights.append(Flight(entity: entity, from: from, to: to, height: height, done: done))
    }

    static let anticipation: Double = 0.12
    static let squash: Double = 0.15

    private func advanceFlights(_ dt: Double) {
        var landed: [Flight] = []
        var finished: [Flight] = []
        for index in flights.indices {
            flights[index].elapsed += dt
            let flight = flights[index]
            let lift = SIMD3<Float>(0, 0.15, 0)
            if flight.elapsed < Self.anticipation {
                let t = Float(flight.elapsed / Self.anticipation)
                flight.entity.position = flight.from + lift * (t * t * (3 - 2 * t))
                continue
            }
            let t = Float(min((flight.elapsed - Self.anticipation) / Self.hopTime, 1))
            if t < 1 {
                let eased = t * t * (3 - 2 * t)
                let height = flight.height * 4 * eased * (1 - eased)
                flight.entity.position = simd_mix(flight.from + lift, flight.to, SIMD3(repeating: eased)) + [0, height, 0]
                flight.entity.orientation = simd_quatf(angle: eased * .pi / 2, axis: [0, 1, 0])
                continue
            }
            if !flight.landed {
                flights[index].landed = true
                flight.entity.position = flight.to
                landed.append(flight)
            }
            let squash = Float(min((flight.elapsed - Self.anticipation - Self.hopTime) / Self.squash, 1))
            let amount = sin(squash * .pi)
            flight.entity.scale = SIMD3(1 + 0.15 * amount, 1 - 0.2 * amount, 1 + 0.15 * amount)
            if squash >= 1 {
                flight.entity.scale = .one
                finished.append(flight)
            }
        }
        flights.removeAll { flight in finished.contains { $0.entity === flight.entity } }
        landed.forEach { $0.done?() }
    }

    // MARK: Terminals

    private func terminal(for server: String) -> Terminal {
        if let terminal = terminals[server] { return terminal }
        let index = terminals.count
        let slots = max(Int((width + 2) / 2.6), 1)
        let x = -width / 2 + 1.2 + Float(index % slots) * 2.6
        let terminal = Terminal(name: Self.shortName(server), at: [x, 0, -Self.rowZ - 4.2 - Float(index / slots) * 1.6], dark: dark)
        root.addChild(terminal.root)
        terminals[server] = terminal
        return terminal
    }

    nonisolated static func shortName(_ server: String) -> String {
        if server.hasPrefix("claude.ai ") { return String(server.dropFirst("claude.ai ".count)) }
        if server.hasPrefix("plugin:") { return server.components(separatedBy: ":").last ?? server }
        return server
    }

    static func symbol(for tool: String) -> String {
        if tool.hasPrefix("mcp__") { return "antenna.radiowaves.left.and.right" }
        return switch tool {
        case "Read", "NotebookRead": "doc.text.magnifyingglass"
        case "Glob", "Grep", "LS": "magnifyingglass"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": "pencil.line"
        case "Bash", "BashOutput": "terminal.fill"
        case "WebFetch", "WebSearch": "globe"
        case "Skill": "book.closed.fill"
        case "ToolSearch": "wrench.and.screwdriver.fill"
        case "TodoWrite": "checklist"
        default: "sparkles"
        }
    }

    private static func connector(from start: SIMD3<Float>, to end: SIMD3<Float>) -> ModelEntity {
        let line = ModelEntity(mesh: .generateBox(width: 0.06, height: 0.06, depth: simd_distance(start, end)),
                               materials: [UnlitMaterial(color: Palette.screenOn)])
        line.position = (start + end) / 2
        line.look(at: end, from: line.position, relativeTo: nil)
        return line
    }

    // MARK: Helpers

    private func themedModel(_ mesh: MeshResource, _ token: NSColor) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh, materials: [Self.material(Palette.resolved(token, dark: dark))])
        themed.append((entity, token))
        return entity
    }

    static func material(_ colour: NSColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: colour)
        material.roughness = 0.6
        return material
    }

    static func makeFolder() -> ModelEntity {
        ModelEntity(mesh: .generateBox(width: 0.62, height: 0.09, depth: 0.46, cornerRadius: 0.03), materials: [material(Palette.folder)])
    }
}

/// One department's corner: tile, desk, robot, props, and whatever floats above it.
@MainActor
final class Pod {
    let room: String
    let colour: NSColor
    let root = Entity()
    let tile: ModelEntity
    let worker: Worker
    let deskTop: SIMD3<Float>
    private var bubble: Entity?
    private var labelsVisible = true
    private var bubbleScale: Float = 1
    private var books: [Entity] = []
    private var bookTitles: [String] = []
    private var bookLabel: Entity?
    private let clockFace = ModelEntity()
    private var clockShown = -1

    init(room: String, colour: NSColor, at position: SIMD3<Float>, variant: Int, dark: Bool) {
        self.room = room
        self.colour = colour
        root.position = position
        tile = ModelEntity(mesh: .generateBox(width: 5.4, height: 0.08, depth: 5.2, cornerRadius: 0.25),
                           materials: [OfficeScene.material(Palette.resolved(colour, dark: dark))])
        tile.position = [0, 0.04, 0]
        tile.name = "room:\(room)"
        tile.components.set(CollisionComponent(shapes: [.generateBox(width: 5.4, height: 3.6, depth: 5.2).offsetBy(translation: [0, 1.8, 0])]))
        tile.components.set(InputTargetComponent())
        root.addChild(tile)

        let base = root
        func place(_ name: String, _ offset: SIMD3<Float>, yaw: Float = 0, scale: Float = 1) -> Entity {
            let entity = ModelLibrary.entity(name)
            entity.position = offset + [0, 0.08, 0]
            entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            entity.scale = [scale, scale, scale]
            base.addChild(entity)
            return entity
        }
        _ = place("table_medium_long", [0.3, 0, 0], yaw: .pi / 2)
        let top: Float = 1.08
        deskTop = position + [0.3, top, 0]
        NightLight.add(to: base, at: [0.3, 2.2, 0.4], colour: Palette.resolved(Palette.lamp, dark: false), intensity: 150000, radius: 4, bulb: 0)
        let monitor = place("monitor", [0.65, top - 0.08, 0.1], yaw: -.pi / 2, scale: 1.7)
        _ = place("keyboard", [0.15, top - 0.08, 0.1], yaw: -.pi / 2, scale: 1.6)
        _ = place("mug", [0.2, top - 0.08, 0.95], scale: 1.6)
        _ = place("chair_C", [-1.35, 0, 0.1], yaw: .pi / 2)
        let robot = place("robot", [-1.2, 0.38, 0.1], yaw: .pi / 2, scale: 1.4)
        worker = Worker(robot: robot, screen: monitor.descendant(named: "Screen"), colour: colour, room: room)
        let clockBody = ModelEntity(mesh: .generateBox(width: 0.62, height: 0.36, depth: 0.2, cornerRadius: 0.06),
                                    materials: [OfficeScene.material(Palette.resolved(Palette.walls, dark: dark))])
        clockBody.position = [-0.1, top + 0.18, 0.95]
        clockBody.orientation = simd_quatf(angle: -.pi / 2 + 0.5, axis: [0, 1, 0])
        root.addChild(clockBody)
        clockFace.model = ModelComponent(mesh: .generatePlane(width: 0.52, height: 0.26, cornerRadius: 0.03), materials: [])
        clockFace.position = [0, 0, 0.101]
        clockBody.addChild(clockFace)
        switch variant % 4 {
        case 0:
            _ = place("cactus_medium_A", [-1.9, 0, -1.8], scale: 0.9)
            _ = place("shelf_B_small_decorated", [1.4, 0, -2.0], scale: 1.1)
        case 1:
            OfficeScene.addLampLight(to: place("lamp_standing", [-2.0, 0, -1.7], scale: 0.75), standing: true)
            _ = place("book_set", [0.7, top - 0.08 + 0.25, -1.05], yaw: .pi / 2, scale: 0.8)
            _ = place("cactus_small_B", [2.0, 0, 1.9])
        case 2:
            _ = place("shelf_B_small_decorated", [-1.9, 0, -2.0], scale: 1.1)
            _ = place("pictureframe_standing_A", [0.7, top - 0.08, -1.0], yaw: .pi / 2)
        default:
            _ = place("armchair_pillows", [1.8, 0, -1.6], yaw: -.pi / 4, scale: 0.8)
            OfficeScene.addLampLight(to: place("lamp_table", [0.7, top - 0.08, -1.0], scale: 0.6), standing: false)
        }
    }

    static func banner(symbol: String, title: String, colour: NSColor, dark: Bool) -> Entity {
        let holder = Entity()
        holder.position = [-2.35, 0, 2.05]
        let wood = OfficeScene.material(Palette.resolved(Palette.desk, dark: dark))
        let pole = ModelEntity(mesh: .generateBox(width: 0.07, height: 3.3, depth: 0.07, cornerRadius: 0.035), materials: [wood])
        pole.position = [0, 1.65, 0]
        holder.addChild(pole)
        let arm = ModelEntity(mesh: .generateBox(width: 1.25, height: 0.05, depth: 0.05, cornerRadius: 0.025), materials: [wood])
        arm.position = [0.6, 3.25, 0]
        holder.addChild(arm)
        let base = ModelEntity(mesh: .generateCylinder(height: 0.06, radius: 0.28), materials: [wood])
        base.position = [0, 0.11, 0]
        holder.addChild(base)
        if let cloth = Billboard.make(BannerView(symbol: symbol, title: title, colour: colour), dark: dark, faceCamera: false) {
            cloth.scale = [0.5, 0.5, 0.5]
            let height = cloth.visualBounds(relativeTo: nil).extents.y
            cloth.position = [0.6, 3.22 - height / 2, 0]
            cloth.orientation = simd_quatf(angle: 0.62, axis: [0, 1, 0])
            holder.addChild(cloth)
        }
        return holder
    }

    private(set) var banner: Entity?

    func hangBanner(symbol: String, title: String, dark: Bool) {
        let flag = Self.banner(symbol: symbol, title: title, colour: colour, dark: dark)
        root.addChild(flag)
        banner = flag
    }

    func tickClock(dark: Bool) {
        let seconds = Int(worker.workedFor)
        guard seconds != clockShown else { return }
        clockShown = seconds
        let text = seconds < 3600 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : String(format: "%dh%02d", seconds / 3600, seconds / 60 % 60)
        let renderer = ImageRenderer(content: ClockFaceView(text: text))
        renderer.scale = 1.5
        guard let image = renderer.cgImage, let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else { return }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        clockFace.model?.materials = [material]
    }

    func flash(after delay: Duration) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.worker.mood == .idle else { return }
            self.worker.setMood(.working)
            try? await Task.sleep(for: .milliseconds(450))
            if self.worker.mood == .working { self.worker.setMood(.idle) }
        }
    }

    func showBubble(symbol: String?, text: String?, dark: Bool) {
        bubble?.removeFromParent()
        bubble = nil
        guard let symbol, let text, let plane = Billboard.make(BubbleView(symbol: symbol, text: text, colour: colour), dark: dark) else { return }
        plane.position = [-1.2, bubbleScale < 1 ? 2.6 : 3.4, 0.1]
        plane.isEnabled = labelsVisible
        plane.scale = SIMD3(repeating: bubbleScale)
        root.addChild(plane)
        bubble = plane
    }

    func addBook(_ title: String, dark: Bool) {
        guard !bookTitles.contains(title) else { return }
        bookTitles.append(title)
        let book = ModelEntity(mesh: .generateBox(width: 0.42, height: 0.1, depth: 0.32, cornerRadius: 0.02),
                               materials: [OfficeScene.material(colour)])
        book.position = [-0.2, 1.08 + Float(books.count) * 0.105, -0.9]
        root.addChild(book)
        books.append(book)
        bookLabel?.removeFromParent()
        if let label = Billboard.make(BubbleView(symbol: "book.closed.fill", text: bookTitles.joined(separator: ", "), colour: colour), dark: dark) {
            label.position = [0.3, 2.3, -1.1]
            label.scale = [0.6, 0.6, 0.6]
            root.addChild(label)
            bookLabel = label
        }
    }

    func setLabelsVisible(_ visible: Bool, focused: Bool = false, overview: Bool = true) {
        labelsVisible = visible
        banner?.isEnabled = overview
        bubbleScale = focused ? 0.55 : 1
        bubble?.position.y = focused ? 2.6 : 3.4
        bubble?.isEnabled = visible
        bubble?.scale = SIMD3(repeating: bubbleScale)
        bookLabel?.isEnabled = visible
    }

    func clearBooks() {
        books.forEach { $0.removeFromParent() }
        books = []
        bookTitles = []
        bookLabel?.removeFromParent()
        bookLabel = nil
    }
}

@MainActor
final class Terminal {
    let root = Entity()
    private let screen: ModelEntity
    private var label: Entity?

    init(name: String, at position: SIMD3<Float>, dark: Bool) {
        root.position = position
        let body = ModelEntity(mesh: .generateBox(width: 1.3, height: 2.0, depth: 0.6, cornerRadius: 0.12),
                               materials: [OfficeScene.material(Palette.tray)])
        body.position = [0, 1.0, 0]
        root.addChild(body)
        screen = ModelEntity(mesh: .generateBox(width: 0.95, height: 0.6, depth: 0.04, cornerRadius: 0.05),
                             materials: [UnlitMaterial(color: Palette.screenOff)])
        screen.position = [0, 1.45, 0.31]
        root.addChild(screen)
        if let label = Billboard.make(BubbleView(symbol: "antenna.radiowaves.left.and.right", text: name, colour: Palette.muted), dark: dark) {
            label.position = [0, 2.7, 0]
            root.addChild(label)
            self.label = label
        }
    }

    func setLabelVisible(_ visible: Bool) { label?.isEnabled = visible }

    func setActive(_ active: Bool) {
        screen.model?.materials = [UnlitMaterial(color: active ? Palette.screenOn : Palette.screenOff)]
    }
}
