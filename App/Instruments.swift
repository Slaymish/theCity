import OfficeCore
import SwiftUI

/// The scope's state and plan usage in one glass group, top right at every level. Each segment opens its detail.
struct Instruments: View {
    enum Scope {
        case city([CityStore.Building])
        case building(CityStore.Building)
        case floor(RunController)
    }

    let city: CityStore
    let scope: Scope
    var configDirectory: URL?
    @State private var detail: Detail?

    enum Detail: Identifiable {
        case scope, usage
        var id: Self { self }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsCounts {
                counts
                    .fixedSize()
                    .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(.scope) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenCounts)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggle(.scope) }
                    .help(help)
            }
            UsageHUD(configDirectory: configDirectory) { toggle(.usage) }
                .overlay(alignment: .leading) {
                    if showsCounts { Rectangle().fill(Color(Palette.hairline)).frame(width: 1) }
                }
        }
        .modifier(Glass(radius: 24, padding: EdgeInsets()))
        .popover(item: $detail, arrowEdge: .bottom) { shown in
            switch shown {
            case .scope: scopeDetail.padding(16)
            case .usage:
                UsageDetail(configDirectory: configDirectory, accounts: UsageHUD(configDirectory: configDirectory).accounts)
                    .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    .fixedSize()
            }
        }
    }

    private func toggle(_ shown: Detail) {
        detail = detail == shown ? nil : shown
    }

    private var floors: [CityStore.Floor] {
        switch scope {
        case .city(let buildings): buildings.flatMap(\.floors)
        case .building(let building): building.floors
        case .floor: []
        }
    }

    private var showsCounts: Bool {
        if case .floor = scope { return true }
        return !floors.isEmpty
    }

    private var signals: [(signal: FloorSignal, count: Int)] {
        let all = floors.map(city.signal(of:))
        return FloorSignal.allCases.filter { $0 != .quiet }.map { signal in (signal, all.filter { $0 == signal }.count) }.filter { $0.count > 0 }
    }

    @ViewBuilder
    private var counts: some View {
        if case .floor(let controller) = scope {
            RoomTally(counts: controller.roomCounts)
        } else {
            let signals = signals
            HStack(spacing: 8) {
                if signals.isEmpty { Text("–").font(Typography.number).foregroundStyle(Color(Palette.muted)) }
                ForEach(signals, id: \.signal) { item in
                    HStack(spacing: 4) {
                        Image(systemName: item.signal.symbol)
                            .font(Typography.captionMedium)
                            .foregroundStyle(Color(item.signal.colour))
                        Text("\(item.count)")
                            .font(Typography.number)
                            .contentTransition(.numericText())
                    }
                }
            }
            .animation(OfficeScene.reduceMotion ? nil : .default, value: signals.map(\.count))
        }
    }

    private var spokenCounts: String {
        if case .floor(let controller) = scope { return "Rooms: \(controller.roomCounts.spoken)" }
        let signals = signals
        guard !signals.isEmpty else { return "Floors: all quiet" }
        return "Floors: " + signals.map { "\($0.count) \($0.signal.label().lowercased())" }.joined(separator: ", ")
    }

    private var help: String {
        switch scope {
        case .floor: "This floor’s job, context and record"
        case .city(let buildings): Self.summary(city.vitals(on: buildings.flatMap(\.floors)), city: city)
        case .building(let building): Self.summary(city.vitals(on: building.floors), city: city)
        }
    }

    @ViewBuilder
    private var scopeDetail: some View {
        switch scope {
        case .city(let buildings): LedgerView(city: city, scope: .city(buildings)) { detail = nil }
        case .building(let building): LedgerView(city: city, scope: .building(building)) { detail = nil }
        case .floor(let controller): FloorDetail(controller: controller)
        }
    }

    static func summary(_ vitals: Vitals, city: CityStore) -> String {
        let summary = vitals.summary, totals = summary.totals
        var lines = ["Today: \(StatusFormat.jobs(summary.today)), \(city.dollars(summary.todaySpendUSD)), \(StatusFormat.tokens(summary.todayTokens)) tokens."]
        if vitals.running {
            lines.insert("Running now: \(city.dollars(vitals.liveSpendUSD)), \(StatusFormat.tokens(vitals.liveTokens)) tokens.", at: 0)
        }
        if totals.jobs > 0 {
            let rate = totals.successRate.map { ", \(StatusFormat.percent($0)) succeeded" } ?? ""
            lines.append("All time: \(StatusFormat.jobs(totals.jobs))\(rate), average \(RunController.clock(totals.averageDuration)), \(city.dollars(totals.spendUSD)), \(StatusFormat.tokens(totals.tokens)) tokens.")
        }
        return lines.joined(separator: " ")
    }
}

