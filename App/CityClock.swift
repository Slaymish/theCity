import Observation
import SwiftUI

/// A session-only override; every launch starts at the user's local time.
@MainActor @Observable
final class CityClock {
    static let shared = CityClock()
    var hour: Double?
    var revision = 0

    func set(_ value: Double?) {
        hour = value.map { min(max($0, 0), 24) }
        revision += 1
    }
}

struct DaylightDial: View {
    private var clock: CityClock { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: DayCycle.tick)) { _ in
            HStack(spacing: 8) {
                Image(systemName: "moon.fill").foregroundStyle(Color(Palette.primaryFill))
                Slider(value: Binding(get: { clock.hour ?? DayCycle.now.hour }, set: { clock.set($0) }), in: 0...24)
                    .tint(Color(Palette.primaryFill))
                    .background {
                        Capsule().fill(LinearGradient(colors: [Color(Palette.nightSky), Color(Palette.dawnSky), Color(Palette.primaryFill), Color(Palette.duskSky), Color(Palette.nightSky)], startPoint: .leading, endPoint: .trailing)).frame(height: 6)
                    }
                    .frame(width: 160)
                    .accessibilityLabel("City time of day")
                    .accessibilityValue(time)
                Image(systemName: "moon.stars.fill").foregroundStyle(Color(Palette.manager))
                Text(time).font(Typography.caption).monospacedDigit()
                Button("Local time") { clock.set(nil) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(clock.hour == nil)
            }
            .glass(padding: 12)
            .sheltersScroll()
        }
    }

    private var time: String {
        let minutes = Int((clock.hour ?? DayCycle.now.hour) * 60) % 1440
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
