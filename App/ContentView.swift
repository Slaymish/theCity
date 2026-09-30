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
            case .newFloor:
                if let draft = city.draft, draft.screen == .office {
                    OfficeView(controller: draft)
                } else {
                    WorldView(city: city)
                }
            case .welcome, .city, .building, .floor:
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

extension Notification.Name {
    static let replayFixture = Notification.Name("replayFixture")
    static let resetView = Notification.Name("resetView")
}

struct Wordmark: View {
    var compact = false
    /// Just the symbol, where there's no room for the name. Brands without a symbol keep the name.
    var symbolOnly = false

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
                if !symbolOnly || brand.wordmarkSymbol == nil {
                    Text(brand.name).font(compact ? Typography.titleSmall : Typography.titleLarge)
                }
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
