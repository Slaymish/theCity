import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let mine = list.filter { ($0[kCGWindowOwnerName as String] as? String) == "The City" && ($0[kCGWindowLayer as String] as? Int) == 0 }
let big = mine.max { (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) < (($1[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) }
if let big, ((big[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 300 { print(big[kCGWindowNumber as String]!) }
