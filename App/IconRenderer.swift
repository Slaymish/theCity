import AppKit
import RealityKit

/// Renders the app icon from the city's own models: `TheCity -render-icon <file.png>`.
@MainActor
enum IconRenderer {
    static func run(to path: String) {
        do {
            try write(render(size: 1024, fullBleed: LaunchArgument.value("-icon-platform") == "ios"), to: URL(fileURLWithPath: path))
            print("icon written to \(path)")
            exit(0)
        } catch {
            print("icon render failed: \(error)")
            exit(1)
        }
    }

    static func render(size: Int, fullBleed: Bool = false) throws -> CGImage {
        let root = Entity()
        let base = ModelLibrary.entity("base")
        root.addChild(base)
        var building = CityStore.Building(name: "icon", path: "", style: Facade.Style.brick.rawValue)
        building.floors = [.init(name: "", hires: [], budgetUSD: 1), .init(name: "", hires: [], budgetUSD: 1)]
        let tower = Facade.tower(building, dark: false)
        tower.position = [0.12, 0.1, -0.2]
        Facade.light(tower, glow: 0.3)
        root.addChild(tower)
        let bush = ModelLibrary.entity("bush")
        bush.position = [0.78, 0.1, 0.68]
        bush.scale = SIMD3(repeating: 1.3)
        root.addChild(bush)
        let robot = ModelLibrary.entity("robot")
        robot.position = [-0.38, 0.1, 0.68]
        robot.scale = SIMD3(repeating: 1.05)
        robot.orientation = simd_quatf(angle: 0.66, axis: [0, 1, 0])
        root.addChild(robot)
        _ = Worker(robot: robot, screen: nil, colour: Palette.primaryFill, room: "reception")

        let sun = Entity()
        let warmth = Palette.dusk.blended(withFraction: 0.78, of: .white) ?? .white
        Sun.light(sun, colour: warmth, intensity: 3200, from: [-3, 7, 5])
        sun.components.set(Sun.shadow(reach: 12, depthBias: 0.5))
        root.addChild(sun)
        for entity in root.descendants where entity.components.has(ModelComponent.self) {
            entity.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: true))
        }
        let camera = Entity()
        var ortho = OrthographicCameraComponent()
        ortho.scale = 1.82
        camera.components.set(ortho)
        camera.look(at: [0, 0.64, 0], from: [9, 7.8, 11], relativeTo: nil)
        root.addChild(camera)
        let recorder = try FrameRecorder(root: root, camera: camera, width: size, height: size,
                                         environment: ModelLibrary.environment("sky"), exposure: 0.3)
        try recorder.warmUp()
        let scene = try recorder.capture()

        let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let inset = fullBleed ? 0 : CGFloat(size) * 100 / 1024
        let shape = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
        let radius = fullBleed ? 0 : shape.width * 0.225
        let squircle = CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)
        canvas.saveGState()
        canvas.setShadow(offset: CGSize(width: 0, height: -CGFloat(size) * 0.012), blur: CGFloat(size) * 0.02,
                         color: Palette.resolved(Palette.mullion, dark: false).withAlphaComponent(0.22).cgColor)
        canvas.addPath(squircle)
        canvas.setFillColor(Palette.resolved(Palette.facadeStone, dark: false).cgColor)
        canvas.fillPath()
        canvas.restoreGState()
        canvas.addPath(squircle)
        canvas.clip()
        let top = Palette.resolved(Palette.cloud, dark: false)
        let bottom = Palette.resolved(Palette.duskSky, dark: false)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [bottom.cgColor, top.cgColor] as CFArray, locations: [0, 1])!
        canvas.drawLinearGradient(gradient, start: CGPoint(x: shape.midX, y: shape.minY),
                                  end: CGPoint(x: shape.midX, y: shape.maxY), options: [])
        canvas.draw(scene, in: shape)
        canvas.addPath(squircle)
        canvas.setStrokeColor(top.withAlphaComponent(0.7).cgColor)
        canvas.setLineWidth(CGFloat(size) * 0.004)
        canvas.strokePath()
        return canvas.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
