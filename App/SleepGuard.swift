import Foundation
import Observation

/// Holds off idle sleep while any floor has a job running, so a run keeps going after you walk away. The display may still sleep.
@MainActor
final class SleepGuard {
    static let shared = SleepGuard()
    private var activity: NSObjectProtocol?

    func watch(_ city: CityStore) {
        let running = withObservationTracking { city.anyRunning } onChange: {
            Task { @MainActor in SleepGuard.shared.watch(city) }
        }
        hold(running)
    }

    private func hold(_ running: Bool) {
        if running, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Claude Code jobs are running")
        } else if !running, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
    }
}
