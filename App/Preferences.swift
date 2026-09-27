import AppKit
import Observation
import OfficeCore
import SwiftUI

@MainActor
@Observable
final class Preferences {
    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "Match System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var scheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    var configDirectory: URL? {
        didSet { defaults.set(configDirectory?.path, forKey: "configDirectory") }
    }
    var model: String? {
        didSet { defaults.set(model, forKey: "model") }
    }
    var budgetUSD: Double {
        didSet { defaults.set(budgetUSD, forKey: "budgetUSD") }
    }
    var permissionMode: PermissionMode {
        didSet { defaults.set(permissionMode.rawValue, forKey: "permissionMode") }
    }
    var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }
    var notifications: Bool {
        didSet { defaults.set(notifications, forKey: "notifications") }
    }
    var sounds: Bool {
        didSet { defaults.set(sounds, forKey: "sounds") }
    }
    var soundVolume: Double {
        didSet { defaults.set(soundVolume, forKey: "soundVolume") }
    }
    var cliPath: String? {
        didSet { defaults.set(cliPath, forKey: "cliPath") }
    }
    var editorPath: String? {
        didSet { defaults.set(editorPath, forKey: "editorPath") }
    }
    var hiddenAccounts: Set<String> {
        didSet { defaults.set(Array(hiddenAccounts), forKey: "hiddenAccounts") }
    }

    private init() {
        configDirectory = defaults.string(forKey: "configDirectory").map { URL(fileURLWithPath: $0) }
            ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        model = defaults.string(forKey: "model")
        budgetUSD = defaults.object(forKey: "budgetUSD") as? Double ?? 1.0
        permissionMode = PermissionMode(rawValue: defaults.string(forKey: "permissionMode") ?? "") ?? .auto
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        notifications = defaults.object(forKey: "notifications") as? Bool ?? true
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.7
        cliPath = defaults.string(forKey: "cliPath")
        editorPath = defaults.string(forKey: "editorPath")
        hiddenAccounts = Set(defaults.stringArray(forKey: "hiddenAccounts") ?? [])
    }

    var isDark: Bool {
        guard BrandStore.shared.current.supportsDark else { return false }
        return switch colorScheme {
        case .dark: true
        case .light: false
        default: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var colorScheme: ColorScheme? {
        if !BrandStore.shared.current.supportsDark { return .light }
        return switch RunController.launchArgument("-theme") {
        case "light": .light
        case "dark": .dark
        default: theme.scheme
        }
    }

    static var allAccounts: [URL?] { [nil] + RunController.configDirectories.map { $0 } }

    func visibleAccounts(including selected: URL?) -> [URL?] {
        let accounts = Self.allAccounts
        let visible = accounts.filter { $0 == selected || !hiddenAccounts.contains(UsageStore.key($0)) }
        return visible.contains(selected) ? visible : visible + [selected]
    }

    func isShown(_ account: URL?) -> Binding<Bool> {
        let id = UsageStore.key(account)
        return Binding(get: { !self.hiddenAccounts.contains(id) },
                       set: { if $0 { self.hiddenAccounts.remove(id) } else { self.hiddenAccounts.insert(id) } })
    }

    static func accountName(_ directory: URL?) -> String {
        guard let name = directory?.lastPathComponent, name.hasPrefix(".claude-") else { return "Default" }
        return name.dropFirst(".claude-".count).split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}

struct SettingsView: View {
    @Bindable var preferences = Preferences.shared
    @Bindable var brands = BrandStore.shared
    let city: CityStore

    private func importBrand() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a brand folder containing brand.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try brands.importBrand(from: url) } catch {
            NSAlert(error: error).runModal()
        }
    }

    var body: some View {
        Form {
            Section("New jobs start with") {
                Picker("Account", selection: $preferences.configDirectory) {
                    ForEach(preferences.visibleAccounts(including: preferences.configDirectory), id: \.self) { url in
                        Text(Preferences.accountName(url)).tag(url)
                    }
                }
                Picker("Model", selection: $preferences.model) {
                    Text("Default").tag(String?.none)
                    ForEach(city.allSessions.first?.primaryModels ?? []) { model in
                        Text(model.displayName).tag(String?.some(model.value))
                    }
                }
                Picker("Budget", selection: $preferences.budgetUSD) {
                    ForEach(RunController.budgets, id: \.self) { budget in
                        Text(budget.formatted(.currency(code: "USD"))).tag(budget)
                    }
                }
                Picker("Permissions", selection: $preferences.permissionMode) {
                    ForEach(PermissionMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Text(preferences.permissionMode.detail).font(.caption).foregroundStyle(Color(Palette.muted))
            }
            if Preferences.allAccounts.count > 1 {
                Section {
                    ForEach(Preferences.allAccounts, id: \.self) { url in
                        let starts = url == preferences.configDirectory
                        Toggle(isOn: starts ? .constant(true) : preferences.isShown(url)) {
                            Text(Preferences.accountName(url))
                            Text(((url?.path ?? "~/.claude") as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(Color(Palette.muted))
                            if starts {
                                Text("Starts new jobs, so it stays shown.").font(.caption).foregroundStyle(Color(Palette.muted))
                            }
                        }
                        .disabled(starts)
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Hidden accounts don’t appear in the usage gauges or the Account menu, and aren’t refreshed.")
                        .font(.caption).foregroundStyle(Color(Palette.muted))
                }
            }
            Section("Branding") {
                Picker("Brand", selection: $brands.selectedID) {
                    ForEach(brands.brands) { brand in Text(brand.name).tag(brand.id) }
                }
                if let notes = brands.current.notes {
                    Text(notes).font(.caption).foregroundStyle(Color(Palette.muted))
                }
                HStack {
                    Button("Import Brand…") { importBrand() }
                    Button("Open Brands Folder") {
                        try? FileManager.default.createDirectory(at: BrandStore.customFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(BrandStore.customFolder)
                    }
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(Preferences.Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!brands.current.supportsDark)
                if !brands.current.supportsDark {
                    Text("\(brands.current.name) has a light theme only.").font(.caption).foregroundStyle(Color(Palette.muted))
                }
            }
            Section("Alerts") {
                Toggle("Notify me when the office needs me or a job finishes", isOn: $preferences.notifications)
                Toggle("Play sounds", isOn: $preferences.sounds)
                Slider(value: $preferences.soundVolume, in: 0...1) { Text("Volume") }
                    .disabled(!preferences.sounds)
            }
            Section("Claude Code") {
                LabeledContent("Command-line tool") {
                    Text(preferences.cliPath ?? "Found automatically").foregroundStyle(Color(Palette.muted))
                }
                HStack {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { preferences.cliPath = url.path }
                        city.allSessions.forEach { $0.checkReadiness() }
                    }
                    if preferences.cliPath != nil {
                        Button("Use Default") {
                            preferences.cliPath = nil
                            city.allSessions.forEach { $0.checkReadiness() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
