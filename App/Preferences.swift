import AppKit
import FoundationModels
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

    enum MenuBarIcon: String, CaseIterable, Identifiable {
        case whenWindowClosed, always
        var id: String { rawValue }
        var title: String {
            switch self {
            case .whenWindowClosed: "When the window is closed"
            case .always: "Always"
            }
        }
    }

    enum Receptionist: String, CaseIterable, Identifiable {
        case onDevice, claude
        var id: String { rawValue }
        var title: String {
            switch self {
            case .onDevice: "Apple Intelligence"
            case .claude: "Claude Haiku"
            }
        }
    }

    static let shared = Preferences()
    private let defaults = UserDefaults.app

    var provider: AgentProvider {
        didSet { defaults.set(provider.rawValue, forKey: "agentProvider") }
    }
    var codexCLIPath: String? {
        didSet { defaults.set(codexCLIPath, forKey: "codexCLIPath") }
    }
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
    var dictationModel: String? {
        didSet { defaults.set(dictationModel, forKey: "dictationModel") }
    }
    var menuBarIcon: MenuBarIcon {
        didSet { defaults.set(menuBarIcon.rawValue, forKey: "menuBarIcon") }
    }
    var receptionist: Receptionist {
        didSet { defaults.set(receptionist.rawValue, forKey: "receptionist") }
    }
    var graphics: GraphicsQuality? {
        didSet { defaults.set(graphics?.rawValue, forKey: "graphics") }
    }

    private init() {
        provider = AgentProvider(rawValue: RunController.launchArgument("-provider") ?? defaults.string(forKey: "agentProvider") ?? "") ?? .claude
        codexCLIPath = defaults.string(forKey: "codexCLIPath")
        configDirectory = defaults.string(forKey: "configDirectory").map { URL(fileURLWithPath: $0) }
            ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        model = defaults.string(forKey: "model")
        budgetUSD = defaults.object(forKey: "budgetUSD") as? Double ?? 5.0
        permissionMode = PermissionMode(rawValue: defaults.string(forKey: "permissionMode") ?? "") ?? .manual
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        notifications = defaults.object(forKey: "notifications") as? Bool ?? true
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.7
        cliPath = defaults.string(forKey: "cliPath")
        editorPath = defaults.string(forKey: "editorPath")
        hiddenAccounts = Set(defaults.stringArray(forKey: "hiddenAccounts") ?? [])
        dictationModel = defaults.string(forKey: "dictationModel")
        menuBarIcon = MenuBarIcon(rawValue: defaults.string(forKey: "menuBarIcon") ?? "") ?? .whenWindowClosed
        graphics = (defaults.object(forKey: "graphics") as? Int).flatMap(GraphicsQuality.init(rawValue:))
        receptionist = Receptionist(rawValue: RunController.launchArgument("-receptionist") ?? defaults.string(forKey: "receptionist") ?? "") ?? .onDevice
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

    static func addAccount() {
        let alert = NSAlert()
        alert.messageText = "Add a Claude Account"
        alert.informativeText = "Name the account, for example Work. Terminal opens so you can sign in, then the account appears here."
        let field = NSTextField(string: "")
        field.placeholderString = "Work"
        field.sizeToFit()
        field.frame.size.width = 240
        alert.accessoryView = field
        alert.addButton(withTitle: "Sign In…")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let slug = field.stringValue.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
        guard !slug.isEmpty else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-\(slug)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        RunController.signIn(configDirectory: directory)
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
    @State private var accountsRefresh = 0
    @State private var loadedModels: [ModelOption] = []

    private var models: [ModelOption] {
        let open = city.allSessions.first?.primaryModels ?? []
        return open.isEmpty ? loadedModels : open
    }

    private var receptionNote: String {
        switch preferences.receptionist {
        case .onDevice:
            guard case .available = SystemLanguageModel.default.availability else {
                return "Apple Intelligence isn’t available on this Mac, so you’ll choose floors and departments yourself. Switch to Claude Haiku to have Reception choose for you."
            }
            return "Reception chooses floors and departments on this Mac, at no cost."
        case .claude:
            return "Each request asks Claude Haiku on your \(Preferences.accountName(preferences.configDirectory)) account and counts towards its usage limits."
        }
    }

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
        TabView {
            page {
                Section("New jobs start with") {
                    Picker("Agent", selection: $preferences.provider) {
                        ForEach(AgentProvider.allCases) { Text($0.title).tag($0) }
                    }
                    if preferences.provider == .claude {
                        Picker("Account", selection: $preferences.configDirectory) {
                            ForEach(preferences.visibleAccounts(including: preferences.configDirectory), id: \.self) { url in
                                Text(Preferences.accountName(url)).tag(url)
                            }
                        }
                        Picker("Model", selection: $preferences.model) {
                            Text("Default").tag(String?.none)
                            ForEach(models) { model in
                                Text(model.displayName).tag(String?.some(model.value))
                            }
                        }
                        .task(id: preferences.configDirectory) {
                            guard city.allSessions.first?.primaryModels.isEmpty != false else { return }
                            loadedModels = await RunController.models(configDirectory: preferences.configDirectory)
                        }
                        Picker("Budget", selection: $preferences.budgetUSD) {
                            ForEach(RunController.budgets, id: \.self) { budget in
                                Text(budget.formatted(.currency(code: "USD"))).tag(budget)
                            }
                        }
                    } else {
                        Text("Codex uses its configured default model and account. It has no dollar budget cap.")
                            .font(.caption).foregroundStyle(Color(Palette.muted))
                    }
                    Picker("Permissions", selection: $preferences.permissionMode) {
                        ForEach(PermissionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Text(preferences.provider.permissionDetail(preferences.permissionMode)).font(.caption).foregroundStyle(Color(Palette.muted))
                }
                Section {
                    Picker("Routes and hires with", selection: $preferences.receptionist) {
                        ForEach(Preferences.Receptionist.allCases) { option in Text(option.title).tag(option) }
                    }
                } header: {
                    Text("Reception")
                } footer: {
                    Text(receptionNote).font(.caption).foregroundStyle(Color(Palette.muted))
                }
                Section("Codex") {
                    LabeledContent("Command-line tool", value: preferences.codexCLIPath ?? "Found automatically")
                    Button("Choose Codex…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { preferences.codexCLIPath = url.path }
                        city.allSessions.forEach { $0.checkReadiness() }
                    }
                    if preferences.codexCLIPath != nil {
                        Button("Use Default") {
                            preferences.codexCLIPath = nil
                            city.allSessions.forEach { $0.checkReadiness() }
                        }
                    }
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
                Section {
                    Picker("Show in menu bar", selection: $preferences.menuBarIcon) {
                        ForEach(Preferences.MenuBarIcon.allCases) { option in Text(option.title).tag(option) }
                    }
                } header: {
                    Text("Menu bar")
                } footer: {
                    Text("When you close the window, The City keeps running from the menu bar and leaves the Dock.")
                        .font(.caption).foregroundStyle(Color(Palette.muted))
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }
            page {
                let _ = accountsRefresh
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
                Section {
                    Button("Add Account…") { Preferences.addAccount() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                accountsRefresh += 1
            }
            .tabItem { Label("Accounts", systemImage: "person.2") }
            page {
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
                Section("Graphics") {
                    let quality = preferences.graphics ?? GraphicsQuality.recommended
                    Slider(value: Binding(get: { Double(quality.rawValue) },
                                          set: { preferences.graphics = GraphicsQuality(rawValue: Int($0.rounded())) }),
                           in: 0...Double(GraphicsQuality.allCases.count - 1), step: 1) {
                        Text("Quality")
                    } minimumValueLabel: {
                        Text(GraphicsQuality.low.title)
                    } maximumValueLabel: {
                        Text(GraphicsQuality.ultra.title)
                    }
                    Text("\(quality.title)\(preferences.graphics == nil ? " (recommended for this Mac)" : ""): \(quality.detail)")
                        .font(.caption).foregroundStyle(Color(Palette.muted))
                    if preferences.graphics != nil {
                        Button("Use Recommended") { preferences.graphics = nil }
                    }
                }
            }
            .tabItem { Label("Appearance", systemImage: "paintbrush") }
            page {
                Section("Alerts") {
                    Toggle("Notify me when the office needs me or a job finishes", isOn: $preferences.notifications)
                    Toggle("Play sounds", isOn: $preferences.sounds)
                    Slider(value: $preferences.soundVolume, in: 0...1) { Text("Volume") }
                        .disabled(!preferences.sounds)
                }
            }
            .tabItem { Label("Alerts", systemImage: "bell") }
            page { DictationSettings() }
                .tabItem { Label("Dictation", systemImage: "mic") }
            page { CompanionSettings() }
                .tabItem { Label("iPhone", systemImage: "iphone") }
            page {
                Section("Updates") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Button("Check for Updates…") { Updater.shared.controller.checkForUpdates(nil) }
                }
            }
            .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
    }

    private func page(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}
