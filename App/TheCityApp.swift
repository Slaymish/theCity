import AppKit
import SwiftUI

@main
struct TheCityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var city: CityStore
    @State private var preferences: Preferences
    @State private var brands: BrandStore

    init() {
        LegacyData.migrate()
        _city = State(initialValue: .shared)
        _preferences = State(initialValue: .shared)
        _brands = State(initialValue: .shared)
    }

    var body: some Scene {
        Window("The City", id: "office") {
            ContentView(city: city)
                .id(brands.selectedID)
                .frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(preferences.colorScheme)
                .background(WindowFrameSaver(name: "office"))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { OfficeCommands(city: city) }

        Window("Raw Log", id: "raw-log") {
            RawLogView(city: city)
                .preferredColorScheme(preferences.colorScheme)
                .background(WindowFrameSaver(name: "raw-log"))
        }
        .defaultSize(width: 560, height: 640)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(city: city)
                .preferredColorScheme(preferences.colorScheme)
        }
    }
}

struct OfficeCommands: Commands {
    let city: CityStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        #if !DEBUG
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.controller.checkForUpdates(nil) }
        }
        #endif
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { ProjectPicker.addProject() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Floor…") {
                switch city.route {
                case .building(let id), .floor(let id, _): city.startNewFloor(in: id)
                default: break
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled({ if case .building = city.route { false } else if case .floor = city.route { false } else { true } }())
            Menu("Open Recent") {
                ForEach(city.buildings) { building in
                    ForEach(building.floors) { floor in
                        Button("\(building.name) · \(floor.name)") { city.route = .floor(building: building.id, floor: floor.id) }
                    }
                }
            }
            .disabled(city.buildings.allSatisfy(\.floors.isEmpty))
        }
        CommandGroup(before: .toolbar) {
            Button("City") { city.route = city.buildings.isEmpty ? .welcome : .city }
                .keyboardShortcut("0", modifiers: .command)
            ForEach(1...9, id: \.self) { number in
                Button("Floor \(number)") {
                    if let id = city.currentBuildingID, let floor = city.building(id)?.floors.dropFirst(number - 1).first {
                        city.route = .floor(building: id, floor: floor.id)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                .disabled((city.currentBuildingID.flatMap { city.building($0)?.floors.count } ?? 0) < number)
            }
            Button(city.activeSession?.showPanel ?? true ? "Hide Panel" : "Show Panel") { city.activeSession?.showPanel.toggle() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(city.activeSession == nil)
            Button("Show Raw Log") { openWindow(id: "raw-log") }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Job") {
            Button("Cancel Job") { city.activeSession?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(city.activeSession?.isRunning != true)
        }
        CommandGroup(replacing: .help) {}
        #if DEBUG
        CommandMenu("Debug") {
            Button("Replay Fixture…") { NotificationCenter.default.post(name: .replayFixture, object: nil) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        #endif
    }
}

/// SwiftUI's own frame saving is off along with state restoration, so the frame is kept by name instead.
struct WindowFrameSaver: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct RawLogView: View {
    let city: CityStore

    var body: some View {
        EventLogList(entries: city.activeSession?.log ?? [])
            .padding(12)
            .frame(minWidth: 420, minHeight: 300)
            .background(Color(Palette.background))
            .foregroundStyle(Color(Palette.text))
    }
}
