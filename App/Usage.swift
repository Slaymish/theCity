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
    private(set) var latest: Reading?
    private(set) var isRefreshing = false
    private(set) var refreshError: String?
    private let key = "usageReading"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key) {
            latest = try? JSONDecoder().decode(Reading.self, from: data)
        }
    }

    func record(_ limit: RateLimit) {
        guard !limit.windows.isEmpty else { return }
        let reading = Reading(session: limit.windows["five_hour"], week: limit.windows["seven_day"], asOf: .now)
        latest = reading
        if let data = try? JSONEncoder().encode(reading) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Asks Haiku for one word just to read the limits the reply carries (about US$0.001).
    func refresh(configDirectory: URL?) {
        guard !isRefreshing else { return }
        let environment = ClaudeEnvironment.make(base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        guard let executable = ClaudeEnvironment.locateCLI(environment: environment) else {
            refreshError = "Claude Code isn’t installed."
            return
        }
        isRefreshing = true
        refreshError = nil
        // A bare session: the default prompt carries every skill and MCP tool, which made one word cost about US$0.05.
        let arguments = ["-p", "ok", "--output-format", "stream-json", "--verbose", "--model", "haiku", "--no-session-persistence",
                         "--system-prompt", "Reply with the single word ok.", "--tools", "", "--strict-mcp-config",
                         "--mcp-config", #"{"mcpServers":{}}"#, "--disable-slash-commands", "--setting-sources", ""]
        let directory = FileManager.default.temporaryDirectory
        Task {
            defer { isRefreshing = false }
            guard let process = try? ClaudeProcess(executable: executable, arguments: arguments, environment: environment,
                                                    workingDirectory: directory) else {
                refreshError = "Couldn’t start Claude Code."
                return
            }
            var found = false
            for await output in process.output {
                if case .line(let line) = output, case .event(.rateLimit(let limit)) = line.parsed, !limit.windows.isEmpty {
                    record(limit)
                    found = true
                }
            }
            if !found { refreshError = "Claude Code didn’t report your limits." }
        }
    }
}

struct UsageHUD: View {
    let usage = UsageStore.shared
    var configDirectory: URL?

    var body: some View {
        HStack(spacing: 14) {
            if let reading = usage.latest {
                gauge("Session", reading.session)
                gauge("Week", reading.week)
                Text("as of \(reading.asOf.formatted(date: .omitted, time: .shortened))")
                    .font(Typography.caption).foregroundStyle(Color(Palette.muted))
            } else {
                Text("Plan limits appear after your first job.").font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
            Button {
                usage.refresh(configDirectory: configDirectory)
            } label: {
                if usage.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(Palette.muted))
            .help(usage.refreshError ?? "Refresh your plan limits (sends one tiny request to Haiku)")
            .accessibilityLabel("Refresh plan limits")
        }
        .modifier(Glass(radius: 24, padding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)))
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
