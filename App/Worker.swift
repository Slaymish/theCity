#if os(macOS)
import AppKit
#else
import UIKit
#endif
import OfficeCore
import RealityKit
import SwiftUI

/// One TV-head robot at a desk, animated procedurally each frame so states blend smoothly.
@MainActor
final class Worker {
    enum Mood: Equatable { case idle, working, question, approval, done, error }

    enum Expression: String, CaseIterable {
        case idle = "^ ^", blink = "‒ ‒", working = "– –", question = "?", approval = "!", done = "★", error = "× ×"
    }

    let root: Entity
    let colour: NSColor
    private(set) var mood: Mood = .idle
    private(set) var workedFor: Double = 0
    private let head: Entity?
    private let armL: Entity?
    private let armR: Entity?
    private let elbowL: Entity?
    private let elbowR: Entity?
    private let legL: Entity?
    private let legR: Entity?
    private let seat: SIMD3<Float>
    private let seatOrientation: simd_quatf
    private var route: [SIMD3<Float>] = []
    private var arrived: (() -> Void)?
    var isWalking: Bool { !route.isEmpty }
    var waving = false
    var stretching = false
    private var headBase: Float = 0
    private var bobTimer: Double = 0
    private var hopTimer: Double = 0
    static let bobTime: Double = 0.1
    static let hopTime: Double = 0.35
    static let walkSpeed: Float = 1.8
    private let face = ModelEntity()
    private let screen: Entity?
    private let captionPanel = ModelEntity()
    private var captionAspect: Float = 1.45
    private var captionTexture: TextureResource?
    private(set) var caption = ToolCaption.thinking
    private var time = Double.random(in: 0...10)
    private var armLAngle: Float = 0
    private var armRAngle: Float = 0
    private var elbowLAngle: Float = 0
    private var elbowRAngle: Float = 0
    private var headPitch: Float = 0
    private var nextBlink = Double.random(in: 2...5)
    private var shown: Expression?
    private var doneUntil: Double = 0
    private let glow = Entity()
    private let baseY: Float
    private let halfWidth: Float
    private static var faces: [String: UnlitMaterial] = [:]

    init(robot: Entity, screen: Entity?, colour: NSColor, room: String) {
        root = robot
        self.colour = colour
        self.screen = screen
        head = robot.descendant(named: "Head")
        armL = robot.descendant(named: "ArmL")
        armR = robot.descendant(named: "ArmR")
        elbowL = robot.descendant(named: "ElbowL")
        elbowR = robot.descendant(named: "ElbowR")
        legL = robot.descendant(named: "LegL")
        legR = robot.descendant(named: "LegR")
        seat = robot.position
        seatOrientation = robot.orientation
        headBase = head?.position.y ?? 0
        baseY = robot.position.y
        let bounds = robot.visualBounds(relativeTo: robot)
        let extents = bounds.extents
        halfWidth = max(extents.x, extents.z) / 2
        if room != "reception" {
            // A robot away from its desk sits outside its room's tile, so it needs its own hit area to be clickable.
            let hit = Entity()
            hit.name = "room:\(room)"
            hit.components.set(CollisionComponent(shapes: [.generateBox(size: extents).offsetBy(translation: bounds.center)]))
            hit.components.set(InputTargetComponent())
            robot.addChild(hit)
        }
        glow.position = [0, 1.25, 0.9]
        robot.addChild(glow)
        if let anchor = robot.descendant(named: "FaceAnchor") {
            face.model = ModelComponent(mesh: .generatePlane(width: 0.54, height: 0.37, cornerRadius: 0.04), materials: [])
            (head ?? anchor).addChild(face)
            face.setPosition(anchor.position(relativeTo: robot) + [0, 0, 0.008], relativeTo: robot)
            face.setOrientation(simd_quatf(angle: 0, axis: [0, 1, 0]), relativeTo: robot)
        }
        if let screen {
            let bounds = screen.visualBounds(relativeTo: screen)
            captionAspect = bounds.extents.x / max(bounds.extents.y, 0.001)
            captionPanel.model = ModelComponent(mesh: .generatePlane(width: bounds.extents.x, height: bounds.extents.y), materials: [])
            captionPanel.position = [bounds.center.x, bounds.center.y, bounds.max.z + 0.002]
            screen.addChild(captionPanel)
        }
        Self.attachAccessory(for: room, to: robot)
        ModelLibrary.tint(robot, parts: ["Knob", "AntennaTip", "Accent"], colour: colour)
        setScreen(on: false)
        show(.idle)
    }

    var headPosition: SIMD3<Float> {
        (head ?? root).position(relativeTo: nil) + [0, 0.4, 0]
    }

