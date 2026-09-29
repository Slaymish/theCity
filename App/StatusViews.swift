import AppKit
import OfficeCore
import SwiftUI

struct Vitals: Equatable {
    var rooms = RoomCounts()
    var running = false
    var liveSpendUSD: Double = 0
    var liveTokens = 0
    var summary = JobSummary()
    var onPlan = false
}

enum StatusFormat {
    static func tokens(_ count: Int) -> String { count.formatted(.number.notation(.compactName)) }

    static func dollars(_ amount: Double, onPlan: Bool = false) -> String {
        amount.formatted(.currency(code: "USD")) + (onPlan ? " API-equivalent" : "")
    }

    /// On a plan that isn't using extra usage, dollars are only what the API would have charged.
    @MainActor static func isOnPlan(_ limit: RateLimit?, configDirectory: URL?) -> Bool {
        if let limit, !limit.windows.isEmpty { return !limit.isUsingOverage && limit.windows["five_hour"] != nil }
        return UsageStore.shared.reading(configDirectory)?.session != nil
    }

    static func percent(_ fraction: Double) -> String { fraction.formatted(.percent.precision(.fractionLength(0))) }

    /// On a plan, dollars are only what the API would have charged, so tokens lead.
    static func spend(_ usd: Double, tokens count: Int, onPlan: Bool) -> String {
        onPlan ? "\(tokens(count)) tokens" : dollars(usd)
    }

    static func jobs(_ count: Int) -> String { "\(count) job\(count == 1 ? "" : "s")" }
}

struct RoomTally: View {
    let counts: RoomCounts

    var body: some View {
        let shown = RoomState.allCases.filter { counts.count($0) > 0 }
        HStack(spacing: 8) {
            if shown.isEmpty { Text("–").font(Typography.number).foregroundStyle(Color(Palette.muted)) }
            ForEach(shown, id: \.self) { state in
                HStack(spacing: 4) {
                    Image(systemName: state.symbol)
                        .font(Typography.captionMedium)
                        .foregroundStyle(Color(state.colour))
                        .symbolEffect(.pulse, isActive: state == .waiting && !OfficeScene.reduceMotion)
                    Text("\(counts.count(state))")
                        .font(Typography.number)
                        .contentTransition(.numericText())
                }
            }
        }
        .animation(OfficeScene.reduceMotion ? nil : .default, value: counts)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(counts.spoken)
    }
}

struct StatBlock: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).eyebrow()
            Text(value)
                .font(Typography.number)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

enum LedgerScope {
    case city([CityStore.Building])
    case building(CityStore.Building)

    var floors: [CityStore.Floor] {
        switch self {
        case .city(let buildings): buildings.flatMap(\.floors)
        case .building(let building): building.floors
        }
    }

    var title: String {
        switch self {
        case .city: "City"
        case .building(let building): building.name
        }
    }
}

struct LedgerView: View {
    let city: CityStore
    let scope: LedgerScope
    var dismiss: () -> Void = {}

    private struct Row: Identifiable {
        let id: UUID
        let name: String
        let floors: [CityStore.Floor]
        let route: CityStore.Route
    }

    private var rows: [Row] {
        switch scope {
        case .city(let buildings):
            buildings.filter { !$0.floors.isEmpty }.map { Row(id: $0.id, name: $0.name, floors: $0.floors, route: .building($0.id)) }
        case .building(let building):
            building.floors.reversed().map { Row(id: $0.id, name: $0.name, floors: [$0], route: .floor(building: building.id, floor: $0.id)) }
        }
    }

    var body: some View {
        let vitals = city.vitals(on: scope.floors)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(scope.title) ledger").eyebrow()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text(scopeNoun).eyebrow()
                    Text("Rooms").eyebrow()
                    Text("Today").eyebrow()
                    Text("Success").eyebrow()
                    Text("Avg job").eyebrow()
                }
                ForEach(rows) { row in
                    let summary = city.jobSummary(on: row.floors)
                    GridRow {
                        Button(row.name) {
                            city.route = row.route
                            dismiss()
                        }
                        .buttonStyle(.plain)
                        .font(Typography.captionMedium)
                        .lineLimit(1)
                        RoomTally(counts: city.live(on: row.floors).rooms)
                        Text("\(summary.today) · \(StatusFormat.spend(summary.todaySpendUSD, tokens: summary.todayTokens, onPlan: vitals.onPlan))")
                        Text(summary.totals.successRate.map(StatusFormat.percent) ?? "–")
                        Text(summary.totals.jobs > 0 ? RunController.clock(summary.totals.averageDuration) : "–")
                    }
                    .font(Typography.number)
                    .accessibilityElement(children: .combine)
                }
            }
            Divider()
            let totals = vitals.summary.totals
            Text(totals.jobs == 0 ? "No finished jobs yet."
                 : "All time: \(StatusFormat.jobs(totals.jobs)) · \(city.dollars(totals.spendUSD)) · \(StatusFormat.tokens(totals.tokens)) tokens")
                .font(Typography.caption)
                .foregroundStyle(Color(Palette.muted))
            TrendBars(days: city.jobsByDay(on: scope.floors))
        }
        .fixedSize()
    }

    private var scopeNoun: String {
        if case .city = scope { "Building" } else { "Floor" }
    }
}

