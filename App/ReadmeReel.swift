import AppKit
import OfficeCore
import RealityKit
import SwiftUI

/// `TheCity -render-reel city|office <dir> [-theme light] [-fps n]`: scripted scenes rendered frame by frame for the README's GIFs.
@MainActor
enum ReadmeReel {
    typealias Cue = (at: Double, run: () -> Void)

    static let size = CGSize(width: 1600, height: 1000)

    static func run(_ name: String, to directory: String) {
        do {
            let dark = RunController.launchArgument("-theme") != "light"
            let fps = RunController.launchArgument("-fps").flatMap(Double.init) ?? 30
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            switch name {
            case "city": try city(dark: dark, fps: fps, to: folder)
            case "office": try office(dark: dark, fps: fps, to: folder)
            default: throw CocoaError(.featureUnsupported)
            }
            print("reel written to \(directory)")
            exit(0)
        } catch {
            print("reel failed: \(error)")
            exit(1)
        }
    }

    private static func record(seconds: Double, fps: Double, cues: [Cue], recorder: FrameRecorder, to folder: URL,
                               step: (Double) -> Void, camera: () -> Entity, overlay: (CGImage) throws -> CGImage = { $0 }) throws {
        var pending = cues.sorted { $0.at < $1.at }
        let dt = 1 / fps
        try recorder.warmUp()
        for frame in 0..<Int(seconds * fps) {
            let time = Double(frame) * dt
            while let cue = pending.first, cue.at <= time {
                pending.removeFirst()
                cue.run()
            }
            for _ in 0..<2 { step(dt / 2) }
            let image = try overlay(try recorder.capture(camera: camera()))
            try OffscreenRenderer.writePNG(image, to: folder.appendingPathComponent(String(format: "frame-%05d.png", frame)))
        }
    }

    private static func background(_ dark: Bool) -> CGColor { Palette.resolved(Palette.background, dark: dark).cgColor }

    private static func work(_ scene: OfficeScene, rooms: [(String, String, String)], prefix: String) {
        scene.apply([.runStarted, .managerActive(true)])
        for (index, (room, tool, caption)) in rooms.enumerated() {
            let id = "\(prefix)\(index)"
            scene.apply([.handoff(toolUseID: id, room: room, description: nil), .roomStarted(toolUseID: id, room: room),
                         .roomActivity(room: room, toolName: tool), .roomCaption(room: room, caption: caption)])
        }
    }

    // MARK: City: break ground, rise, walk in, visit a floor

    private static func city(dark: Bool, fps: Double, to folder: URL) throws {
        let workspace = RunController.launchArgument("-workspace") ?? FileManager.default.currentDirectoryPath
        var buildings = ["api", "web-app", "docs-site", "infra", "theCity"].enumerated().map { index, name in
            CityStore.Building(name: name, path: workspace, style: index * 3 % 8)
        }
        buildings[4].floors = [
            .init(name: "Feature: login", hires: ["research", "build", "review"], budgetUSD: 1),
            .init(name: "Security review", hires: ["research", "review"], budgetUSD: 2),
            .init(name: "Docs", hires: ["design", "build"], budgetUSD: 1),
        ]
        let building = buildings[4]
        let sessions = building.floors.map { floor in (floor.id, RunController(building: building, floor: floor)) }

        let world = World()
        world.city.titleMode = true
        world.city.build(Array(buildings.prefix(4)), dark: dark)
        world.fit(size)

        let recorder = try FrameRecorder(root: world.root, camera: world.camera.entity, width: Int(size.width), height: Int(size.height),
                                         environment: ModelLibrary.environment("sky"), exposure: dark ? -0.5 : 0.6, background: background(dark))
        let cues: [Cue] = [
            (2.0, {
                world.city.titleMode = false
                world.city.build(buildings, dark: dark)
                world.city.riseBuilding(building.id)
                world.city.flyTowards(building.id)
            }),
            (3.6, {
                world.building.show(building, sessions: sessions, dark: dark)
                world.enter(building.id, animated: true)
                work(sessions[0].1.scene, rooms: [("research", "Read", "reading README.md"), ("build", "Write", "writing Login.swift")], prefix: "f0-")
                work(sessions[1].1.scene, rooms: [("review", "Grep", "searching for tokens")], prefix: "f1-")
            }),
            (6.2, {
                world.building.enter(floor: sessions[2].0)
                work(sessions[2].1.scene, rooms: [("design", "Read", "reading the style guide"), ("build", "Edit", "editing README.md")], prefix: "f2-")
            }),
            (8.4, {
                sessions[2].1.scene.apply([.handRaised(PermissionRequest.preview(question: "Which tone should the intro use?"), room: "design")])
            }),
        ]
        try record(seconds: 10.5, fps: fps, cues: cues, recorder: recorder, to: folder,
                   step: world.update, camera: { world.camera.entity })
    }

