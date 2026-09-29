#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealityKit

/// The directional light a scene uses as its sun, and how far its shadows reach.
struct Sun: Equatable {
    let from: SIMD3<Float>
    let day: Float
    let night: Float

    static let storey = Sun(from: [-16, 14, -18], day: 2600, night: 700)
    static let city = Sun(from: [-8, 14, 6], day: 3500, night: 1100)
    static let emptyLot = Sun(from: [-8, 12, 6], day: 2400, night: 600)
    static let depthBias: Float = 1

    @MainActor func apply(to entity: Entity, cycle: DayCycle) {
        Self.light(entity, colour: cycle.sunColour, intensity: cycle.mix(day: day, night: night), from: cycle.sun(from))
    }

    @MainActor static func light(_ entity: Entity, colour: NSColor, intensity: Float, from position: SIMD3<Float>) {
        var light = DirectionalLightComponent(color: colour, intensity: intensity)
        light.isRealWorldProxy = false
        entity.components.set(light)
        entity.look(at: .zero, from: position, relativeTo: nil)
    }

    static func shadow(reach: Float, depthBias: Float = depthBias) -> DirectionalLightComponent.Shadow {
        DirectionalLightComponent.Shadow(shadowProjection: .automatic(maximumDistance: reach), depthBias: depthBias)
    }

    /// Rounded up to 10 m steps, so a moving camera rewrites the shadow rarely.
    static func reach(distance: Float, extent: Float) -> Float {
        ((distance + extent) / 10).rounded(.up) * 10
    }
}
