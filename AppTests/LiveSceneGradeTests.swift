import AppKit
import Metal
import RealityKit
import Testing
@testable import TheCity

@MainActor
struct LiveSceneGradeTests {
    @Test func directViewAcceptsPostProcessing() {
        let view = ARView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let processor = LiveSceneProcessor()
        view.renderCallbacks.postProcess = { processor.render($0) }
        #expect(view.renderCallbacks.postProcess != nil)
        view.renderCallbacks = .init()
    }

    @Test func liveCallbackGradesPixelsAndAppliesFocus() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 32, height: 32, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let target = try #require(device.makeTexture(descriptor: descriptor))
        var pixels = [Float](repeating: 0, count: 32 * 32 * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) { pixels[index + 3] = 1 }
        let bright = (1 * 32 + 16) * 4
        pixels[bright] = 0.4
        pixels.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 32 * 4 * MemoryLayout<Float>.size)
        }
        let previous = SceneGrade.settings.withLock { $0 }
        defer { SceneGrade.settings.withLock { $0 = previous } }
        var settings = SceneGrade.Settings()
        settings.shadows = SIMD3(repeating: 2)
        settings.highlights = SIMD3(repeating: 2)
        SceneGrade.settings.withLock { $0 = settings }
        let processor = LiveSceneProcessor()

        func render() throws -> [Float] {
            let buffer = try #require(queue.makeCommandBuffer())
            processor.render(ARView.PostProcessContext(device, buffer, source, source, target, matrix_identity_float4x4, 0))
            buffer.commit()
            buffer.waitUntilCompleted()
            #expect(buffer.error == nil)
            var output = [Float](repeating: 0, count: pixels.count)
            output.withUnsafeMutableBytes { bytes in
                target.getBytes(bytes.baseAddress!, bytesPerRow: 32 * 4 * MemoryLayout<Float>.size, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
            }
            return output
        }

        let sharp = try render()
        #expect(abs(sharp[bright] - 0.8) < 0.005, "The live callback must grade pixels rather than copy the source.")
        processor.focus.withLock { $0 = GraphicsQuality.Focus(sharp: 0.08, falloff: 0.3, sigma: 200) }
        let focused = try render()
        #expect(focused[bright] < sharp[bright] * 0.5, "Foreground miniature focus should blur an isolated bright pixel.")
        #expect(focused[bright + 4] > sharp[bright + 4], "Focus should spread light into neighbouring pixels.")
    }
}
