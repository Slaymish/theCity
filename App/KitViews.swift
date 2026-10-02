import AppKit
import OfficeCore
import SwiftUI

enum KitStyle {
    static func statusColour(_ status: String) -> NSColor {
        switch status {
        case "connected": Palette.screenOn
        case "pending": Palette.lamp
        case "failed", "needs-auth": Palette.error
        default: Palette.muted
        }
    }

    static func statusText(_ status: String) -> String {
        switch status {
        case "connected": "Connected"
        case "pending": "Waiting for approval"
        case "needs-auth": "Needs sign-in"
        case "failed": "Couldn’t connect"
        default: status.capitalized
        }
    }

    static func sourceText(_ source: String?) -> String {
        switch source {
        case "user": "Yours"
        case "project": "This workspace"
        case "plugin": "Plugin"
        case "claudeai": "claude.ai"
        default: source?.capitalized ?? ""
        }
    }
}

struct StatusDot: View {
    let status: String

    var body: some View {
        Circle().fill(Color(KitStyle.statusColour(status))).frame(width: 8, height: 8)
            .accessibilityLabel(KitStyle.statusText(status))
    }
}

struct KitToggle: View {
    let isOn: Bool
    let name: String
    let action: () -> Void

    var body: some View {
        Button(isOn ? "On" : "Off", action: action)
            .buttonStyle(PillButtonStyle(kind: isOn ? .tab(active: true) : .secondary))
            .accessibilityLabel("\(name), \(isOn ? "allowed" : "blocked")")
    }
}

struct KitChooser: View {
    let controller: RunController
    @State private var showAllSkills = false

    var body: some View {
        if controller.isLoadingKit && controller.kit == nil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking your services and skills…").font(Typography.caption).foregroundStyle(Color(Palette.muted))
            }
        } else if let kit = controller.kit {
            VStack(alignment: .leading, spacing: 10) {
                Text("Services").eyebrow()
                if kit.servers.isEmpty {
                    Text("No MCP servers are set up for this login.").font(Typography.caption).foregroundStyle(Color(Palette.muted))
                }
                ForEach(kit.servers) { server in
                    HStack(spacing: 10) {
                        StatusDot(status: server.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(Typography.captionMedium)
                            Text("\(KitStyle.sourceText(server.source)) · \(KitStyle.statusText(server.status))")
                                .font(Typography.caption).foregroundStyle(Color(Palette.muted))
                        }
                        Spacer()
                        if server.status == "connected" {
                            KitToggle(isOn: controller.allowedServers.contains(server.name), name: server.name) {
                                controller.toggleServer(server.name)
                            }
                        }
                    }
                }
                Text("Skills").eyebrow().padding(.top, 6)
                let allowed = kit.skills.filter { controller.allowedSkills.contains($0.name) }
                if allowed.isEmpty {
                    Text("No skills allowed for this job.").font(Typography.caption).foregroundStyle(Color(Palette.muted))
                }
                ForEach(allowed) { skill in skillRow(skill) }
                Button(showAllSkills ? "Hide other skills" : "Show all \(kit.skills.count) skills") { showAllSkills.toggle() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                if showAllSkills {
                    ForEach(kit.skills.filter { !controller.allowedSkills.contains($0.name) }) { skill in skillRow(skill) }
                }
            }
            .glass()
        }
    }

    private func skillRow(_ skill: CommandInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).font(Typography.captionMedium)
                Text(skill.description).font(Typography.caption).foregroundStyle(Color(Palette.muted)).lineLimit(2)
            }
            Spacer()
            KitToggle(isOn: controller.allowedSkills.contains(skill.name), name: skill.name) { controller.toggleSkill(skill.name) }
        }
    }
}

struct KitPanel: View {
    let controller: RunController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Services").eyebrow()
                let servers = controller.kit?.servers ?? controller.state.mcpServers
                if servers.isEmpty {
                    Text(controller.provider == .codex ? "Codex uses its configured MCP services." : "No MCP servers for this job.").font(Typography.caption).foregroundStyle(Color(Palette.muted))
                }
                ForEach(servers) { server in
                    let calls = controller.state.serviceCallsByServer[server.name] ?? 0
                    let blocked = controller.kit != nil && server.status == "connected" && !controller.allowedServers.contains(server.name)
                    HStack(spacing: 10) {
                        StatusDot(status: server.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(Typography.captionMedium)
                            Text(server.status != "connected" ? KitStyle.statusText(server.status)
                                 : blocked ? "Blocked for this job" : calls == 0 ? "Not used yet" : "Used \(calls) time\(calls == 1 ? "" : "s")")
                                .font(Typography.caption).foregroundStyle(Color(Palette.muted))
                        }
                    }
                }
                Text("Skills").eyebrow().padding(.top, 6)
                let loaded = controller.state.skillsByRoom.flatMap { room, skills in skills.map { ($0, room) } }.sorted { $0.0 < $1.0 }
                if loaded.isEmpty {
                    Text("No skills loaded yet.").font(Typography.caption).foregroundStyle(Color(Palette.muted))
                }
                ForEach(loaded, id: \.0) { skill, room in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill).font(Typography.captionMedium)
                        Text("Loaded by \(room == "manager" ? "the manager" : room.capitalized)").font(Typography.caption).foregroundStyle(Color(Palette.muted))
                    }
                }
                if controller.provider == .claude, let kit = controller.kit {
                    let blocked = kit.skills.count - kit.skills.filter { controller.allowedSkills.contains($0.name) }.count
                    Text("\(kit.skills.count - blocked) allowed · \(blocked) blocked for this job")
                        .font(Typography.caption).foregroundStyle(Color(Palette.muted))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CommandPicker: View {
    let commands: [CommandInfo]
    let pick: (CommandInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(commands) { command in
                Button { pick(command) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/\(command.name)").font(Typography.code)
                        Text(command.description).font(Typography.caption).foregroundStyle(Color(Palette.muted)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .glass(radius: 12, padding: 6)
    }
}
