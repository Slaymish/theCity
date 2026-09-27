import AppKit
import Metal
import OfficeCore
import RealityKit
import SwiftUI

@MainActor
enum OffscreenRenderer {
    static func render(root: Entity, camera: Entity, width: Int, height: Int,
                       environment: EnvironmentResource? = nil, exposure: Float = 0,
                       background: CGColor = CGColor(gray: 0, alpha: 0)) throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
        let renderer = try RealityRenderer()
        renderer.entities.append(root)
        if camera.parent == nil { renderer.entities.append(camera) }
        renderer.activeCamera = camera
        renderer.cameraSettings.colorBackground = .color(background)
        if let environment {
            renderer.lighting.resource = environment
            renderer.lighting.intensityExponent = exposure
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw CocoaError(.featureUnsupported) }
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        for _ in 0..<3 { try renderer.update(1.0 / 60) }
        let done = DispatchSemaphore(value: 0)
        try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output, onComplete: { _ in done.signal() })
        guard done.wait(timeout: .now() + 20) == .success else { throw CocoaError(.fileWriteUnknown) }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!.makeImage()!
    }

    static func composite(_ base: CGImage, overlay: some View, leadingAt point: CGPoint) throws -> CGImage {
        let renderer = ImageRenderer(content: overlay)
        renderer.scale = 1
        guard let card = renderer.cgImage,
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let y = min(max(point.y - CGFloat(card.height) / 2, 20), CGFloat(base.height - card.height) - 20)
        let x = min(point.x, CGFloat(base.width - card.width) - 20)
        context.draw(card, in: CGRect(x: x, y: CGFloat(base.height) - y - CGFloat(card.height), width: CGFloat(card.width), height: CGFloat(card.height)))
        guard let result = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return result
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}

