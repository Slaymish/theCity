import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    print(w[kCGWindowNumber as String]!, w[kCGWindowOwnerName as String] ?? "?", w[kCGWindowName as String] ?? "-", w[kCGWindowBounds as String]!, "on:", w[kCGWindowIsOnscreen as String] ?? false, "layer:", w[kCGWindowLayer as String]!)
}