    // MARK: Office: hand-offs, tools, an approval at the desk, delivery

    private static func office(dark: Bool, fps: Double, to folder: URL) throws {
        let scene = OfficeScene()
        let hired = ["research", "build", "review"].map { Department(name: $0, description: "") }
        let colours = ["research": Palette.departments[2], "build": Palette.departments[0], "review": Palette.departments[3]]
        scene.build(hired: hired, servers: [McpServer(name: "specification-website", status: "connected", source: "user")],
                    colour: { colours[$0] ?? Palette.muted }, dark: dark)
        scene.fit(size)
        scene.camera.overview.distance *= 0.72
        scene.camera.reset(to: scene.camera.overview, animated: false)

        let workspace = CityStore.Building(name: "theCity", path: RunController.launchArgument("-workspace") ?? "", style: 0)
        let controller = RunController(building: workspace, floor: .init(name: "Feature: login", hires: ["research", "build", "review"], budgetUSD: 1))
        // ImageRenderer draws the link-style "switch to Auto" button as a placeholder, so hide it.
        controller.setPermissionMode(.auto)
        let approval = PermissionRequest.preview(command: "npm test -- auth", rule: "npm test:*")
        let card = ImageRenderer(content: DeskCard(pending: PendingRequest(request: approval, room: "build"), colour: colours["build"]!, controller: controller)
            .environment(\.colorScheme, dark ? .dark : .light))
        card.scale = 1.5
        guard let cardImage = card.cgImage else { throw CocoaError(.fileWriteUnknown) }
        var showCard = false

        let recorder = try FrameRecorder(root: scene.root, camera: scene.camera.entity, width: Int(size.width), height: Int(size.height),
                                         environment: ModelLibrary.environment("studio"), exposure: dark ? 0.2 : 0.9, background: background(dark))
        let cues: [Cue] = [
            (0.3, { scene.apply([.runStarted, .managerActive(true)]) }),
            (0.6, { scene.apply([.handoff(toolUseID: "a", room: "research", description: nil)]) }),
            (1.1, { scene.apply([.handoff(toolUseID: "b", room: "build", description: nil)]) }),
            (1.6, { scene.apply([.handoff(toolUseID: "c", room: "review", description: nil)]) }),
            (1.5, { scene.apply([.roomStarted(toolUseID: "a", room: "research"), .roomActivity(room: "research", toolName: "Read"),
                                 .roomCaption(room: "research", caption: "reading README.md")]) }),
            (2.0, { scene.apply([.roomStarted(toolUseID: "b", room: "build"), .roomActivity(room: "build", toolName: "Write"),
                                 .roomCaption(room: "build", caption: "writing Login.swift")]) }),
            (2.4, { scene.apply([.skillLoaded(room: "research", skill: "office-house-style")]) }),
            (2.5, { scene.apply([.roomStarted(toolUseID: "c", room: "review"), .roomActivity(room: "review", toolName: "Grep"),
                                 .roomCaption(room: "review", caption: "searching for TODO")]) }),
            (2.8, { scene.apply([.serviceCall(callID: "s", room: "research", server: "specification-website", active: true)]) }),
            (3.9, { scene.apply([.serviceCall(callID: "s", room: "research", server: "specification-website", active: false)]) }),
            (4.2, { scene.apply([.handRaised(approval, room: "build")]) }),
            (4.8, { scene.focus(room: "build") }),
            (5.6, { showCard = true }),
            (7.8, {
                showCard = false
                scene.apply([.handLowered(requestID: approval.requestID, room: "build"), .roomActivity(room: "build", toolName: "Bash"),
                             .roomCaption(room: "build", caption: "running npm test")])
                scene.showOverview()
            }),
            (8.6, { scene.apply([.roomFinished(toolUseID: "a", room: "research", outcome: .completed), .handback(toolUseID: "a", room: "research", isError: false)]) }),
            (9.0, { scene.apply([.roomFinished(toolUseID: "c", room: "review", outcome: .completed), .handback(toolUseID: "c", room: "review", isError: false)]) }),
            (9.6, { scene.apply([.roomFinished(toolUseID: "b", room: "build", outcome: .completed), .handback(toolUseID: "b", room: "build", isError: false)]) }),
            (10.8, { scene.apply([.runEnded(.completed(summary: "Done", costUSD: 0.42))]) }),
        ]
        try record(seconds: 13.5, fps: fps, cues: cues, recorder: recorder, to: folder,
                   step: scene.update, camera: { scene.camera.entity },
                   overlay: { image in
                       guard showCard, let head = scene.screenPoint(of: "build") else { return image }
                       return try OffscreenRenderer.composite(image, card: cardImage, leadingAt: CGPoint(x: head.x + 40, y: head.y))
                   })
    }
}
