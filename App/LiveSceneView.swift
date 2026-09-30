import AppKit
import Combine
import Metal
import RealityKit
import SwiftUI
import Synchronization

/// Register callbacks before attaching entities or subscribing to scene events.
/// Those operations start the renderer; changing its callbacks afterwards traps.
/// Direct ownership lets us enforce that order and retain native entity picking.
struct LiveSceneView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let root: Entity
    let camera: () -> CameraRig
    let quality: GraphicsQuality
    var miniatureFocus = false
    let update: (Double) -> Void
    let tapped: (Entity) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PickingView {
        let view = PickingView(frame: .zero)
        view.renderCallbacks.postProcess = { [processor = context.coordinator.processor] context in
            processor.render(context)
        }
        context.coordinator.install(root: root, in: view)
        configure(view, context: context)
        return view
    }

    func updateNSView(_ view: PickingView, context: Context) { configure(view, context: context) }

    private func configure(_ view: PickingView, context: Context) {
        context.coordinator.update = update
        view.tapped = tapped
        view.camera = camera
        context.coordinator.processor.focus.withLock { $0 = miniatureFocus ? quality.focus : nil }
        view.environment.background = .color(DayCycle.now.sky(dark: colorScheme == .dark && BrandStore.shared.current.supportsDark))
    }

    static func dismantleNSView(_ view: PickingView, coordinator: Coordinator) {
        coordinator.subscription?.cancel()
        view.scene.anchors.removeAll()
    }

    @MainActor final class Coordinator {
        let processor = LiveSceneProcessor()
        var update: ((Double) -> Void)?
        var subscription: (any Cancellable)?

        func install(root: Entity, in view: ARView) {
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(root)
            view.scene.anchors.append(anchor)
            subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                self?.update?(event.deltaTime)
            }
        }
    }

    @MainActor final class PickingView: ARView {
        var tapped: ((Entity) -> Void)?
        var camera: (() -> CameraRig)?
        private var down: CGPoint?

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            down = event.locationInWindow
        }

        override func mouseUp(with event: NSEvent) {
            defer { down = nil }
            guard let down, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) < 5 else { return }
            var point = convert(event.locationInWindow, from: nil)
            if !isFlipped { point.y = bounds.height - point.y }
            guard let camera = camera?() else { return }
            // Cast through the rig's explicit camera, matching overlay projection
            // through camera switches and the scaled city/building transition.
            let eye = camera.entity.position(relativeTo: nil)
            let forward = simd_normalize(camera.current.target * camera.frame.scale + camera.frame.offset - eye)
            let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
            let up = simd_cross(right, forward)
            let lens = camera.entity.components[PerspectiveCameraComponent.self]
            let focal = Float(bounds.height) / 2 / tan((lens?.fieldOfViewInDegrees ?? 26) * .pi / 360)
            let direction = simd_normalize(forward + right * ((Float(point.x) - Float(bounds.width) / 2) / focal)
                                          - up * ((Float(point.y) - Float(bounds.height) / 2) / focal))
            let hit = scene.raycast(origin: eye, direction: direction, length: lens?.far ?? 6000, query: .nearest).first?.entity
            if ProcessInfo.processInfo.arguments.contains("-live-grade-check") {
                FileHandle.standardError.write(Data("LiveScenePick point=\(point) size=\(bounds.size) entity=\(hit?.name ?? "none")\n".utf8))
            }
            if let hit { tapped?(hit) }
        }
    }
}

/// Scratch textures belong to this view's serial RealityKit render callback.
/// UI changes cross to that callback through the mutex; no view or actor state is
/// accessed while encoding GPU work.
final class LiveSceneProcessor: @unchecked Sendable {
    let focus = Mutex<GraphicsQuality.Focus?>(nil)
    private var grader: Grader?
    private var graded: (any MTLTexture)?
    private var frames = 0
    private let diagnostics = ProcessInfo.processInfo.arguments.contains("-live-grade-check")

    func render(_ context: ARView.PostProcessContext) {
        if grader == nil { grader = Grader(device: context.device) }
        let source = context.sourceColorTexture, target = context.targetColorTexture
        frames += 1
        if diagnostics, frames == 1 || frames == 120 {
            let message = "LiveSceneGrade frame=\(frames) source=\(source.pixelFormat.rawValue) target=\(target.pixelFormat.rawValue) writable=\(target.usage.contains(.shaderWrite)) focus=\(focus.withLock { $0 != nil })\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        guard let grader, target.usage.contains(.shaderWrite) else {
            if let blit = context.commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: source, to: target)
                blit.endEncoding()
            }
            return
        }
        let settings = SceneGrade.settings.withLock { $0 }
        guard let focus = focus.withLock({ $0 }) else {
            grader.encode(source: source, target: target, into: context.commandBuffer, settings: settings)
            return
        }
        if graded?.width != target.width || graded?.height != target.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: target.width, height: target.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            graded = context.device.makeTexture(descriptor: descriptor)
        }
        guard let graded else {
            grader.encode(source: source, target: target, into: context.commandBuffer, settings: settings)
            return
        }
        grader.encode(source: source, target: graded, into: context.commandBuffer, settings: settings)
        grader.focus(source: graded, target: target, into: context.commandBuffer, focus: focus)
    }
}
