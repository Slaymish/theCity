#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Metal
import MetalPerformanceShaders
import RealityKit
import Synchronization

/// The scenes' finishing pass: bloom on lamps and lit windows, a colour grade that follows the time of day, and a vignette.
struct SceneGrade: PostProcessEffect {
    struct Settings {
        var bloom: Float = 0
        var threshold: Float = 1
        var saturation: Float = 1
        var vignette: Float = 0
        var contrast: Float = 1
        var shadows: SIMD3<Float> = .one
        var highlights: SIMD3<Float> = .one
        var encodeSRGB: UInt32 = 0
    }

    static let settings = Mutex(Settings())
    private var grader: Grader?

    @MainActor static func update(_ cycle: DayCycle) {
        let moon = Self.tint(Palette.moonlight), dusk = Self.tint(Palette.dusk)
        var next = Settings()
        next.bloom = cycle.mix(day: 0.15, night: 1.2)
        next.threshold = cycle.mix(day: 1.1, night: 0.45)
        next.saturation = 1.08 + 0.1 * cycle.twilight
        next.vignette = cycle.mix(day: 0.2, night: 0.4)
        next.contrast = 1.1
        next.shadows = .one + (moon - .one) * 0.35 * cycle.night
        next.highlights = .one + (dusk - .one) * 0.3 * cycle.twilight
        settings.withLock { $0 = next }
    }

    /// A token's hue in linear light, scaled to unit luminance so tinting shifts colour without darkening.
    @MainActor private static func tint(_ colour: NSColor) -> SIMD3<Float> {
        let rgb = colour.usingColorSpace(.sRGB) ?? colour
        let linear = SIMD3<Float>([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Float(pow($0, 2.2)) })
        return linear / max(simd_dot(linear, [0.2126, 0.7152, 0.0722]), 0.001)
    }

    mutating func prepare(for device: any MTLDevice) {
        grader = Grader(device: device)
    }

    mutating func postProcess(context: borrowing PostProcessEffectContext<any MTLCommandBuffer>) {
        let source = context.sourceColorTexture, target = context.targetColorTexture
        guard let grader, target.usage.contains(.shaderWrite) else {
            guard source.pixelFormat == target.pixelFormat, source.width == target.width, source.height == target.height,
                  let blit = context.commandBuffer.makeBlitCommandEncoder() else { return }
            blit.copy(from: source, to: target)
            blit.endEncoding()
            return
        }
        grader.encode(source: source, target: target, into: context.commandBuffer,
                      settings: Self.settings.withLock { $0 })
    }
}

/// Holds the compiled kernels and scratch textures; only ever touched from the render callback that owns it.
final class Grader: @unchecked Sendable {
    private let brightPass: MTLComputePipelineState
    private let composite: MTLComputePipelineState
    private let blur: MPSImageGaussianBlur
    private var scratch: (bright: MTLTexture, blurred: MTLTexture)?

    init?(device: any MTLDevice) {
        guard let library = try? device.makeLibrary(source: Self.source, options: nil),
              let bright = library.makeFunction(name: "brightPass").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let composite = library.makeFunction(name: "composite").flatMap({ try? device.makeComputePipelineState(function: $0) })
        else { return nil }
        brightPass = bright
        self.composite = composite
        blur = MPSImageGaussianBlur(device: device, sigma: 6)
        blur.edgeMode = .clamp
    }

    func encode(source: any MTLTexture, target: any MTLTexture, into buffer: any MTLCommandBuffer, settings: SceneGrade.Settings) {
        let width = max(source.width / 2, 1), height = max(source.height / 2, 1)
        if scratch?.bright.width != width || scratch?.bright.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let bright = source.device.makeTexture(descriptor: descriptor),
                  let blurred = source.device.makeTexture(descriptor: descriptor) else { return }
            scratch = (bright, blurred)
        }
        guard let scratch else { return }
        var settings = settings
        dispatch(brightPass, [source, scratch.bright], &settings, size: (width, height), into: buffer)
        blur.encode(commandBuffer: buffer, sourceTexture: scratch.bright, destinationTexture: scratch.blurred)
        dispatch(composite, [source, scratch.blurred, target], &settings, size: (target.width, target.height), into: buffer)
    }

    private func dispatch(_ pipeline: MTLComputePipelineState, _ textures: [any MTLTexture], _ settings: inout SceneGrade.Settings,
                          size: (Int, Int), into buffer: any MTLCommandBuffer) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        encoder.setBytes(&settings, length: MemoryLayout<SceneGrade.Settings>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: size.0, height: size.1, depth: 1), threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Settings {
        float bloom;
        float threshold;
        float saturation;
        float vignette;
        float contrast;
        float3 shadows;
        float3 highlights;
        uint encodeSRGB;
    };

    constant float3 luma = float3(0.2126, 0.7152, 0.0722);
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

    kernel void brightPass(texture2d<float, access::sample> source [[texture(0)]],
                           texture2d<float, access::write> bright [[texture(1)]],
                           constant Settings& s [[buffer(0)]],
                           uint2 id [[thread_position_in_grid]]) {
        if (id.x >= bright.get_width() || id.y >= bright.get_height()) return;
        float2 uv = (float2(id) + 0.5) / float2(bright.get_width(), bright.get_height());
        float3 c = source.sample(linearClamp, uv).rgb;
        float l = dot(c, luma);
        float knee = 0.2;
        float soft = clamp(l - s.threshold + knee, 0.0, 2.0 * knee);
        soft = soft * soft / (4.0 * knee + 1e-4);
        float weight = max(soft, l - s.threshold) / max(l, 1e-4);
        bright.write(float4(c * weight, 1.0), id);
    }

    kernel void composite(texture2d<float, access::sample> source [[texture(0)]],
                          texture2d<float, access::sample> glow [[texture(1)]],
                          texture2d<float, access::write> target [[texture(2)]],
                          constant Settings& s [[buffer(0)]],
                          uint2 id [[thread_position_in_grid]]) {
        if (id.x >= target.get_width() || id.y >= target.get_height()) return;
        float2 uv = (float2(id) + 0.5) / float2(target.get_width(), target.get_height());
        float4 base = source.sample(linearClamp, uv);
        float3 halo = glow.sample(linearClamp, uv).rgb * s.bloom;
        float3 c = base.rgb + halo;
        float l = dot(c, luma);
        c = max(mix(float3(l), c, s.saturation), 0.0);
        c = 0.18 * pow(c / 0.18, s.contrast);
        c *= mix(s.shadows, s.highlights, smoothstep(0.05, 0.8, l));
        float2 d = (uv - 0.5) * float2(1.0, 0.85);
        c *= 1.0 - s.vignette * smoothstep(0.25, 0.8, length(d));
        float alpha = max(base.a, min(dot(halo, luma), 1.0));
        if (s.encodeSRGB != 0) {
            c = clamp(c, 0.0, 1.0);
            c = select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
        }
        target.write(float4(c, alpha), id);
    }
    """
}
