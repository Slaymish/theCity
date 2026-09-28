import Foundation
import Metal
import RealityKit

enum GraphicsQuality: Int, CaseIterable, Identifiable {
    case low, medium, high, ultra

    struct Focus {
        var sharp: Float
        var falloff: Float
        var sigma: Float
        var encodeSRGB: UInt32 = 0
    }

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .ultra: "Ultra"
        }
    }

    var detail: String {
        switch self {
        case .low: "Everything in focus, without edge smoothing. Easiest on older Macs and the battery."
        case .medium: "Smooth edges and a soft miniature focus."
        case .high: "Smooth edges and a miniature focus that blurs the foreground and the distance."
        case .ultra: "The shallowest miniature focus, so the city looks like a model."
        }
    }

    var antialiasing: AntialiasingMode { self == .low ? .none : .multisample4X }

    var depthOfField: Bool { self != .low }

    var focus: Focus? {
        switch self {
        case .low: nil
        case .medium: Focus(sharp: 0.22, falloff: 0.35, sigma: 3)
        case .high: Focus(sharp: 0.14, falloff: 0.3, sigma: 6)
        case .ultra: Focus(sharp: 0.08, falloff: 0.3, sigma: 10)
        }
    }

    static func named(_ name: String) -> GraphicsQuality? {
        allCases.first { $0.title.lowercased() == name.lowercased() }
    }

    @MainActor static var forced: GraphicsQuality? { LaunchArgument.value("-graphics").flatMap(named) }

    #if os(macOS)
    @MainActor static var current: GraphicsQuality { forced ?? Preferences.shared.graphics ?? recommended }
    #endif

    static var recommended: GraphicsQuality {
        guard ProcessInfo.processInfo.isLowPowerModeEnabled else { return device }
        return GraphicsQuality(rawValue: max(device.rawValue - 1, 0)) ?? .low
    }

    private static let device: GraphicsQuality = {
        guard let device = MTLCreateSystemDefaultDevice() else { return .low }
        if device.supportsFamily(.apple9), device.hasUnifiedMemory, device.recommendedMaxWorkingSetSize >= 16 << 30 { return .ultra }
        if device.supportsFamily(.apple7) { return .high }
        #if os(macOS)
        return device.isLowPower ? .low : .medium
        #else
        return .medium
        #endif
    }()
}
