import AppKit
import RealityKit

/// Renders the app icon from the city's own models: `TheCity -render-icon <file.png>`.
@MainActor
enum IconRenderer {
    static func run(to path: String) {
        do {
            try write(render(size: 1024), to: URL(fileURLWithPath: path))
            print("icon written to \(path)")
            exit(0)
        } catch {
            print("icon render failed: \(error)")
            exit(1)
        }
    }

    static func render(size: Int) throws -> CGImage {
        let root = Entity()
        let base = ModelLibrary.entity("base")
        root.addChild(base)
        var building = CityStore.Building(name: "icon", path: "", style: Facade.Style.brick.rawValue)
        building.floors = [.init(name: "", hires: [], budgetUSD: 1), .init(name: "", hires: [], budgetUSD: 1)]
        let tower = Facade.tower(building, dark: false)
        tower.position = [0.05, 0.1, -0.1]
        root.addChild(tower)
        let bush = ModelLibrary.entity("bush")
        bush.position = [0.78, 0.1, 0.72]
        bush.scale = SIMD3(repeating: 1.6)
        root.addChild(bush)
        let robot = ModelLibrary.entity("robot")
        robot.position = [-0.2, 0.1, 0.78]
        robot.scale = SIMD3(repeating: 0.85)
        robot.orientation = simd_quatf(angle: 0.78, axis: [0, 1, 0])
        root.addChild(robot)
        _ = Worker(robot: robot, screen: nil, colour: Palette.primaryFill, room: "reception")

        let sun = Entity()
        var light = DirectionalLightComponent(color: .white, intensity: 2600)
        light.isRealWorldProxy = false
        sun.components.set(light)
        sun.look(at: .zero, from: [-4, 10, 6], relativeTo: nil)
        root.addChild(sun)
        let camera = Entity()
        var ortho = OrthographicCameraComponent()
        ortho.scale = 1.9
        camera.components.set(ortho)
        camera.look(at: [0, 0.55, 0], from: [9, 8, 9], relativeTo: nil)
        root.addChild(camera)
        let recorder = try FrameRecorder(root: root, camera: camera, width: size, height: size,
                                         environment: ModelLibrary.environment("sky"), exposure: 0.6)
        try recorder.warmUp()
        let scene = try recorder.capture()

        let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let inset = CGFloat(size) * 100 / 1024
        let shape = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
        let squircle = CGPath(roundedRect: shape, cornerWidth: shape.width * 0.225, cornerHeight: shape.width * 0.225, transform: nil)
        canvas.addPath(squircle)
        canvas.setFillColor(Palette.resolved(Palette.background, dark: false).cgColor)
        canvas.fillPath()
        canvas.addPath(squircle)
        canvas.clip()
        canvas.draw(scene, in: shape.insetBy(dx: -shape.width * 0.02, dy: -shape.width * 0.02))
        return canvas.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
