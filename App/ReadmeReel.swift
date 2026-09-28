import AppKit
import OfficeCore
import RealityKit
import SwiftUI

/// `TheCity -render-reel showcase|city|office <dir> [-theme light] [-fps n]`: scripted scenes rendered frame by frame for the README's GIFs.
@MainActor
enum ReadmeReel {
    typealias Cue = (at: Double, run: () -> Void)

    static let size = CGSize(width: 1600, height: 1000)
    /// The window the HUD is laid out in; frames are rendered at `size`, so the HUD is drawn at `size.width / points.width`.
    static let points = CGSize(width: 1000, height: 625)

    private static var time = 0.0

    static func run(_ name: String, to directory: String) {
        let epoch = Date.now
        RunController.now = { epoch.addingTimeInterval(time) }
        do {
            let dark = RunController.launchArgument("-theme") != "light"
            let fps = RunController.launchArgument("-fps").flatMap(Double.init) ?? 30
            guard fps.isFinite, fps > 0, fps <= 120 else { throw CocoaError(.validationNumberTooLarge) }
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            switch name {
            case "city": try city(dark: dark, fps: fps, to: folder)
            case "office": try office(dark: dark, fps: fps, to: folder)
            case "showcase": try showcase(dark: dark, fps: fps, to: folder)
            default: throw CocoaError(.featureUnsupported)
            }
            print("reel written to \(directory)")
            exit(0)
        } catch {
            print("reel failed: \(error)")
            exit(1)
        }
    }

    private static func record(seconds: Double, fps: Double, cues: [Cue], recorder: FrameRecorder, to folder: URL, loopDissolve: Double = 0,
                               step: (Double) -> Void, camera: () -> Entity, overlay: (CGImage, Double) throws -> CGImage = { image, _ in image }) throws {
        var pending = cues.sorted { $0.at < $1.at }
        let dt = 1 / fps
        var first: CGImage?
        try recorder.warmUp()
        for frame in 0..<Int(seconds * fps) {
            time = Double(frame) * dt
            while let cue = pending.first, cue.at <= time {
                pending.removeFirst()
                cue.run()
            }
            // Camera flights clamp long steps. Keep low-rate contact sheets at the same speed as final reels.
            let steps = max(Int(ceil(dt * 60)), 2)
            for _ in 0..<steps { step(dt / Double(steps)) }
            var image = try overlay(try recorder.capture(camera: camera()), time)
            if first == nil { first = image }
            if loopDissolve > dt {
                image = try layer(image, [(first, fade(time, in: seconds - loopDissolve, loopDissolve - dt))])
            }
            try OffscreenRenderer.writePNG(image, to: folder.appendingPathComponent(String(format: "frame-%05d.png", frame)))
        }
    }

    private static func background(_ dark: Bool) -> CGColor { DayCycle.now.sky(dark: dark).cgColor }

    // MARK: HUD