    var worldHalfWidth: Float { halfWidth * root.scale(relativeTo: nil).x }

    func setMood(_ mood: Mood) {
        guard mood != self.mood else { return }
        self.mood = mood
        if mood == .done {
            doneUntil = time + 3
            hopTimer = Self.hopTime
        }
        setScreen(on: mood == .working)
        show(expression(for: mood))
    }

    private func expression(for mood: Mood) -> Expression {
        switch mood {
        case .idle: .idle
        case .working: .working
        case .question: .question
        case .approval: .approval
        case .done: .done
        case .error: .error
        }
    }

    private func show(_ expression: Expression) {
        guard expression != shown else { return }
        if shown != nil, expression != .blink, shown != .blink { bobTimer = Self.bobTime }
        shown = expression
        guard let material = Self.material(for: expression) else { return }
        face.model?.materials = [material]
    }

    private static func material(for expression: Expression) -> UnlitMaterial? {
        let key = BrandStore.shared.current.id + expression.rawValue
        if let cached = faces[key] { return cached }
        let renderer = ImageRenderer(content: FaceView(glyph: expression.rawValue))
        renderer.scale = 2
        guard let image = renderer.cgImage, let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else { return nil }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        faces[key] = material
        return material
    }

    private static func attachAccessory(for room: String, to robot: Entity) {
        let name = room.lowercased()
        let (model, anchor): (String, String) = switch true {
        case name == "manager", name == "reception": ("tie", "ChestAnchor")
        case name.contains("research"): ("glasses", "FaceAnchor")
        case ["build", "engineer", "dev", "code"].contains(where: name.contains): ("hardhat", "HatAnchor")
        case ["review", "qa", "test", "secur", "audit"].contains(where: name.contains): ("magnifier", "HandAnchorR")
        case ["design", "ux", "ui", "brand"].contains(where: name.contains): ("beret", "HatAnchor")
        default: ("cap", "HatAnchor")
        }
        guard let point = robot.descendant(named: anchor) else { return }
        let item = ModelLibrary.entity(model)
        point.addChild(item)
        item.setOrientation(simd_quatf(angle: 0, axis: [0, 1, 0]), relativeTo: robot)
        item.setPosition(point.position(relativeTo: robot) + (model == "glasses" ? [0, 0.02, 0.05] : .zero), relativeTo: robot)
    }

    private func setScreen(on: Bool) {
        guard let screen else { return }
        let material = ModelLibrary.material(on ? Palette.screenOn : Palette.screenOff, roughness: 0.2, emissive: on ? 1.5 : 0)
        for part in [screen] + screen.descendants {
            guard var model = part.components[ModelComponent.self] else { continue }
            model.materials = model.materials.map { _ in material }
            part.components.set(model)
        }
        captionPanel.isEnabled = on
        if on {
            if captionPanel.model?.materials.isEmpty == true { drawCaption() }
            glow.components.set(PointLightComponent(color: Palette.screenOn, intensity: 2600, attenuationRadius: 2.2))
        } else {
            glow.components.remove(PointLightComponent.self)
        }
    }

    func setCaption(_ text: String) {
        guard text != caption else { return }
        caption = text
        drawCaption()
    }

    private func drawCaption() {
        let view = CaptionView(text: caption, aspect: CGFloat(captionAspect))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        captionTexture = LivePanel.show(image, on: captionPanel, reusing: captionTexture)
    }

    func resetClock() { workedFor = 0 }

    func walk(through points: [SIMD3<Float>], arrived: (() -> Void)? = nil) {
        route = points
        self.arrived = arrived
    }

    var seatPosition: SIMD3<Float> { seat }

    func sitDown() {
        route = []
        arrived = nil
        stretching = false
        root.position = seat
        root.orientation = seatOrientation
    }

    var standingHeight: Float { 0.08 }

    private func stepAlong(_ dt: Double) -> Bool {
        guard let next = route.first else { return false }
        var position = root.position
        position.y = standingHeight
        let offset = SIMD3(next.x - position.x, 0, next.z - position.z)
        let distance = simd_length(offset)
        let step = Self.walkSpeed * Float(dt)
        if distance <= step {
            position.x = next.x
            position.z = next.z
            route.removeFirst()
        } else {
            position += offset / distance * step
            let heading = simd_quatf(angle: atan2(offset.x, offset.z), axis: [0, 1, 0])
            root.orientation = simd_slerp(root.orientation, heading, Float(min(dt * 12, 1)))
        }
        root.position = position
        if route.isEmpty {
            if simd_distance(SIMD2(position.x, position.z), SIMD2(seat.x, seat.z)) < 0.01 {
                root.position = seat
                root.orientation = seatOrientation
            }
            let done = arrived
            arrived = nil
            done?()
        }
        return true
    }

