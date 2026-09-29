import AppKit

/// What a floor, building or the whole city is telling the user, in the order it matters.
/// Every place that shows status derives it from here, so a state has one name, symbol and colour everywhere.
enum FloorSignal: Int, Comparable, CaseIterable {
    case blocked, failed, ready, working, queued, quiet

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Only blocked and failed floors want action; ready is a soft prompt that can wait.
    var needsAPerson: Bool { self <= .ready }

    static func of(pending: Int, unseen: Bool, outcome: String?, running: Bool, queued: Int) -> FloorSignal {
        if pending > 0 { return .blocked }
        if unseen { return outcome == "failed" ? .failed : .ready }
        if running { return .working }
        return queued > 0 ? .queued : .quiet
    }

    var symbol: String {
        switch self {
        case .blocked: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .ready: "tray.full.fill"
        case .working: "bolt.fill"
        case .queued: "clock.fill"
        case .quiet: "moon.zzz.fill"
        }
    }

    var colour: NSColor {
        switch self {
        case .blocked: Palette.manager
        case .failed: Palette.error
        case .ready: Palette.primaryFill
        case .working: Palette.folder
        case .queued, .quiet: Palette.muted
        }
    }

    func label(count: Int = 1) -> String {
        switch self {
        case .blocked: count > 1 ? "\(count) waiting" : "Waiting"
        case .failed: "Failed"
        case .ready: "Ready"
        case .working: "Working"
        case .queued: "Queued"
        case .quiet: "Quiet"
        }
    }
}