    private static func hud(_ view: some View, dark: Bool) -> CGImage? {
        let renderer = ImageRenderer(content: view
            .frame(width: points.width, height: points.height)
            .foregroundStyle(Color(Palette.text))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.rendersOffscreen, true))
        renderer.scale = size.width / points.width
        return renderer.cgImage
    }

    private static func layer(_ base: CGImage, _ layers: [(CGImage?, Double)]) throws -> CGImage {
        guard layers.contains(where: { $0.0 != nil && $0.1 > 0 }) else { return base }
        guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        let frame = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        context.draw(base, in: frame)
        for case let (image?, alpha) in layers where alpha > 0 {
            context.setAlpha(alpha)
            context.draw(image, in: frame)
        }
        guard let result = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return result
    }

    private static func fade(_ time: Double, in start: Double, _ duration: Double = 0.3) -> Double {
        let t = min(max((time - start) / duration, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func window(_ time: Double, _ from: Double, _ to: Double) -> Double {
        fade(time, in: from) * (1 - fade(time, in: to))
    }

    /// A copy of the sample workspace's departments under the project's name, so file rows and addresses read like a real project.
    private static func project(named name: String, beside folder: URL) throws -> URL {
        let sample = URL(fileURLWithPath: RunController.launchArgument("-workspace") ?? FileManager.default.currentDirectoryPath)
        let project = folder.deletingLastPathComponent().appendingPathComponent("reel-\(folder.lastPathComponent)").appendingPathComponent(name)
        try? FileManager.default.removeItem(at: project)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sample.appendingPathComponent(".claude"), to: project.appendingPathComponent(".claude"))
        return project.standardizedFileURL
    }

    private static func plan(session: Double, week: Double) {
        let now = Date.now.timeIntervalSince1970
        let line = Wire.json(["type": "rate_limit_event", "rate_limit_info": [
            "status": "allowed", "rateLimitType": "five_hour", "isUsingOverage": false,
            "unifiedWindows": ["five_hour": ["utilization": session, "resetsAt": now + 3 * 3600],
                               "seven_day": ["utilization": week, "resetsAt": now + 4 * 86_400]],
        ] as [String: Any]])
        guard case .event(.rateLimit(let limit)) = StreamParser.parse(line, index: 0).parsed else { return }
        UsageStore.shared.record(limit, configDirectory: Preferences.shared.configDirectory, persist: false)
    }

    // MARK: City: break ground, rise, walk in, ask reception, go up to the floor

    private static func city(dark: Bool, fps: Double, to folder: URL) throws {
        let root = try project(named: "theCity", beside: folder)
        plan(session: 0.34, week: 0.21)
        var buildings = ["api", "web-app", "docs-site", "infra", "theCity"].enumerated().map { index, name in
            CityStore.Building(name: name, path: root.path, style: index * 3 % 8)
        }
        buildings[4].floors = [
            .init(name: "Login", hires: ["research", "build", "review"], budgetUSD: 1, lastRequest: "Add a sign-in page with email login"),
            .init(name: "Audit", hires: ["research", "review"], budgetUSD: 2),
            .init(name: "Docs", hires: ["design", "build"], budgetUSD: 1),
        ]
        let building = buildings[4]
        let sessions = building.floors.map { floor in (floor.id, RunController(building: building, floor: floor)) }
        for (index, (_, session)) in sessions.enumerated() {
            session.pendingFloorName = building.floors[index].name
            session.buildScene(dark: dark)
        }
        let login = sessions[0].1
        let audit = Wire(cwd: root.path)
        sessions[1].1.request = "Audit the auth code"
        sessions[1].1.beginScript(servers: [], dark: nil)
        ([audit.initLine()] + audit.assign("review", "Audit the auth code")
            + audit.use(.init(room: "review", tool: "Grep", input: ["pattern": "password"], caption: "Searching for password")))
            .forEach(sessions[1].1.feed)
        let request = "Add a password reset flow"
        let suggestion = RoutingSuggestion(floorID: building.floors[0].id, newFloorName: "Password reset",
                                           reason: "Login already builds the sign-in flow. Its last job: “Add a sign-in page with email login”.")

        let world = World()
        world.city.titleMode = true
        world.city.build(Array(buildings.prefix(4)), dark: dark)
        world.fit(points)

        var typed = ""
        var suggested: RoutingSuggestion?
        var entered: Double?
        var onFloor: Double?
        let script = Wire(cwd: root.path)
        let recorder = try FrameRecorder(root: world.root, camera: world.camera.entity, width: Int(size.width), height: Int(size.height),
                                         environment: ModelLibrary.environment("sky"), exposure: CityScene.skyExposure(.now), background: background(dark))
        var cues: [Cue] = [
            (2.0, {
                world.city.titleMode = false
                world.city.build(buildings, dark: dark)
                world.city.riseBuilding(building.id)
                world.city.flyTowards(building.id)
            }),
            (3.0, {
                world.building.show(building, sessions: sessions, dark: dark)
                world.enter(building.id, animated: true)
                entered = 3.0
            }),
            (5.8, {
                suggested = suggestion
                world.building.receptionist(thinking: false, pointingAt: suggestion.floorID, scaffold: false)
            }),
            (7.2, {
                world.building.receptionist(thinking: false, pointingAt: nil, scaffold: false)
                world.building.enter(floor: sessions[0].0)
                onFloor = 7.2
                login.request = request
                login.beginScript(servers: [], dark: nil)
                ([script.initLine()] + script.assign("research", "Find how sign-in works") + script.assign("build", "Build the reset flow"))
                    .forEach(login.feed)
            }),
            (7.9, { script.use(.init(room: "research", tool: "Read", input: ["file_path": root.appendingPathComponent("Sources/LoginView.swift").path], caption: "Reading LoginView.swift")).forEach(login.feed) }),
            (8.5, { script.use(.init(room: "build", tool: "Write", input: ["file_path": root.appendingPathComponent("Sources/PasswordReset.swift").path, "content": ""], caption: "Writing PasswordReset.swift")).forEach(login.feed) }),
        ]
        let letters = Array(request)
        for index in letters.indices {
            cues.append((4.2 + Double(index) * 0.045, { typed = String(letters[...index]) }))
        }

        let title = hud(TitleHUD(city: .shared), dark: dark)
        try record(seconds: 10.5, fps: fps, cues: cues, recorder: recorder, to: folder,
                   step: world.update, camera: { world.camera.entity },
                   overlay: { image, time in
                       var layers: [(CGImage?, Double)] = [(title, 1 - fade(time, in: 1.7))]
                       if let entered, onFloor == nil || time < onFloor! + 0.3 {
                           let composer = ReceptionComposer(city: .shared, building: building, scene: world.building, text: typed, suggestion: suggested)
                           let alpha = fade(time, in: entered + 0.6) * (1 - fade(time, in: onFloor ?? .infinity, 0.25))
                           layers.append((hud(BuildingHUD(city: .shared, building: building, scene: world.building, composer: composer), dark: dark), alpha))
                       }
                       if let onFloor, let floor = world.building.scene(for: sessions[0].0) {
                           layers.append((hud(OfficeOverlay(controller: login, scene: floor, onBack: {}, onClose: {}), dark: dark), fade(time, in: onFloor + 0.5)))
                       }
                       return try layer(image, layers)
                   })
    }

    // MARK: Office: hand-offs, tools, an approval at the desk, delivery

    private static func office(dark: Bool, fps: Double, to folder: URL) throws {
        let root = try project(named: "theCity", beside: folder)
        plan(session: 0.34, week: 0.21)
        let building = CityStore.Building(name: "theCity", path: root.path, style: 0)
        let controller = RunController(building: building, floor: .init(name: "Feature: login", hires: ["research", "build", "review"], budgetUSD: 1))
        controller.pendingFloorName = "Feature: login"
        controller.request = "Add a sign-in page with email login"
        // ImageRenderer draws the link-style "switch to Auto" button as a placeholder, so hide it.
        controller.setPermissionMode(.auto)
        let servers = [McpServer(name: "specification-website", status: "connected", source: "user")]
        controller.beginScript(servers: servers, dark: dark)
        let scene = controller.scene
        scene.fit(points)
        scene.camera.overview.distance *= 0.92
        scene.camera.reset(to: scene.camera.overview, animated: false)

        let script = Wire(cwd: root.path)
        let view = root.appendingPathComponent("Sources/LoginView.swift")
        var cardShown: Double?
        var cardHidden: Double?
        var delivered: Double?
        var before: CGImage?
        let recorder = try FrameRecorder(root: scene.root, camera: scene.camera.entity, width: Int(size.width), height: Int(size.height),
                                         environment: ModelLibrary.environment("studio"), exposure: OfficeScene.studioExposure(.now), background: background(dark))
        let cues: [Cue] = [
            (0.0, { controller.feed(script.initLine()) }),
            (0.4, { script.assign("research", "Find how sign-in should look").forEach(controller.feed) }),
            (0.8, { script.assign("build", "Build the sign-in page").forEach(controller.feed) }),
            (1.2, { script.assign("review", "Check the auth code").forEach(controller.feed) }),
            (1.3, { script.use(.init(room: "research", tool: "Read", input: ["file_path": root.appendingPathComponent("README.md").path], caption: "Reading README.md")).forEach(controller.feed) }),
            (1.7, { script.use(.init(room: "build", tool: "Write", input: ["file_path": view.path, "content": ""], caption: "Writing LoginView.swift")).forEach(controller.feed) }),
            (2.1, { script.use(.init(room: "review", tool: "Grep", input: ["pattern": "TODO"], caption: "Searching for TODO")).forEach(controller.feed) }),
            (2.4, { script.use(.init(room: "research", tool: "Skill", input: ["skill": "office-house-style"], caption: "Loading office-house-style")).forEach(controller.feed) }),
            (2.7, { controller.feed(script.finish("research")) }),
            (3.0, { script.use(.init(room: "research", tool: "mcp__specification-website__search", input: ["query": "sign-in form"], caption: "Searching the specification")).forEach(controller.feed) }),
            (3.8, { controller.feed(script.approval(room: "build", command: "npm test -- auth", rule: "npm test:*")) }),
            (4.0, { scene.focus(room: "build") }),
            (4.2, { controller.feed(script.finish("research")) }),
            (4.7, { cardShown = 4.7 }),
            (7.1, {
                cardHidden = 7.1
                if let pending = controller.state.pendingRequests.first { controller.allow(pending) }
                script.use(.init(room: "build", tool: "Bash", input: ["command": "npm test -- auth"], caption: "Running npm test")).forEach(controller.feed)
            }),
            (7.4, { scene.showOverview() }),
            (7.7, { script.handBack("research").forEach(controller.feed) }),
            (8.1, {
                controller.feed(script.finish("review"))
                script.handBack("review").forEach(controller.feed)
            }),
            (8.7, {
                try? FileManager.default.createDirectory(at: view.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "struct LoginView {}\n".write(to: view, atomically: true, encoding: .utf8)
                controller.feed(script.finish("build", tool: "Write"))
                controller.feed(script.finish("build"))
                script.handBack("build").forEach(controller.feed)
            }),
            (9.3, {
                controller.feed(script.done(summary: "Added a sign-in page with email login in `LoginView.swift`. The auth tests pass.", cost: 0.42))
                controller.endScript()
                delivered = 9.3
            }),
        ]
        try record(seconds: 13, fps: fps, cues: cues, recorder: recorder, to: folder,
                   step: scene.update, camera: { scene.camera.entity },
                   overlay: { image, time in
                       let base = hud(OfficeOverlay(controller: controller, scene: scene, onBack: {}, onClose: {}, showsDeskRequests: false), dark: dark)
                       if delivered == nil { before = base }
                       let arriving = delivered.map { fade(time, in: $0) } ?? 1
                       var layers: [(CGImage?, Double)] = arriving < 1 ? [(before, 1 - arriving), (base, arriving)] : [(base, 1)]
                       if let cardShown {
                           let alpha = fade(time, in: cardShown, 0.25) * (1 - fade(time, in: cardHidden ?? .infinity, 0.2))
                           if alpha > 0 { layers.append((hud(DeskRequestLayer(controller: controller, scene: scene), dark: dark), alpha)) }
                       }
                       return try layer(image, layers)
                   })
    }

    // MARK: Showcase: a warm miniature neighbourhood, with a gentle looping camera move

    private static func showcase(dark: Bool, fps: Double, to folder: URL) throws {
        let sample = URL(fileURLWithPath: RunController.launchArgument("-workspace") ?? FileManager.default.currentDirectoryPath)
        var buildings = ["theCity", "api", "web-app", "docs-site", "infra"].enumerated().map { index, name in
            CityStore.Building(name: name, path: sample.path, style: [1, 0, 2, 1, 2][index])
        }
        buildings[0].floors = [
            .init(name: "Login", hires: ["research", "build", "review"], budgetUSD: 1),
            .init(name: "Audit", hires: ["research", "review"], budgetUSD: 2),
            .init(name: "Docs", hires: ["design", "build"], budgetUSD: 1),
        ]
        buildings[1].floors = [.init(name: "Landing page", hires: ["research", "build"], budgetUSD: 1)]
        for index in 2..<buildings.count {
            buildings[index].floors = (0..<(index == 3 ? 1 : 2)).map { floor in
                .init(name: "Studio \(floor + 1)", hires: ["build"], budgetUSD: 1)
            }
        }
        _ = PreviewStage.seedStatus(buildings, workspace: sample, dark: dark)
        let epoch = Date.now
        RunController.now = { epoch.addingTimeInterval(time) }

        let city = CityScene()
        city.build(buildings, dark: dark)
        city.fit(points)
        city.refresh()
        city.setLabelsVisible(false)
        for _ in 0..<120 { city.update(1.0 / 60) }
        let cycle = DayCycle.now
        var pose = city.camera.overview
        pose.target = [-0.7, 0.55, -0.5]
        pose.distance *= 0.37
        pose.pitch = 0.48
        pose.yaw -= 0.18
        let start = pose
        city.camera.reset(to: pose, animated: false)
        let recorder = try FrameRecorder(root: city.root, camera: city.camera.entity, width: Int(size.width), height: Int(size.height),
                                         environment: ModelLibrary.environment("sky"), exposure: CityScene.skyExposure(cycle),
                                         background: cycle.sky(dark: dark).cgColor)
        try record(seconds: 8, fps: fps, cues: [], recorder: recorder, to: folder, loopDissolve: 0.6,
                   step: { dt in
                       city.update(dt)
                       let move = Float(fade(time, in: 0.4, 1.5) * (1 - fade(time, in: 5.3, 1.5)))
                       pose.yaw = start.yaw + move * 0.12
                       pose.distance = start.distance * (1 - move * 0.035)
                       city.camera.reset(to: pose, animated: false)
                   },
                   camera: { city.camera.entity })
    }
}

/// Stream-JSON lines shaped like the CLI's own, so a reel runs through the same reducer as a real job.
@MainActor
private final class Wire {
    struct Use {
        var room: String
        var tool: String
        var input: [String: Any]
        var caption: String
    }

    let cwd: String
    let session = "reel-session"
    private var agents: [String: String] = [:]
    private var tasks: [String: String] = [:]
    private var tools: [String: [String: String]] = [:]
    private var count = 0

    init(cwd: String) { self.cwd = cwd }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    private func id(_ prefix: String) -> String {
        count += 1
        return "\(prefix)_reel\(count)"
    }

    private func usage(_ output: Int) -> [String: Any] {
        ["input_tokens": 1_800, "cache_read_input_tokens": 6_400, "output_tokens": output]
    }

    func initLine() -> String {
        Self.json(["type": "system", "subtype": "init", "cwd": cwd, "session_id": session, "model": "claude-sonnet-5",
                   "mcp_servers": [["name": "specification-website", "status": "connected", "source": "user"]]])
    }

    func assign(_ room: String, _ description: String) -> [String] {
        let toolUse = id("toolu"), task = id("task")
        agents[room] = toolUse
        tasks[room] = task
        return [
            Self.json(["type": "assistant", "parent_tool_use_id": NSNull(), "session_id": session,
                       "message": ["id": id("msg"), "model": "claude-sonnet-5", "usage": usage(240), "content": [
                           ["type": "tool_use", "id": toolUse, "name": "Agent",
                            "input": ["description": description, "subagent_type": room, "prompt": description]],
                       ]] as [String: Any]]),
            Self.json(["type": "system", "subtype": "task_started", "task_id": task, "tool_use_id": toolUse,
                       "description": description, "subagent_type": room, "session_id": session]),
        ]
    }

    func use(_ use: Use) -> [String] {
        guard let parent = agents[use.room] else { return [] }
        let toolUse = id("toolu")
        tools[use.room, default: [:]][use.tool] = toolUse
        tools[use.room, default: [:]]["last"] = toolUse
        return [
            Self.json(["type": "system", "subtype": "task_progress", "task_id": tasks[use.room] ?? "", "tool_use_id": parent, "description": use.caption,
                       "subagent_type": use.room, "last_tool_name": use.tool, "session_id": session]),
            Self.json(["type": "assistant", "parent_tool_use_id": parent, "session_id": session,
                       "message": ["id": id("msg"), "model": "claude-haiku-4-5-20251001", "usage": usage(420), "content": [
                           ["type": "tool_use", "id": toolUse, "name": use.tool, "input": use.input],
                       ]] as [String: Any]]),
        ]
    }

    func finish(_ room: String, tool: String = "last") -> String {
        let toolUse = tools[room]?[tool] ?? ""
        return Self.json(["type": "user", "parent_tool_use_id": agents[room] ?? NSNull(), "session_id": session,
                          "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolUse, "content": "ok"]]] as [String: Any]])
    }

    func handBack(_ room: String) -> [String] {
        guard let toolUse = agents[room] else { return [] }
        return [Self.json(["type": "user", "parent_tool_use_id": NSNull(), "session_id": session,
                           "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolUse, "content": [["type": "text", "text": "Done."]]]]] as [String: Any]])]
    }

    func approval(room: String, command: String, rule: String) -> String {
        Self.json(["type": "control_request", "request_id": id("req"), "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "display_name": "Bash", "input": ["command": command],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": rule]], "behavior": "allow", "destination": "localSettings"]],
            "tool_use_id": id("toolu"), "agent_id": tasks[room] ?? "",
        ] as [String: Any]])
    }

    func done(summary: String, cost: Double) -> String {
        Self.json(["type": "result", "subtype": "success", "is_error": false, "result": summary, "terminal_reason": "completed",
                   "total_cost_usd": cost, "duration_ms": 94_000, "num_turns": 4, "session_id": session])
    }
}
