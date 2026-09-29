import Foundation
import Observation
import OfficeCore
import SwiftUI

/// The plan's rolling limits, from the latest reading any floor's stream reported.
@MainActor
@Observable
final class UsageStore {
    struct Reading: Codable, Equatable {
        var session: RateLimit.Window?
        var week: RateLimit.Window?
        var asOf: Date
    }

    static let shared = UsageStore()
    private(set) var readings: [String: Reading] = [:]
    private(set) var refreshing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var noLimits: Set<String> = []
    private let key = "usageReadings"

    private init() {
        if let data = UserDefaults.app.data(forKey: key) {
            readings = (try? JSONDecoder().decode([String: Reading].self, from: data)) ?? [:]
        }
    }

    static func key(_ directory: URL?) -> String { directory?.path ?? "default" }

    func reading(_ directory: URL?) -> Reading? { readings[Self.key(directory)] }
    func isRefreshing(_ directory: URL?) -> Bool { refreshing.contains(Self.key(directory)) }
    func refreshError(_ directory: URL?) -> String? { errors[Self.key(directory)] }
    func hasNoLimits(_ directory: URL?) -> Bool { noLimits.contains(Self.key(directory)) }

    func summary(_ directory: URL?) -> String {
        let name = Preferences.accountName(directory)
        if let reading = reading(directory) {
            let percent = { (window: RateLimit.Window?) in "\(Int(((window?.utilization ?? 0) * 100).rounded()))%" }
            return "\(name) — Session \(percent(reading.session)) · Week \(percent(reading.week))"
        }
        return "\(name) — \(hasNoLimits(directory) ? "no plan limits" : "no reading yet")"
    }

    func record(_ limit: RateLimit, configDirectory: URL?, persist: Bool = true) {
        guard !limit.windows.isEmpty else { return }
        let id = Self.key(configDirectory)
        readings[id] = Reading(session: limit.windows["five_hour"], week: limit.windows["seven_day"], asOf: .now)
        // An observed write re-renders every reader even when nothing changed, and this runs on every rate-limit event.
        if noLimits.contains(id) { noLimits.remove(id) }
        if errors[id] != nil { errors[id] = nil }
        if persist, let data = try? JSONEncoder().encode(readings) { UserDefaults.app.set(data, forKey: key) }
    }

    func refresh(_ directories: [URL?]) {
        directories.forEach { refresh(configDirectory: $0) }
    }

    /// Asks Haiku for one word just to read the limits the reply carries (about US$0.001).
    func refresh(configDirectory: URL?) {
        let id = Self.key(configDirectory)
        guard !refreshing.contains(id) else { return }
        let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        guard let executable = RunController.executable(environment: environment) else {
            errors[id] = "Claude Code isn’t installed."
            return
        }
        refreshing.insert(id)
        errors[id] = nil
        // A bare session: the default prompt carries every skill and MCP tool, which made one word cost about US$0.05.
        let arguments = ["-p", "ok", "--output-format", "stream-json", "--verbose", "--model", "haiku", "--no-session-persistence",
                         "--system-prompt", "Reply with the single word ok.", "--tools", "", "--strict-mcp-config",
                         "--mcp-config", #"{"mcpServers":{}}"#, "--disable-slash-commands", "--setting-sources", ""]
        let directory = FileManager.default.temporaryDirectory
        Task {
            defer { refreshing.remove(id) }
            guard let process = try? ClaudeProcess(executable: executable, arguments: arguments, environment: environment,
                                                    workingDirectory: directory) else {
                errors[id] = "Couldn’t start Claude Code."
                return
            }
            var found = false
            var replied = false
            for await output in process.output {
                guard case .line(let line) = output else { continue }
                if case .event(.rateLimit(let limit)) = line.parsed, !limit.windows.isEmpty {
                    record(limit, configDirectory: configDirectory)
                    found = true
                } else if case .event(.result) = line.parsed {
                    replied = true
                }
            }
            if found { return }
            if replied { noLimits.insert(id) } else { errors[id] = "Claude Code didn’t report your limits." }
        }
    }
}

/// Plan usage at a glance, the second segment of `Instruments`: a ring and percentage per window. Clicking opens the reset times and refresh.
struct UsageHUD: View {
    let usage = UsageStore.shared
    var configDirectory: URL?
    var open: () -> Void = {}
    @Environment(\.rendersOffscreen) private var rendersOffscreen

    var accounts: [URL?] { rendersOffscreen ? [configDirectory] : Preferences.shared.visibleAccounts(including: configDirectory) }

    var body: some View {
        let accounts = accounts
        HStack(spacing: 14) {
            ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                if index > 0 { Text("·").font(Typography.caption).foregroundStyle(Color(Palette.muted)) }
                compact(account, named: accounts.count > 1)
            }
        }
        .fixedSize()
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .help(accounts.compactMap(resets).joined(separator: "\n"))
        .accessibilityLabel("Plan usage")
        .accessibilityValue(accounts.map(spoken).joined(separator: ". "))
    }

