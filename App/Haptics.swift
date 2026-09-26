import AppKit

/// Trackpad feedback for decisive moments; Force Touch trackpads only, silent elsewhere.
@MainActor
enum Haptics {
    static func pick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func stamp() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}
