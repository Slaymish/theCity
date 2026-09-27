import AppKit
import CoreText
import SwiftUI

enum Palette {
    private static var brand: Brand { MainActor.assumeIsolated { BrandStore.shared.current } }

    private static func token(_ pick: @escaping (Brand.Tokens) -> String) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: pick(brand.tokens(dark: dark)))
        }
    }

    static var background: NSColor { token(\.background) }
    static var text: NSColor { token(\.text) }
    static var muted: NSColor { token(\.muted) }
    static var glassTop: NSColor { token(\.panel) }
    static var glassBottom: NSColor { token(\.panel) }
    static var hairline: NSColor { token(\.panelEdge) }
    static var primaryFill: NSColor { token(\.primaryFill) }
    static var primaryText: NSColor { token(\.primaryText) }
    static var onAccent: NSColor { NSColor(hex: brand.onAccent) }
    static var manager: NSColor { NSColor(hex: brand.manager) }
    static var departments: [NSColor] { brand.departments.map { NSColor(hex: $0) } }

    static var sceneFloor: NSColor { token(\.floor) }
    static var walls: NSColor { token(\.walls) }
    static var desk: NSColor { token(\.desk) }
    static var robot: NSColor { token(\.robot) }
    static var screenOff: NSColor { token(\.screen) }
    static var screenOn: NSColor { token(\.screenPixels) }
    static var lamp: NSColor { token(\.lamp) }
    static var folder: NSColor { token(\.folder) }
    static var error: NSColor { token(\.error) }
    static var tray: NSColor { token(\.tray) }
    static var grass: NSColor { token { $0.grass ?? Brand.defaultGrass.light } }
    static var facadeBrick: NSColor { pair(light: "#B5654A", dark: "#7A4434") }
    static var facadeStone: NSColor { pair(light: "#E6DFD2", dark: "#8F897E") }
    static var facadeConcrete: NSColor { pair(light: "#C9C7C2", dark: "#6E6D6A") }
    static var glazing: NSColor { pair(light: "#8FB4CC", dark: "#2E4150") }
    static var mullion: NSColor { pair(light: "#4A5059", dark: "#2B2F35") }

    private static func pair(light: String, dark: String) -> NSColor {
        NSColor(name: nil) { NSColor(hex: $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light) }
    }

    static func textOn(_ fill: NSColor) -> NSColor {
        fill.isEqual(muted) || resolved(fill, dark: false) == resolved(muted, dark: false) ? background : onAccent
    }

    static func accent(forHireIndex index: Int) -> NSColor {
        let colours = departments
        return colours[index % max(colours.count, 1)]
    }

    static func resolved(_ colour: NSColor, dark: Bool) -> NSColor {
        var result = colour
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = colour.usingColorSpace(.sRGB) ?? colour
        }
        return result
    }
}

extension Color {
    init(_ token: NSColor) { self.init(nsColor: token) }
}

enum Typography {
    @MainActor private static var registered: Set<URL> = []

    @MainActor static func register(brand: Brand) {
        var urls: [URL] = []
        if let file = brand.font?.file {
            if let url = brand.folder?.appendingPathComponent(file), FileManager.default.fileExists(atPath: url.path) {
                urls.append(url)
            } else if let url = Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: (file as NSString).pathExtension) {
                urls.append(url)
            }
        }
        let fresh = urls.filter { !registered.contains($0) }
        guard !fresh.isEmpty else { return }
        registered.formUnion(fresh)
        CTFontManagerRegisterFontURLs(fresh as CFArray, .process, true, nil)
    }

    private static var family: String? { MainActor.assumeIsolated { BrandStore.shared.current.font?.family } }

    /// Brand fonts are variable, so weight goes on the `wght` axis; without a brand font, the system font is used.
    static func ui(_ size: CGFloat, weight: CGFloat) -> Font {
        guard let family else { return .system(size: size, weight: systemWeight(weight)) }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
            kCTFontVariationAttribute: [0x7767_6874 as UInt32: weight],
        ] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }

    static func nsUI(_ size: CGFloat, weight: CGFloat) -> NSFont {
        guard let family else { return .systemFont(ofSize: size, weight: .init(rawValue: (weight - 400) / 500)) }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
            kCTFontVariationAttribute: [0x7767_6874 as UInt32: weight],
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    private static func systemWeight(_ weight: CGFloat) -> Font.Weight {
        switch weight {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        default: .heavy
        }
    }

    static func outfit(_ size: CGFloat, weight: CGFloat) -> Font { ui(size, weight: weight) }

    static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
        .system(size: size, weight: medium ? .medium : .regular, design: .monospaced)
    }

    static var titleSmall: Font { ui(20, weight: 700) }
    static var titleLarge: Font { ui(39, weight: 700) }
    static var body: Font { ui(16, weight: 400) }
    static var bodyMedium: Font { ui(16, weight: 500) }
    static var control: Font { ui(13, weight: 600) }
    static var controlQuiet: Font { ui(13, weight: 500) }
    static var caption: Font { ui(12.5, weight: 400) }
    static var captionMedium: Font { ui(12.5, weight: 500) }
    static var eyebrow: Font { ui(10.5, weight: 600) }
    static var number: Font { ui(13, weight: 600).monospacedDigit() }
    static var code: Font { mono(12.5) }
}

struct Glass: ViewModifier {
    var radius: CGFloat = 16
    var padding: EdgeInsets = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color(Palette.hairline), lineWidth: 1))
    }
}

extension View {
    func glass(radius: CGFloat = 16, padding: CGFloat = 12) -> some View {
        modifier(Glass(radius: radius, padding: EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)))
    }

    func eyebrow() -> some View {
        font(Typography.eyebrow).tracking(1.4).textCase(.uppercase).foregroundStyle(Color(Palette.muted))
    }
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, accent(NSColor), tab(active: Bool) }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(kind.isPrimary ? Typography.control : Typography.controlQuiet)
            .foregroundStyle(foreground)
            .padding(.vertical, 8)
            .padding(.horizontal, 15)
            .background(Capsule().fill(fill))
            .overlay { if case .secondary = kind { Capsule().strokeBorder(Color(Palette.hairline), lineWidth: 1) } }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }

    private var fill: Color {
        if !isEnabled { return Color(Palette.hairline) }
        return switch kind {
        case .primary, .tab(active: true): Color(Palette.primaryFill)
        case .secondary, .tab(active: false): .clear
        case .accent(let colour): Color(colour)
        }
    }

    private var foreground: Color {
        if !isEnabled { return Color(Palette.muted) }
        return switch kind {
        case .primary, .tab(active: true): Color(Palette.primaryText)
        case .secondary: Color(Palette.text)
        case .tab(active: false): Color(Palette.muted)
        case .accent: Color(Palette.onAccent)
        }
    }
}

private extension PillButtonStyle.Kind {
    var isPrimary: Bool {
        switch self {
        case .secondary, .tab(active: false): false
        default: true
        }
    }
}
