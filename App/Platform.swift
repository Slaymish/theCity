import Foundation

/// A value passed on the command line as `-name value`, for renders, replays and tests.
enum LaunchArgument {
    static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}

#if os(iOS)
import UIKit

// The scene code is shared with the iPhone app and written against AppKit's names; these map them onto UIKit.
typealias NSColor = UIColor
typealias NSFont = UIFont
typealias NSImage = UIImage

extension UIColor {
    enum ColourSpace { case sRGB }

    convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// UIKit colours are already in extended sRGB, so there is nothing to convert.
    func usingColorSpace(_ space: ColourSpace) -> UIColor? { self }

    private var rgba: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    var redComponent: CGFloat { rgba.red }
    var greenComponent: CGFloat { rgba.green }
    var blueComponent: CGFloat { rgba.blue }

    func blended(withFraction fraction: CGFloat, of other: UIColor) -> UIColor? {
        let a = rgba, b = other.rgba
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * fraction }
        return UIColor(red: mix(a.red, b.red), green: mix(a.green, b.green), blue: mix(a.blue, b.blue), alpha: mix(a.alpha, b.alpha))
    }
}

extension UIImage {
    convenience init?(contentsOf url: URL) {
        self.init(contentsOfFile: url.path)
    }
}
#endif