struct TrendBars: View {
    let days: [(day: Date, jobs: Int)]
    static let height: CGFloat = 28

    var body: some View {
        let most = max(days.map(\.jobs).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            Text("Jobs, last 7 days").eyebrow()
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days, id: \.day) { day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(day.jobs > 0 ? Palette.primaryFill : Palette.hairline))
                            .frame(width: 14, height: max(Self.height * CGFloat(day.jobs) / CGFloat(most), 2))
                            .frame(height: Self.height, alignment: .bottom)
                        Text(day.day.formatted(.dateTime.weekday(.narrow)))
                            .font(Typography.eyebrow)
                            .foregroundStyle(Color(Palette.muted))
                    }
                    .help("\(day.day.formatted(.dateTime.weekday(.wide))): \(StatusFormat.jobs(day.jobs))")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jobs over the last 7 days: " + days.map { "\($0.day.formatted(.dateTime.weekday(.wide))) \($0.jobs)" }.joined(separator: ", "))
    }
}

struct AgentCard: View {
    let controller: RunController
    let room: String

    var body: some View {
        let colour = controller.colour(for: room)
        let status = status
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(room == "manager" ? "Manager" : controller.displayName(room))
                    .font(Typography.captionMedium)
                    .foregroundStyle(Color(Palette.textOn(colour)))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(Color(colour)))
                Label(status.text, systemImage: status.symbol)
                    .font(Typography.captionMedium)
                    .foregroundStyle(Color(status.colour))
                    .symbolEffect(.pulse, isActive: status.waiting && !OfficeScene.reduceMotion)
            }
            if room == "manager" { manager } else { department }
        }
        .frame(maxWidth: DeskCard.width, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .glass(radius: 12, padding: 12)
        .accessibilityElement(children: .combine)
    }

    private var manager: some View {
        let state = controller.state
        let fraction = state.contextFraction(windows: controller.contextWindows)
        return HStack(spacing: 14) {
            if let fraction { StatBlock(label: "Context", value: StatusFormat.percent(fraction)) }
            StatBlock(label: "Turns", value: "\(state.turns)")
            StatBlock(label: "Briefed", value: "\(state.handoffs.count)")
            if let model = state.mainModel { StatBlock(label: "Model", value: ModelName.display(model)) }
        }
    }

    private var department: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !status.working)) { _ in
            let stats = controller.roomStats(room, now: RunController.now())
            VStack(alignment: .leading, spacing: 8) {
                if let step = stats.latest?.step ?? stats.latest?.brief {
                    Text(step).font(Typography.bodyMedium).lineLimit(2)
                }
                if stats.latest == nil {
                    Text("Nothing handed over yet this job.").font(Typography.caption).foregroundStyle(Color(Palette.muted))
                } else {
                    HStack(spacing: 14) {
                        StatBlock(label: "Worked", value: RunController.clock(stats.worked))
                        StatBlock(label: "Tokens", value: StatusFormat.tokens(stats.tokens))
                        StatBlock(label: "Tools", value: "\(stats.tools)")
                        if let model = stats.latest?.model { StatBlock(label: "Model", value: ModelName.display(model)) }
                    }
                    if stats.waited >= 1 {
                        Label("Waited on you \(RunController.clock(stats.waited))", systemImage: RoomState.waiting.symbol)
                            .font(Typography.caption)
                            .foregroundStyle(Color(Palette.muted))
                    }
                }
            }
        }
    }

    private var status: (text: String, symbol: String, colour: NSColor, working: Bool, waiting: Bool) {
        let state = controller.state
        if state.pendingRequests.contains(where: { $0.room == room }) { return ("Needs you", RoomState.waiting.symbol, RoomState.waiting.colour, true, true) }
        if room == "manager" {
            return state.managerActive ? ("Working", RoomState.working.symbol, RoomState.working.colour, true, false)
                : ("Idle", RoomState.idle.symbol, RoomState.idle.colour, false, false)
        }
        guard let latest = controller.roomStats(room, now: RunController.now()).latest else { return ("Idle", RoomState.idle.symbol, RoomState.idle.colour, false, false) }
        switch (latest.phase, latest.outcome) {
        case (.working, _): return ("Working", RoomState.working.symbol, RoomState.working.colour, true, false)
        case (.requested, _): return ("Briefed", "tray.and.arrow.down.fill", Palette.muted, false, false)
        case (.finished, .failed?): return ("Failed", "xmark.circle.fill", Palette.error, false, false)
        case (.finished, .killed?): return ("Stopped", "stop.circle.fill", Palette.muted, false, false)
        case (.finished, _): return ("Done", "checkmark.circle.fill", Palette.text, false, false)
        }
    }
}
