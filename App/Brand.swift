#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation

/// A white-label theme: everything the city, offices and UI take their colours, type and name from.
struct Brand: Codable, Identifiable, Equatable {
    struct Tokens: Codable, Equatable {
        var background: String
        var panel: String
        var panelEdge: String
        var text: String
        var muted: String
        var primaryFill: String
        var primaryText: String
        var floor: String
        var walls: String
        var screen: String
        var screenPixels: String
        var robot: String
        var desk: String
        var lamp: String
        var folder: String
        var error: String
        var tray: String
        var grass: String?
        var cloud: String?
    }

    /// Scene lighting that follows the clock rather than the appearance; optional so a brand can fall back to The City's.
    struct Sky: Codable, Equatable {
        var moonlight: String
        var dusk: String
        var streetlight: String
        var nightSky: String
        var duskSky: String
    }

    struct Font: Codable, Equatable {
        var family: String
        var file: String?
    }

    var id: String
    var name: String
    var wordmarkSymbol: String?
    var logo: String?
    var font: Font?
    var light: Tokens
    var dark: Tokens?
    var sky: Sky?
    var departments: [String]
    var manager: String
    var onAccent: String
    /// Set when the brand's owner hasn't supplied some values yet; shown in Settings.
    var notes: String?

    var folder: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, wordmarkSymbol, logo, font, light, dark, sky, departments, manager, onAccent, notes
    }

    var supportsDark: Bool { dark != nil }

    func tokens(dark wantsDark: Bool) -> Tokens {
        var tokens = wantsDark ? (dark ?? light) : light
        if tokens.grass == nil { tokens.grass = wantsDark && dark != nil ? Self.defaultGrass.dark : Self.defaultGrass.light }
        if tokens.cloud == nil { tokens.cloud = wantsDark && dark != nil ? Self.defaultCloud.dark : Self.defaultCloud.light }
        return tokens
    }

    static let defaultGrass = (light: "#BFE3A0", dark: "#5E7A4F")
    static let defaultCloud = (light: "#FFFFFF", dark: "#D9D4E6")
    static let defaultSky = Sky(moonlight: "#9DB4E8", dusk: "#FFB070", streetlight: "#FFC46B", nightSky: "#1A1F3D", duskSky: "#F2A88C")

    var logoImage: NSImage? {
        guard let logo, let folder else { return nil }
        return NSImage(contentsOf: folder.appendingPathComponent(logo))
    }
}

@MainActor
@Observable
final class BrandStore {
    static let shared = BrandStore()

    private(set) var brands: [Brand] = []
    private(set) var current: Brand
    var selectedID: String {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "brand")
            current = brands.first { $0.id == selectedID } ?? current
            Typography.register(brand: current)
        }
    }

    static var customFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("The City/Brands")
    }

    private init() {
        let loaded = Self.load()
        brands = loaded
        let saved = UserDefaults.standard.string(forKey: "brand") ?? "the-city"
        selectedID = saved
        current = loaded.first { $0.id == saved } ?? loaded.first { $0.id == "the-city" } ?? loaded[0]
        Typography.register(brand: current)
    }

    func reload() {
        brands = Self.load()
        current = brands.first { $0.id == selectedID } ?? brands[0]
        Typography.register(brand: current)
    }

    /// Copies a brand folder (brand.json plus any logo and font files) into the brands folder.
    func importBrand(from folder: URL) throws {
        let target = Self.customFolder.appendingPathComponent(folder.lastPathComponent)
        try FileManager.default.createDirectory(at: Self.customFolder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: folder, to: target)
        reload()
        if let brand = Self.read(target) { selectedID = brand.id }
    }

    private static func load() -> [Brand] {
        var folders: [URL] = []
        if let builtIn = Bundle.main.resourceURL?.appendingPathComponent("Brands"),
           let entries = try? FileManager.default.contentsOfDirectory(at: builtIn, includingPropertiesForKeys: nil) {
            folders += entries
        }
        if let entries = try? FileManager.default.contentsOfDirectory(at: customFolder, includingPropertiesForKeys: nil) {
            folders += entries
        }
        let brands = folders.compactMap(read)
        return brands.isEmpty ? [Brand.fallback] : brands.sorted { ($0.id == "the-city" ? 0 : 1, $0.name) < ($1.id == "the-city" ? 0 : 1, $1.name) }
    }

    private static func read(_ folder: URL) -> Brand? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("brand.json")),
              var brand = try? JSONDecoder().decode(Brand.self, from: data) else { return nil }
        brand.folder = folder
        return brand
    }
}

extension Brand {
    /// Only used if the bundled brand files can't be read; mirrors `Brands/the-city/brand.json`.
    static let fallback = Brand(
        id: "the-city", name: "The City", wordmarkSymbol: "building.2.fill", logo: nil,
        font: .init(family: "Fredoka", file: nil),
        light: .init(background: "#DCEEFB", panel: "#FFFDF7", panelEdge: "#EADFCB", text: "#3B2F2A", muted: "#7A6A60",
                     primaryFill: "#F2C14E", primaryText: "#3B2F2A", floor: "#E8CFA8", walls: "#F6EEDF",
                     screen: "#2D3A36", screenPixels: "#B6F26B", robot: "#F5F2F8", desk: "#CC9E73", lamp: "#FFDB9E",
                     folder: "#FAC740", error: "#E54D4D", tray: "#4D5266", grass: "#BFE3A0", cloud: "#FFFFFF"),
        dark: nil, sky: defaultSky, departments: ["#F2836B", "#7DBB5E", "#F2C14E", "#5A7BD8"], manager: "#C9557A", onAccent: "#3B2F2A",
        notes: nil, folder: nil)
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        let hasAlpha = hex.count > 7
        let rgba = hasAlpha ? value : (value << 8) | 0xFF
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
}
