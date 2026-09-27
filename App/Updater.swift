import Sparkle

@MainActor
final class Updater {
    static let shared = Updater()
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}
