import OfficeCore
import SwiftUI

/// Reports observed work, without inventing thoughts or a progress percentage.
struct ManagerBriefing: View {
    let controller: RunController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Manager’s desk", systemImage: "person.crop.rectangle.fill")
                .font(Typography.captionMedium)
            Text(status).font(Typography.caption)
            ForEach(controller.steps.filter { $0.status == .working }) { step in
                let handoff = controller.state.handoffs(in: step.room).last
                Text("\(controller.displayName(step.room)): \(handoff?.step ?? "working on its brief")")
                    .font(Typography.caption).foregroundStyle(Color(Palette.muted))
                    .lineLimit(2)
            }
            if let latest = controller.activity.last(where: { $0.room == "manager" }) {
                Text(latest.text).font(Typography.caption).lineLimit(3)
            }
            Button("See dispatches", systemImage: "list.bullet.rectangle") {
                controller.panelTab = .requests
                controller.showPanel = true
            }.buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .frame(width: 300, alignment: .leading)
        .glass(padding: 12)
        .sheltersScroll()
    }

    private var status: String {
        if !controller.state.pendingRequests.isEmpty { return "Work is waiting for your answer or approval." }
        let working = controller.steps.filter { $0.status == .working }.count
        if working > 0 { return "\(working) department\(working == 1 ? " is" : "s are") working. The manager coordinates their results." }
        if controller.state.handoffs.isEmpty { return "The manager is handling the request; no departments have been briefed yet." }
        return "Departments have returned their work. The manager is continuing the job."
    }
}