/// `TheCity -render-preview <out.png> [-focus <room>] [-theme light] [-city | -building [-floor n | -lobby]]`: real scenes with sample data.
@MainActor
enum PreviewStage {
    static func renderCityOrBuilding(to path: String, dark: Bool, arguments: [String]) throws {
        let workspace = URL(fileURLWithPath: RunController.launchArgument("-workspace") ?? FileManager.default.currentDirectoryPath)
        let names = ["theCity", "alphero-web", "client-portal", "docs-site", "infra"]
        var buildings = names.enumerated().map { index, name in
            CityStore.Building(name: name, path: workspace.path, style: index * 3 % 8)
        }
        let size = CGSize(width: 1600, height: 1000)
        if arguments.contains("-title") {
            let city = CityScene()
            city.titleMode = true
            city.build([], dark: dark)
            city.fit(size)
            if let seconds = RunController.launchArgument("-rise").flatMap(Double.init) {
                city.titleMode = false
                city.build([buildings[0]], dark: dark)
                city.riseBuilding(buildings[0].id)
                city.flyTowards(buildings[0].id)
                for _ in 0..<Int(seconds * 60) { city.update(1.0 / 60) }
            } else {
                for _ in 0..<60 { city.update(1.0 / 60) }
            }
            let image = try OffscreenRenderer.render(root: city.root, camera: city.camera.entity, width: 1600, height: 1000,
                                                     environment: ModelLibrary.environment("sky"), exposure: dark ? -0.5 : 0.6,
                                                     background: Palette.resolved(Palette.background, dark: dark).cgColor)
            return try OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: path))
        }
        if arguments.contains("-city") {
            let city = CityScene()
            city.build(buildings, dark: dark)
            city.fit(size)
            for _ in 0..<30 { city.update(1.0 / 60) }
            let image = try OffscreenRenderer.render(root: city.root, camera: city.camera.entity, width: 1600, height: 1000,
                                                     environment: ModelLibrary.environment("sky"), exposure: dark ? -0.5 : 0.6,
                                                     background: Palette.resolved(Palette.background, dark: dark).cgColor)
            return try OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: path))
        }
        buildings[0].floors = [
            .init(name: "Feature: login", hires: ["research", "build", "review"], budgetUSD: 1),
            .init(name: "Security review", hires: ["research", "review"], budgetUSD: 2),
            .init(name: "Docs", hires: ["design", "build"], budgetUSD: 1),
        ]
        let building = buildings[0]
        let sessions = building.floors.map { floor in (floor.id, RunController(building: building, floor: floor)) }
        sessions[1].1.scene.apply([.runStarted, .roomStarted(toolUseID: "a", room: "review"), .roomActivity(room: "review", toolName: "Grep")])
        if let seconds = RunController.launchArgument("-world").flatMap(Double.init) {
            let world = World()
            world.city.build(buildings, dark: dark)
            world.fit(size)
            world.city.flyTowards(building.id)
            for _ in 0..<60 { world.update(1.0 / 60) }
            world.building.show(building, sessions: sessions, dark: dark)
            world.enter(building.id, animated: true)
            for _ in 0..<Int(seconds * 60) { world.update(1.0 / 60) }
            if let back = RunController.launchArgument("-leave").flatMap(Double.init) {
                world.leave(animated: false)
                for _ in 0..<Int(back * 60) { world.update(1.0 / 60) }
            }
            let image = try OffscreenRenderer.render(root: world.root, camera: world.camera.entity, width: 1600, height: 1000,
                                                     environment: ModelLibrary.environment("sky"), exposure: dark ? -0.5 : 0.6,
                                                     background: Palette.resolved(Palette.background, dark: dark).cgColor)
            return try OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: path))
        }
        let tower = BuildingScene()
        tower.show(building, sessions: sessions, dark: dark)
        tower.fit(size)
        if let index = RunController.launchArgument("-floor").flatMap(Int.init), index < sessions.count {
            tower.enter(floor: sessions[index].0)
        } else if arguments.contains("-lobby") {
            tower.focusLobby()
            if let pick = RunController.launchArgument("-reception") {
                tower.receptionist(thinking: false, pointingAt: Int(pick).map { sessions[$0].0 }, scaffold: pick == "new")
            }
        }
        for _ in 0..<240 { tower.update(1.0 / 60) }
        let image = try OffscreenRenderer.render(root: tower.root, camera: tower.camera.entity, width: 1600, height: 1000,
                                                 environment: ModelLibrary.environment("studio"), exposure: dark ? 0.2 : 0.9,
                                                 background: Palette.resolved(Palette.background, dark: dark).cgColor)
        try OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: path))
    }

    static func run(to path: String) {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            let dark = RunController.launchArgument("-theme") != "light"
            if arguments.contains("-parallel-test") {
                let workspace = URL(fileURLWithPath: RunController.launchArgument("-workspace") ?? FileManager.default.currentDirectoryPath)
                let building = CityStore.Building(name: "Parallel test", path: workspace.path, style: 0)
                let floors: [(CityStore.Floor, String)] = [
                    (.init(name: "Builders", hires: ["build"], model: "haiku", budgetUSD: 0.3),
                     "Use the build subagent to write parallel-a.txt containing the single word alpha."),
                    (.init(name: "Researchers", hires: ["research"], model: "haiku", budgetUSD: 0.3),
                     "Use the research subagent to say in one line what README.md is about. Do not write files."),
                ]
                let sessions = floors.map { RunController(building: building, floor: $0.0) }
                Task { @MainActor in
                    let started = Date()
                    for _ in 0..<60 where sessions.contains(where: { $0.readiness != .ready }) { try? await Task.sleep(for: .milliseconds(250)) }
                    for (session, (_, job)) in zip(sessions, floors) { session.newJobOnFloor(job) }
                    var overlap = false
                    while sessions.contains(where: { $0.state.phase != .idle && $0.isRunning }) || sessions.contains(where: { $0.state.phase == .idle }) {
                        if sessions.allSatisfy({ $0.isRunning }) { overlap = true }
                        if Date().timeIntervalSince(started) > 240 { break }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    for (session, (floor, _)) in zip(sessions, floors) {
                        let rooms = session.steps.map { "\($0.room):\($0.status)" }.joined(separator: ",")
                        print("PARALLEL \(floor.name) | phase \(session.state.phase) | rooms \(rooms) | files \(session.jobFiles.map { URL(fileURLWithPath: $0).lastPathComponent }) | cost \(session.state.tally.costUSD ?? 0)")
                    }
                    print(String(format: "PARALLEL overlap=%@ total %.1fs", overlap ? "yes" : "no", Date().timeIntervalSince(started)))
                    exit(0)
                }
                return
            }
            if let request = RunController.launchArgument("-route-test") {
                let floors: [CityStore.Floor] = [
                    .init(name: "Feature: login", hires: ["research", "build", "review"], budgetUSD: 1, lastRequest: "Add a sign-in page with email login"),
                    .init(name: "Security review", hires: ["research", "review"], budgetUSD: 2, lastRequest: "Review the auth code for vulnerabilities"),
                    .init(name: "Docs", hires: ["design", "build"], budgetUSD: 1, lastRequest: "Write the README introduction"),
                ]
                Task { @MainActor in
                    let started = Date()
                    let result = await ReceptionDesk.route(request: request, floors: floors)
                    let target = result.floorID.flatMap { id in floors.first { $0.id == id }?.name } ?? "NEW: \(result.newFloorName)"
                    print(String(format: "ROUTE %.1fs | %@ | %@", Date().timeIntervalSince(started), target, result.reason))
                    exit(0)
                }
                return
            }
            if arguments.contains("-city") || arguments.contains("-building") || arguments.contains("-title") {
                try renderCityOrBuilding(to: path, dark: dark, arguments: arguments)
                exit(0)
            }
            if arguments.contains("-hud-test") {
                let building = CityStore.Building(name: "theCity", path: RunController.launchArgument("-workspace") ?? "", style: 0)
                let controller = RunController(building: building, floor: .init(name: "Preview", hires: ["research", "build"], budgetUSD: 1))
                controller.request = "Add a sign-in page with email login and write tests for it"
                let badges = [("research", true, "Finds prior art and reads the docs"), ("build", true, "Writes and edits the code"), ("review", false, "Checks the work for bugs")]
                let hud = VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .top, spacing: 40) {
                        JobCard(controller: controller)
                        CounterCard(controller: controller)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(badges.enumerated()), id: \.offset) { index, badge in
                            CandidateBadge(candidate: Candidate(department: Department(name: badge.0, description: badge.2), hired: badge.1),
                                           order: badge.1 ? index : nil, colour: Palette.departments[index], moveUp: {}, moveDown: {}, toggle: {})
                                .frame(width: 200)
                        }
                    }
                }
                .padding(30)
                .background(Color(Palette.background))
                .foregroundStyle(Color(Palette.text))
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: hud)
                renderer.scale = 2
                if let image = renderer.cgImage { try OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: path)) }
                exit(0)
            }
            if arguments.contains("-face-test") {
                let renderer = ImageRenderer(content: FaceView(glyph: "?"))
                renderer.scale = 2
                if let image = renderer.cgImage { try OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: path)) }
                print("face written, image: \(renderer.cgImage.map { "\($0.width)x\($0.height)" } ?? "nil")")
                exit(0)
            }
            let scene = OfficeScene()
            let hired = ["research", "build", "review"].map { Department(name: $0, description: "") }
            let colours = ["research": Palette.departments[2], "build": Palette.departments[0], "review": Palette.departments[3]]
            scene.build(hired: hired, servers: [McpServer(name: "specification-website", status: "connected", source: "user")],
                        colour: { colours[$0] ?? Palette.muted }, dark: dark)
            scene.fit(CGSize(width: 1600, height: 1000))
            let question = PermissionRequest.preview(question: "Which tone should the greeting use?")
            scene.apply([.runStarted, .managerActive(false),
                         .handoff(toolUseID: "a", room: "build", description: nil), .roomStarted(toolUseID: "a", room: "build"),
                         .roomActivity(room: "build", toolName: "Write"), .roomCaption(room: "build", caption: "writing hello.txt"),
                         .roomStarted(toolUseID: "b", room: "research"), .roomActivity(room: "research", toolName: "Read"),
                         .roomCaption(room: "research", caption: "reading README.md"),
                         .skillLoaded(room: "research", skill: "office-house-style"),
                         .handRaised(question, room: "review")])
            if let count = RunController.launchArgument("-records").flatMap(Int.init) {
                let requests = ["Add a sign-in page", "Fix the flaky auth test", "Write the README intro", "Review the payment flow"]
                let jobs = (0..<count).map { index in
                    JobRecord(id: UUID(), date: .now.addingTimeInterval(Double(index - count) * 86_400), request: requests[index % requests.count],
                              workingDirectory: "", hires: [], costUSD: 0.12 + Double(index) * 0.05, budgetUSD: 1, duration: 60,
                              files: [], sessionID: nil, outcome: "completed")
                }
                scene.showRecords(jobs, fastest: 48)
            }
            if let room = RunController.launchArgument("-focus") { scene.focus(room: room) }
            for _ in 0..<(arguments.contains("-focus") ? 240 : 40) { scene.update(1.0 / 60) }
            if let seconds = RunController.launchArgument("-deliver").flatMap(Double.init) {
                for _ in 0..<(RunController.launchArgument("-jobs").flatMap(Int.init) ?? 1) {
                    scene.apply([.runStarted, .runEnded(.completed(summary: "Done", costUSD: 0.1))])
                    for _ in 0..<Int(seconds * 60) { scene.update(1.0 / 60) }
                }
            }
            var image = try OffscreenRenderer.render(root: scene.root, camera: scene.camera.entity, width: 1600, height: 1000,
                                                     environment: ModelLibrary.environment("studio"), exposure: dark ? 0.2 : 0.9,
                                                     background: Palette.resolved(Palette.background, dark: dark).cgColor)
            if let kind = RunController.launchArgument("-card"), let room = RunController.launchArgument("-focus"),
               let head = scene.screenPoint(of: room) {
                let workspace = CityStore.Building(name: "theCity", path: RunController.launchArgument("-workspace") ?? "", style: 0)
                let controller = RunController(building: workspace, floor: .init(name: "Preview", hires: ["research", "build", "review"], budgetUSD: 1))
                let request = kind == "approval"
                    ? PermissionRequest.preview(command: "npm test -- auth", rule: "npm test:*")
                    : PermissionRequest.preview(question: "Which tone should the greeting use?", header: "Tone", options: ["Friendly", "Formal", "Playful"])
                let card = DeskCard(pending: PendingRequest(request: request, room: room), colour: colours[room] ?? Palette.muted, controller: controller)
                    .environment(\.colorScheme, dark ? .dark : .light)
                image = try OffscreenRenderer.composite(image, overlay: card, leadingAt: CGPoint(x: head.x + 40, y: head.y))
            }
            try OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: path))
            print("preview written to \(path)")
            exit(0)
        } catch {
            print("preview failed: \(error)")
            exit(1)
        }
    }
}