    func update(_ dt: Double, reduceMotion: Bool) {
        time += dt
        if mood == .working || mood == .question || mood == .approval { workedFor += dt }
        let t = Float(time)
        let still = reduceMotion
        let walking = stepAlong(dt)
        let standing = walking || root.position.y < baseY - 0.01
        if !walking { root.position.y = (standing ? standingHeight : baseY) + (still ? 0 : sin(t * 2.2) * 0.012) }
        let stride: Float = walking && !still ? sin(t * 9) * 0.5 : 0
        Self.bend(legL, stride)
        Self.bend(legR, -stride)
        if mood == .done && time > doneUntil { setMood(.idle) }

        var (targetL, targetR, targetPitch): (Float, Float, Float) = switch mood {
        case .idle, .done, .error: (0.05, 0.05, still ? 0 : sin(t * 0.5) * 0.06)
        case .working: (-0.7 + (still ? 0 : sin(t * 17) * 0.09), -0.7 + (still ? 0 : sin(t * 17 + 1.7) * 0.09), 0.18)
        case .question, .approval: (0.05, -2.75 + (still ? 0 : sin(t * 7) * 0.18), -0.08)
        }
        var (targetElbowL, targetElbowR): (Float, Float) = switch mood {
        case .idle, .done, .error: (0, 0)
        case .working: (-0.9, -0.9)
        case .question, .approval: (0, -0.3)
        }
        if standing { (targetL, targetR, targetPitch, targetElbowL, targetElbowR) = (-1.0, -1.0, 0, -0.6, -0.6) }
        if waving { (targetL, targetR, targetElbowL, targetElbowR) = (0.05, -2.75 + (still ? 0 : sin(t * 7) * 0.18), 0, -0.3) }
        if stretching { (targetL, targetR, targetElbowL, targetElbowR) = (-2.75, -2.75, -0.3, -0.3) }
        bobTimer = max(bobTimer - dt, 0)
        hopTimer = max(hopTimer - dt, 0)
        if !still {
            let bob = headBase - Float(sin(.pi * bobTimer / Self.bobTime)) * 0.03
            if let head, head.position.y != bob { head.position.y = bob }
            if hopTimer > 0, !walking { root.position.y += Float(sin(.pi * (1 - hopTimer / Self.hopTime))) * 0.25 }
        }
        let blend = Float(1 - exp(-dt * 10))
        armLAngle += (targetL - armLAngle) * blend
        armRAngle += (targetR - armRAngle) * blend
        elbowLAngle += (targetElbowL - elbowLAngle) * blend
        elbowRAngle += (targetElbowR - elbowRAngle) * blend
        headPitch += (targetPitch - headPitch) * blend
        Self.bend(armL, armLAngle)
        Self.bend(armR, armRAngle)
        Self.bend(elbowL, elbowLAngle)
        Self.bend(elbowR, elbowRAngle)
        let turn: Float = mood == .idle && !still ? sin(t * 0.3) * 0.35 : 0
        Self.pose(head, simd_quatf(angle: headPitch, axis: [1, 0, 0]) * simd_quatf(angle: turn, axis: [0, 1, 0]))

        if mood == .idle && !still {
            nextBlink -= dt
            show(nextBlink < 0.14 && nextBlink > 0 ? .blink : .idle)
            if nextBlink <= 0 { nextBlink = Double.random(in: 2.5...6) }
        }
    }

    private static func bend(_ joint: Entity?, _ angle: Float) {
        pose(joint, simd_quatf(angle: angle, axis: [1, 0, 0]))
    }

    /// Joints mostly hold still between moods, and every robot on every storey runs this each frame.
    private static func pose(_ joint: Entity?, _ rotation: simd_quatf) {
        guard let joint, joint.orientation != rotation else { return }
        joint.orientation = rotation
    }
}

struct FaceView: View {
    let glyph: String

    var body: some View {
        Text(glyph)
            .font(Typography.ui(glyph.count > 1 ? 92 : 132, weight: 700))
            .foregroundStyle(Color(Palette.screenOn))
            .frame(width: 290, height: 200)
            .background(Color(Palette.screenOff))
    }
}

struct CaptionView: View {
    let text: String
    let aspect: CGFloat

    var body: some View {
        Text(text)
            .font(Typography.ui(92, weight: 700))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.1)
            .foregroundStyle(Color(Palette.screenOn))
            .padding(24)
            .frame(width: 200 * aspect, height: 200)
            .background(Color(Palette.screenOff))
    }
}
