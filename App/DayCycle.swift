#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealityKit

/// The scenes' time of day in the system time zone; `-hour` pins it for renders.
struct DayCycle {
    static let dawn: ClosedRange<Double> = 6...7
    static let dusk: ClosedRange<Double> = 18...19.5
    static let tick: Double = 60

    let hour: Double

    @MainActor static var now: DayCycle {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now)
        let local = Double(parts.hour ?? 13) + Double(parts.minute ?? 0) / 60
        #if os(macOS)
        let selected = CityClock.shared.hour ?? local
        #else
        let selected = local
        #endif
        return DayCycle(hour: LaunchArgument.value("-hour").flatMap(Double.init) ?? selected)
    }

    /// 1 in full day, 0 in full night, eased through dawn and dusk.
    var daylight: Float {
        let t: Double
        if Self.dawn.contains(hour) {
            t = (hour - Self.dawn.lowerBound) / (Self.dawn.upperBound - Self.dawn.lowerBound)
        } else if Self.dusk.contains(hour) {
            t = 1 - (hour - Self.dusk.lowerBound) / (Self.dusk.upperBound - Self.dusk.lowerBound)
        } else {
            t = hour > Self.dawn.upperBound && hour < Self.dusk.lowerBound ? 1 : 0
        }
        return Float(t * t * (3 - 2 * t))
    }

    var night: Float { 1 - daylight }
    var twilight: Float { 1 - abs(2 * daylight - 1) }
    /// Lamps come on early in the dusk and stay on until well into the dawn.
    var lamps: Float { min(night * 2, 1) }

    /// Where the sun (or, at night, the moon) sits, swinging `midday` round and lowering it towards the horizon.
    func sun(_ midday: SIMD3<Float>) -> SIMD3<Float> {
        guard daylight > 0 else { return [-midday.x, midday.y * 0.9, -midday.z] }
        let noon = (Self.dawn.lowerBound + Self.dusk.upperBound) / 2, span = Self.dusk.upperBound - noon
        let u = Float((min(max(hour, Self.dawn.lowerBound), Self.dusk.upperBound) - noon) / span)
        let turned = simd_quatf(angle: u * .pi / 3, axis: [0, 1, 0]).act(midday)
        return [turned.x, turned.y * (1 - 0.75 * u * u), turned.z]
    }

    var sunColour: NSColor {
        let white = NSColor.white.blended(withFraction: 0.12, of: Palette.dawnSky) ?? .white
        let warmed = white.blended(withFraction: CGFloat(twilight.squareRoot()), of: hour < 12 ? Palette.dusk : Palette.duskSky) ?? white
        return warmed.blended(withFraction: CGFloat(moon), of: Palette.moonlight) ?? warmed
    }

    func sky(dark: Bool) -> NSColor {
        let day = Palette.resolved(Palette.background, dark: dark)
        let warmed = day.blended(withFraction: CGFloat(twilight), of: hour < 12 ? Palette.dawnSky : Palette.duskSky) ?? day
        return warmed.blended(withFraction: CGFloat(moon), of: Palette.nightSky) ?? warmed
    }

    /// Holds off until the sun is mostly down, so dusk stays warm.
    private var moon: Float {
        let t = max(night - 0.5, 0) * 2
        return t * t
    }

    /// `day` in full daylight, `night` in full dark.
    func mix(day: Float, night: Float) -> Float {
        night + (day - night) * daylight
    }
}

/// A lamp that fades in as night falls; each scene re-lights them on its daylight tick.
struct NightLightComponent: Component {
    var intensity: Float
    var colour: NSColor
    var radius: Float
    var bulb: Entity?
}

@MainActor
enum NightLight {
    private static let registered: Void = NightLightComponent.registerComponent()

    static func add(to parent: Entity, at offset: SIMD3<Float>, colour: NSColor, intensity: Float, radius: Float, bulb size: Float) {
        _ = registered
        let light = Entity()
        light.position = offset
        let bulb = ModelEntity(mesh: .generateSphere(radius: size), materials: [ModelLibrary.material(colour, roughness: nil, emissive: 3)])
        light.addChild(bulb)
        let lamp = NightLightComponent(intensity: intensity, colour: colour, radius: radius, bulb: bulb)
        light.components.set(lamp)
        relight(light, lamp, lamps: DayCycle.now.lamps)
        parent.addChild(light)
    }

    static func apply(_ cycle: DayCycle, under root: Entity) {
        _ = registered
        for entity in root.descendants {
            guard let lamp = entity.components[NightLightComponent.self] else { continue }
            relight(entity, lamp, lamps: cycle.lamps)
        }
    }

    // RealityKit still culls and clusters a light at zero intensity, so an unlit lamp drops its light altogether.
    private static func relight(_ entity: Entity, _ lamp: NightLightComponent, lamps: Float) {
        lamp.bulb?.isEnabled = lamps > 0
        guard lamps > 0 else { return entity.components.remove(PointLightComponent.self) }
        entity.components.set(PointLightComponent(color: lamp.colour, intensity: lamp.intensity * lamps, attenuationRadius: lamp.radius))
    }
}
