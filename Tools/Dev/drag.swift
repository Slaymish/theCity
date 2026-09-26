import CoreGraphics
import Foundation
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
let start = CGPoint(x: a[0], y: a[1]), end = CGPoint(x: a[2], y: a[3])
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
post(.leftMouseDown, start)
for i in 1...30 {
    let t = Double(i) / 30
    post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
    usleep(12000)
}
post(.leftMouseUp, end)