    @ViewBuilder
    private func compact(_ account: URL?, named: Bool) -> some View {
        HStack(spacing: 8) {
            if named {
                Text(Preferences.accountName(account))
                    .font(account == configDirectory ? Typography.captionMedium : Typography.caption)
                    .foregroundStyle(Color(account == configDirectory ? Palette.text : Palette.muted))
            }
            if let reading = usage.reading(account) {
                ring(reading.session, title: named ? nil : "Session")
                ring(reading.week, title: named ? nil : "Week")
            } else {
                Text(usage.hasNoLimits(account) ? "No plan limits" : usage.refreshError(account) == nil ? "No reading yet" : "Couldn’t refresh")
                    .font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
        }
    }

    private func ring(_ window: RateLimit.Window?, title: String?) -> some View {
        let used = window?.utilization ?? 0
        return HStack(spacing: 8) {
            RingGauge(fraction: used)
            Text("\(title.map { "\($0) " } ?? "")\(Int((used * 100).rounded()))%").font(Typography.captionMedium).monospacedDigit()
        }
    }

    private func resets(_ account: URL?) -> String? {
        guard let reading = usage.reading(account) else { return nil }
        let when = [("Session", reading.session), ("Week", reading.week)].compactMap { name, window in
            window?.resetsAt.map { "\(name) resets \(UsageDetail.when($0))" }
        }.joined(separator: ", ")
        return "\(Preferences.accountName(account)): \(when)"
    }

    private func spoken(_ account: URL?) -> String {
        guard let reading = usage.reading(account) else { return "\(Preferences.accountName(account)), no reading" }
        return "\(Preferences.accountName(account)), session \(Int(((reading.session?.utilization ?? 0) * 100).rounded())) percent, week \(Int(((reading.week?.utilization ?? 0) * 100).rounded())) percent"
    }
}

/// The full plan-usage readout: every window with its reset time, when it was read, and a refresh.
struct UsageDetail: View {
    let usage = UsageStore.shared
    var configDirectory: URL?
    let accounts: [URL?]

    var body: some View {
        HStack(spacing: 14) {
            if accounts.count > 1 {
                Grid(horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(accounts, id: \.self) { account in row(account) }
                }
            } else if let reading = usage.reading(configDirectory) {
                gauge("Session", reading.session)
                gauge("Week", reading.week)
                if let error = usage.refreshError(configDirectory) {
                    errorLabel(error)
                } else {
                    asOf(reading)
                }
            } else if let error = usage.refreshError(configDirectory) {
                errorLabel(error)
            } else if usage.hasNoLimits(configDirectory) {
                Text("No plan limits on this account.").font(Typography.caption).foregroundStyle(Color(Palette.muted))
            } else {
                Text("Plan limits appear after your first job.").font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
            Button {
                usage.refresh(accounts)
            } label: {
                if accounts.contains(where: usage.isRefreshing) { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(Palette.muted))
            .help(accounts.count > 1 ? "Refresh plan limits for every shown account (sends one tiny request to Haiku for each)"
                  : "Refresh your plan limits (sends one tiny request to Haiku)")
            .accessibilityLabel("Refresh plan limits")
        }
    }

    @ViewBuilder
    private func row(_ account: URL?) -> some View {
        let selected = account == configDirectory
        GridRow {
            Text(Preferences.accountName(account))
                .font(selected ? Typography.captionMedium : Typography.caption)
                .foregroundStyle(Color(selected ? Palette.text : Palette.muted))
                .gridColumnAlignment(.leading)
            if let reading = usage.reading(account) {
                gauge("Session", reading.session)
                gauge("Week", reading.week)
                asOf(reading)
            } else {
                Text(usage.hasNoLimits(account) ? "No plan limits" : usage.refreshError(account) ?? "No reading yet")
                    .font(Typography.caption).foregroundStyle(Color(Palette.muted))
                    .gridCellColumns(3)
                    .gridCellAnchor(.leading)
            }
        }
        .help(usage.reading(account) == nil ? "" : usage.refreshError(account) ?? "")
    }

    private func errorLabel(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle").font(Typography.caption).foregroundStyle(Color(Palette.muted)).lineLimit(1).help(error)
    }

    private func asOf(_ reading: UsageStore.Reading) -> some View {
        Text("as of \(reading.asOf.formatted(date: .omitted, time: .shortened))")
            .font(Typography.caption).foregroundStyle(Color(Palette.muted))
    }

    private func gauge(_ title: String, _ window: RateLimit.Window?) -> some View {
        let used = window?.utilization ?? 0
        return HStack(spacing: 8) {
            RingGauge(fraction: used)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(title) \(Int((used * 100).rounded()))%").font(Typography.captionMedium)
                if let resets = window?.resetsAt {
                    Text("resets \(Self.when(resets))").font(Typography.caption).foregroundStyle(Color(Palette.muted))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct RingGauge: View {
    let fraction: Double

    var body: some View {
        let colour = fraction >= 0.9 ? Palette.error : fraction >= 0.7 ? Palette.primaryFill : Palette.screenOn
        ZStack {
            Circle().stroke(Color(Palette.hairline), lineWidth: 4)
            Circle().trim(from: 0, to: min(max(fraction, 0), 1)).stroke(Color(colour), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 22, height: 22)
    }
}
