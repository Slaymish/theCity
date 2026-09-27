import AppKit
import OfficeCore
import SwiftUI

struct ContentView: View {
    let city: CityStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: DayCycle.tick)) { _ in
                Color(DayCycle.now.sky(dark: colorScheme == .dark)).ignoresSafeArea()
            }
            switch city.route {
            case .welcome, .city, .building, .floor, .newFloor:
                WorldView(city: city)
            }
        }
        .foregroundStyle(Color(Palette.text))
        .onAppear {
            MainWindow.shared.appeared(openWindow)
            if let path = RunController.launchArgument("-replay") { city.startReplay(URL(fileURLWithPath: path)) }
        }
        .onDisappear { MainWindow.shared.disappeared() }
        .onChange(of: colorScheme) {
            for session in city.allSessions { session.scene.setDark(colorScheme == .dark) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .replayFixture)) { _ in
            if let url = Self.chooseFile() { city.startReplay(url) }
        }
    }

    private static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "jsonl") ?? .json]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A new floor: describe the job, hire its departments, then its office opens.
struct DraftFlow: View {
    @Bindable var controller: RunController
    let onCancel: () -> Void

    var body: some View {
        switch controller.screen {
        case .reception: ReceptionView(controller: controller, onCancel: onCancel)
        case .hiring: HiringView(controller: controller)
        case .office: OfficeView(controller: controller)
        }
    }
}

extension Notification.Name {
    static let replayFixture = Notification.Name("replayFixture")
    static let resetView = Notification.Name("resetView")
}

struct Wordmark: View {
    var compact = false

    var body: some View {
        let brand = BrandStore.shared.current
        HStack(spacing: compact ? 8 : 12) {
            if let logo = brand.logoImage {
                Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit).frame(height: compact ? 20 : 34)
            } else {
                if let symbol = brand.wordmarkSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 18 : 30, weight: .semibold))
                        .foregroundStyle(Color(Palette.primaryFill))
                }
                Text(brand.name).font(compact ? Typography.titleSmall : Typography.titleLarge)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(brand.name)
    }
}

extension View {
    func commandReturn(enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command), enabled else { return .ignored }
            action()
            return .handled
        }
    }
}
