import AppKit
import OfficeCore
import UserNotifications

@MainActor
final class Attention: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Attention()
    private var asked = false

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.finishedCategory, actions: [
                UNNotificationAction(identifier: "open", title: "Open", options: [.foreground]),
                UNNotificationAction(identifier: "show", title: "Show in The City", options: [.foreground]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [
                UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
            ], intentIdentifiers: []),
        ])
    }

    /// Called for every stream line, so it only touches the Dock when the badge actually changes.
    func waiting(_ count: Int) {
        let label = count > 0 ? "\(count)" : nil
        guard NSApp.dockTile.badgeLabel != label else { return }
        NSApp.dockTile.badgeLabel = label
    }

    func needsInput(from room: String, request: PermissionRequest, place: String, building: UUID?, floor: UUID?) {
        let who = room == "manager" ? "The manager" : room.capitalized
        let location = Self.location(building: building, floor: floor)
        switch request.kind {
        case .question(let questions):
            post(title: "\(who) has a question", subtitle: place, body: questions.first?.question ?? "", info: location)
        case .approval(let summary):
            post(title: "\(who) asks to use \(McpNaming.friendly(request.toolName, servers: []))", subtitle: place, body: summary,
                 category: Self.approvalCategory, info: location.merging(["request": request.requestID]) { $1 })
        }
    }

    func finished(_ outcome: RunOutcome, files: [String], place: String, building: UUID?, floor: UUID?) {
        let location = Self.location(building: building, floor: floor)
        switch outcome {
        case .completed:
            let name = files.first.map { URL(fileURLWithPath: $0).lastPathComponent }
            post(title: name.map { "\($0) is ready" } ?? "The job is done", subtitle: place, body: files.count > 1 ? "And \(files.count - 1) more in the outbox." : "Open the floor to see the result.",
                 category: Self.finishedCategory, info: location.merging(files.first.map { ["file": $0] } ?? [:]) { $1 })
        case .cancelled: break
        case .failed: post(title: "The job stopped", subtitle: place, body: "Open the floor to see why.", info: location)
        }
    }

    func needsTeam(for floor: String, place: String, building: UUID, drafted: Bool) {
        post(title: "Reception needs you to pick a team for \(floor)", subtitle: place, body: "Open The City to choose its departments.",
             info: ["building": building.uuidString, "newFloor": drafted ? "yes" : "no"])
    }

    private static func location(building: UUID?, floor: UUID?) -> [String: String] {
        guard let building, let floor else { return [:] }
        return ["building": building.uuidString, "floor": floor.uuidString]
    }

    static let finishedCategory = "finished"
    static let approvalCategory = "approval"

    private func post(title: String, subtitle: String, body: String, category: String? = nil, info: [String: String] = [:]) {
        // An accessory app stays active after the menu bar's Ask Reception alert, with no window to show the request.
        guard !NSApp.isActive || !MainWindow.shared.isOpen, Preferences.shared.notifications else { return }
        NSApp.requestUserAttention(.informationalRequest)
        let center = UNUserNotificationCenter.current()
        Task {
            if !asked {
                asked = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            content.sound = Preferences.shared.sounds ? .default : nil
            if let category { content.categoryIdentifier = category }
            content.userInfo = info
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let file = info["file"] as? String
        let requestID = info["request"] as? String
        let building = (info["building"] as? String).flatMap(UUID.init(uuidString:))
        let floor = (info["floor"] as? String).flatMap(UUID.init(uuidString:))
        let newFloor = info["newFloor"] as? String
        await MainActor.run {
            let controller = requestID.flatMap { CityStore.shared.session(forRequest: $0) }
            switch action {
            case "open":
                if let file { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
            case "deny":
                guard let pending = controller?.state.pendingRequests.first(where: { $0.id == requestID }) else { break }
                controller?.deny(pending)
            default:
                let city = CityStore.shared
                let route: CityStore.Route? = if let building, let floor, city.floor(floor, in: building) != nil { .floor(building: building, floor: floor) }
                    else if let building, newFloor != nil, city.building(building) != nil { newFloor == "yes" && city.draft?.buildingID == building ? .newFloor(building) : .building(building) }
                    else { nil }
                MainWindow.shared.show(route: route)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { MainWindow.shared.isOpen } ? [] : [.banner, .list, .sound]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = RunController.launchArgument("-render-icon") { IconRenderer.run(to: path) }
        if let path = RunController.launchArgument("-render-preview") { PreviewStage.run(to: path) }
        if let reel = RunController.launchArgument("-render-reel"), let path = RunController.launchArgument(reel) { ReadmeReel.run(reel, to: path) }
        Attention.shared.setUp()
        if !MainWindow.offscreen { DictationStore.shared.start() }
        #if !DEBUG
        _ = Updater.shared
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !MainWindow.shared.isOpen { MainWindow.shared.show(route: nil) }
        return true
    }

    @MainActor func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let city = CityStore.shared
        let floors = city.buildings.flatMap { building in building.floors.map { (building, $0) } }
            .sorted { $0.1.createdAt > $1.1.createdAt }.prefix(6)
        guard !floors.isEmpty else { return nil }
        let menu = NSMenu()
        for (building, floor) in floors {
            let item = NSMenuItem(title: "\(building.name) · \(floor.name)", action: #selector(openFloor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "\(building.id.uuidString)|\(floor.id.uuidString)"
            menu.addItem(item)
        }
        return menu
    }

    @MainActor @objc func openFloor(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String else { return }
        let parts = value.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
        guard parts.count == 2 else { return }
        MainWindow.shared.show(route: .floor(building: parts[0], floor: parts[1]))
    }

    /// Quitting mid-run would otherwise leave `claude` running, since closing its stdin doesn't stop a turn.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CityStore.shared.anyRunning else { return .terminateNow }
        Task {
            await CityStore.shared.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
