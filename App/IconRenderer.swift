import AppKit
import Metal
import RealityKit

/// Renders the app icon from the scene's own manager desk: `TheCity -render-icon <file.png>`.
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
        guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
        let renderer = try RealityRenderer()
        let root = Entity()
        let pod = Pod(room: "manager", colour: Palette.manager, at: .zero, variant: 3, dark: true)
        pod.worker.setMood(.idle)
        root.addChild(pod.root)
        let sun = Entity()
        var light = DirectionalLightComponent(color: .white, intensity: 2600)
        light.isRealWorldProxy = false
        sun.components.set(light)
        sun.look(at: .zero, from: [-4, 10, 6], relativeTo: nil)
        root.addChild(sun)
        let camera = Entity()
        var ortho = OrthographicCameraComponent()
        ortho.scale = 3.4
        camera.components.set(ortho)
        camera.look(at: [0, 1.2, 0], from: [9, 9.5, 9], relativeTo: nil)
        root.addChild(camera)
        renderer.entities.append(root)
        renderer.activeCamera = camera
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
        if let environment = ModelLibrary.environment("studio") {
            renderer.lighting.resource = environment
            renderer.lighting.intensityExponent = 0.6
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw CocoaError(.featureUnsupported) }
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        let done = DispatchSemaphore(value: 0)
        for _ in 0..<3 { try renderer.update(1.0 / 60) }
        try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output, onComplete: { _ in done.signal() })
        guard done.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        let scene = CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!.makeImage()!

        let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let inset = CGFloat(size) * 100 / 1024
        let shape = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
        let squircle = CGPath(roundedRect: shape, cornerWidth: shape.width * 0.225, cornerHeight: shape.width * 0.225, transform: nil)
        canvas.addPath(squircle)
        canvas.setFillColor(Palette.resolved(Palette.background, dark: true).cgColor)
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
