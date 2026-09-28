import AVFoundation
import SwiftUI
import UserNotifications

@main
struct CompanionApp: App {
    @UIApplicationDelegateAdaptor(CompanionDelegate.self) private var delegate
    @State private var link = CityLink()
    @Environment(\.scenePhase) private var phase

    init() {
        // Ambient, so the office's sounds mix with whatever is playing and the silent switch mutes them.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        Typography.register(brand: BrandStore.shared.current)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if link.pairing == nil {
                    PairingView(link: link)
                } else {
                    CityScreen(link: link)
                }
            }
            .onOpenURL { url in link.pair(with: url) }
            .onChange(of: phase, initial: true) {
                if phase == .active { link.start() } else if phase == .background { link.stop() }
            }
        }
    }
}

@MainActor
final class CompanionDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if COMPANION_CLOUD
        Task {
            guard (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
        #endif
        return true
    }

    /// The city is already on screen when the app is open, so a question shows there rather than as a banner too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.sound]
    }
}
