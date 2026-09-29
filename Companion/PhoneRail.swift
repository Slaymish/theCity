import OfficeCore
import SwiftUI

extension FloorSnapshot {
    /// The same rule as the Mac's `CityStore.signal(of:)`, through the same function.
    var signal: FloorSignal {
        .of(pending: questions.count, unseen: unseen == true, outcome: outcome, running: isRunning, queued: queued ?? 0)
    }

    /// When the oldest question arrived, or for ready and failed floors when the job finished.
    var since: Date? {
        switch signal {
        case .blocked: questions.compactMap(\.since).min()
        case .failed, .ready: unseenSince
        default: nil
        }
    }
}

extension BuildingSnapshot {
    /// The building's highest-priority state, and how many of that state, as the Mac counts them.
    var signal: (signal: FloorSignal, count: Int, since: Date?) {
        guard let top = floors.map(\.signal).min() else { return (.quiet, 0, nil) }
        let matching = floors.filter { $0.signal == top }
        let count = top == .blocked ? matching.reduce(0) { $0 + $1.questions.count } : matching.count
        return (top, count, matching.compactMap(\.since).min())
    }
}

extension CitySnapshot {
    struct NeedsYou {
        var building: BuildingSnapshot
        var floor: FloorSnapshot
    }

    /// Blocked, then failed, then ready, and within a state the longest-waiting first, as on the Mac.
    var floorsNeedingYou: [NeedsYou] {
        buildings.flatMap { building in building.floors.map { NeedsYou(building: building, floor: $0) } }
            .enumerated()
            .filter { $0.element.floor.signal.needsAPerson }
            .sorted { ($0.element.floor.signal, $0.element.floor.since ?? .distantFuture, $0.offset)
                < ($1.element.floor.signal, $1.element.floor.since ?? .distantFuture, $1.offset) }
            .map(\.element)
    }
}

/// The Mac's dispatch rail on the phone: every other floor that needs you, as one scrolling row above the banner.
struct PhoneRail: View {
    let snapshot: CitySnapshot?
    let building: UUID?
    let floor: UUID?
    let go: (BuildingSnapshot, FloorSnapshot) -> Void

    var body: some View {
        let items = (snapshot?.floorsNeedingYou ?? []).filter { $0.floor.id != floor }
        if !items.isEmpty {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(items, id: \.floor.id) { chip($0, now: context.date) }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Needs you")
        }
    }

    private func chip(_ item: CitySnapshot.NeedsYou, now: Date) -> some View {
        let signal = item.floor.signal
        let since = item.floor.since
        let escalated = signal == .blocked && since.map { now.timeIntervalSince($0) >= FloorSignal.escalateAfter } == true
        let name = item.building.id == building ? item.floor.name : "\(item.building.displayName) · \(item.floor.name)"
        let age = since.flatMap { now.timeIntervalSince($0) >= FloorSignal.ageAppearsAfter ? FloorSignal.age(from: $0, to: now) : nil }
        return Button { go(item.building, item.floor) } label: {
            HStack(spacing: 6) {
                Image(systemName: signal.symbol)
                Text(name).lineLimit(1)
                if escalated {
                    Text("\(Int(FloorSignal.escalateAfter / 60))m+")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(Palette.textOn(signal.colour)))
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(Color(signal.colour)))
                } else if let age {
                    Text(age).font(.caption).monospacedDigit()
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .modifier(RailChipStyle(signal: signal, escalated: escalated))
        .accessibilityLabel("\(item.building.displayName), \(item.floor.name), \(signal.label(count: item.floor.questions.count))\(signal.spokenAge(since: since, now: now))")
    }
}

/// A filled glass chip in the signal's colour, or once a request has waited too long an outlined one, as on the Mac.
private struct RailChipStyle: ViewModifier {
    let signal: FloorSignal
    let escalated: Bool

    func body(content: Content) -> some View {
        if escalated {
            content
                .buttonStyle(.glass)
                .overlay(Capsule().strokeBorder(Color(signal.colour), lineWidth: 2))
        } else {
            content
                .buttonStyle(.glassProminent)
                .tint(Color(signal.colour))
                .foregroundStyle(Color(Palette.textOn(signal.colour)))
        }
    }
}