/// A floor's figures: the current job's time and spend, context, and the floor's record.
struct FloorDetail: View {
    let controller: RunController

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !controller.isRunning)) { _ in
            grid
        }
    }

    private var grid: some View {
        let state = controller.state
        let tally = state.tally
        let fraction = state.contextFraction(windows: controller.contextWindows)
        let floor = controller.floorID.flatMap { id in CityStore.shared.allFloors.first { $0.id == id } }
        let totals = floor.map { CityStore.shared.jobSummary(on: [$0]).totals }
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            if controller.startedAt != nil {
                row("Job", "\(RunController.clock(elapsed(now: RunController.now()))) · \(spendLine(tally))")
                row("Tokens", "\(StatusFormat.tokens(tally.total))\(tally.isFinal ? "" : " so far")")
            }
            if let fraction, let model = state.mainModel {
                let window = state.contextWindows[model] ?? controller.contextWindows[model]
                row("Context", "\(StatusFormat.percent(fraction)) · \(StatusFormat.tokens(state.contextTokens))\(window.map { " of \(StatusFormat.tokens($0))" } ?? "") · \(ModelName.display(model))")
            }
            if state.turns > 0 {
                row("Turns", "\(state.turns)")
            }
            ForEach(state.models.keys.sorted(), id: \.self) { model in
                let usage = state.models[model]!
                row(ModelName.display(model), "\(StatusFormat.tokens(usage.usage.total)) tokens\(usage.costUSD.map { " · \(controller.dollars($0))" } ?? "")")
            }
            if let stats = state.subagentStats {
                row("Subagents", "\(stats.spawned) spawned · \(stats.completed) done\(stats.failed + stats.killed > 0 ? " · \(stats.failed + stats.killed) stopped" : "")")
            }
            if state.permissionDenials > 0 {
                row("Denied", "\(state.permissionDenials) permission request\(state.permissionDenials == 1 ? "" : "s")")
            }
            if let totals, totals.jobs > 0 {
                row("Floor record", "\(StatusFormat.jobs(totals.jobs))\(totals.successRate.map { " · \(StatusFormat.percent($0)) succeeded" } ?? "") · avg \(RunController.clock(totals.averageDuration))")
                row("Floor spend", "\(controller.dollars(totals.spendUSD)) · \(StatusFormat.tokens(totals.tokens)) tokens")
            }
            if controller.startedAt == nil, fraction == nil, state.models.isEmpty, (totals?.jobs ?? 0) == 0 {
                Text("Figures appear once this floor has run a job.").font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
        }
        .frame(maxWidth: OfficeView.panelWidth, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).eyebrow()
            Text(value).font(Typography.caption).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// On a subscription the dollar figure is only what the API would have charged, so show plan usage instead.
    private func spendLine(_ tally: TokenTally) -> String {
        if let limit = controller.state.rateLimit, !limit.isUsingOverage, let session = limit.windows["five_hour"] {
            return "Plan \(StatusFormat.percent(session.utilization)) of session"
        }
        let budget = controller.budgetUSD.formatted(.currency(code: "USD"))
        let extra = controller.state.rateLimit?.isUsingOverage == true ? " extra usage" : ""
        guard let cost = tally.costUSD else { return "Budget \(budget)\(extra)" }
        return "\(cost.formatted(.currency(code: "USD")))\(extra) of \(budget)"
    }

    private func elapsed(now: Date) -> TimeInterval {
        guard let start = controller.startedAt else { return 0 }
        return (controller.endedAt ?? now).timeIntervalSince(start)
    }
}
