import AppKit
import OfficeCore
import SwiftUI

struct MenuBarMenu: View {
    let city: CityStore
    @Environment(\.openSettings) private var openSettings

    private var buildings: [CityStore.Building] { city.buildings.filter { $0.id != city.demoID } }

    var body: some View {
        if buildings.isEmpty {
            Button("No projects yet") {}.disabled(true)
            Button("New Project…") {
                MainWindow.shared.show(route: nil)
                DispatchQueue.main.async { ProjectPicker.addProject() }
            }
        } else {
            let floors = buildings.flatMap(\.floors)
            let vitals = city.vitals(on: floors)
            let waiting = waitingRequests
            if !waiting.isEmpty {
                Section("Waiting for you") {
                    ForEach(waiting, id: \.id) { item in
                        requestEntry(item)
                    }
                }
                Divider()
            }
            Button("Rooms: \(vitals.rooms.spoken)", systemImage: symbol(for: vitals.rooms)) {}.disabled(true)
            Button("Today: \(StatusFormat.jobs(vitals.summary.today)) · \(city.dollars(vitals.summary.todaySpendUSD))", systemImage: "calendar") {}.disabled(true)
            Divider()
            ForEach(buildings) { building in
                Menu {
                    Button("Ask Reception…") { MenuBarReception.ask(in: building.id) }
                        .disabled(city.isBusy(building.id))
                    if city.routing.contains(building.id) {
                        Button("The receptionist is checking which floor fits…") {}.disabled(true)
                    } else if city.hiringHeadless[building.id] != nil {
                        Button("Setting up a floor…") {}.disabled(true)
                    }
                    Button("Open in The City") { MainWindow.shared.show(route: .building(building.id)) }
                    if !building.floors.isEmpty {
                        Divider()
                        ForEach(building.floors) { floor in
                            let line = floorLine(floor)
                            Button(line.text, systemImage: line.symbol) {
                                MainWindow.shared.show(route: .floor(building: building.id, floor: floor.id))
                            }
                        }
                    }
                } label: {
                    Label("\(building.name) · \(city.statusLine(for: building))", systemImage: symbol(for: building))
                }
            }
        }
        Divider()
        Button("Open The City") { MainWindow.shared.show(route: nil) }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        Divider()
        Button("Quit The City") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private struct WaitingRequest {
        let building: CityStore.Building
        let floor: CityStore.Floor
        let controller: RunController
        let pending: PendingRequest
        var id: String { "\(floor.id)/\(pending.id)" }
    }

    private var waitingRequests: [WaitingRequest] {
        buildings.flatMap { building in
            building.floors.flatMap { floor -> [WaitingRequest] in
                guard let controller = city.sessions[floor.id] else { return [] }
                return controller.state.pendingRequests.map {
                    WaitingRequest(building: building, floor: floor, controller: controller, pending: $0)
                }
            }
        }
    }

    @ViewBuilder
    private func requestEntry(_ item: WaitingRequest) -> some View {
        let controller = item.controller
        let pending = item.pending
        let place = buildings.count > 1 ? "\(item.building.name) · \(item.floor.name)" : item.floor.name
        let who = "\(place) · \(controller.displayName(pending.room))"
        let open = { MainWindow.shared.show(route: .floor(building: item.building.id, floor: item.floor.id)) }
        switch pending.request.kind {
        case .question:
            Button("\(who) has a question", systemImage: "questionmark.bubble", action: open)
        case .approval(let summary):
            Menu {
                Button(oneLine(summary)) {}.disabled(true)
                Divider()
                Button("Allow") { resolve(item) { $0.allow($1) } }
                if !pending.request.suggestedRules.isEmpty {
                    Button("Always allow in \(controller.workingDirectory?.lastPathComponent ?? "this folder")") {
                        resolve(item) { $0.allow($1, always: true) }
                    }
                    Button("Saves \(pending.request.suggestedRules.joined(separator: ", ")) to .claude/settings.local.json") {}.disabled(true)
                }
                if controller.permissionMode != .auto {
                    Button("Allow and switch this job to Auto") { resolve(item) { $0.allowAndSwitchToAuto($1) } }
                }
                Button("Deny", role: .destructive) { resolve(item) { $0.deny($1) } }
                Divider()
                Button("Open in The City", action: open)
            } label: {
                Label("\(who) wants to use \(controller.friendly(pending.request.toolName))", systemImage: RoomState.waiting.symbol)
            }
        }
    }

    private func resolve(_ item: WaitingRequest, _ act: (RunController, PendingRequest) -> Void) {
        guard let live = item.controller.state.pendingRequests.first(where: { $0.id == item.pending.id }) else { return }
        act(item.controller, live)
    }

    private func oneLine(_ text: String, limit: Int = 80) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? collapsed.prefix(limit - 1) + "…" : collapsed
    }

    private func symbol(for rooms: RoomCounts) -> String {
        (rooms.waiting > 0 ? RoomState.waiting : rooms.working > 0 ? .working : .idle).symbol
    }

    private func symbol(for building: CityStore.Building) -> String {
        let status = city.status(of: building)
        return status.waiting > 0 ? "hand.raised.fill" : status.working > 0 ? "bolt.fill" : "building.2"
    }

    private func floorLine(_ floor: CityStore.Floor) -> (text: String, symbol: String) {
        let session = city.sessions[floor.id]
        if city.needsYou(floor) > 0 { return ("\(floor.name) is waiting for you", "hand.raised.fill") }
        if let session, session.isRunning { return ("\(floor.name) · \(session.currentStep ?? "Working")", "bolt.fill") }
        return (floor.name, "square.stack.3d.up")
    }
}

struct MenuBarLabel: View {
    let city: CityStore

    var body: some View {
        let waiting = city.pendingCount
        if waiting > 0 {
            Label("\(waiting)", systemImage: RoomState.waiting.symbol)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("The City, \(waiting) waiting for you")
        } else {
            Label("The City", systemImage: city.anyRunning ? RoomState.working.symbol : "building.2")
                .labelStyle(.iconOnly)
        }
    }
}

@MainActor
enum MenuBarReception {
    static func ask(in buildingID: UUID) {
        // The alert can't run modally until the menu has finished tracking.
        DispatchQueue.main.async {
            let city = CityStore.shared
            guard let name = city.building(buildingID)?.name else { return }
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Ask Reception in \(name)"
            alert.informativeText = "Reception picks the right floor."
            let field = NSTextField(string: "")
            field.placeholderString = "What do you need done in \(name)?"
            field.sizeToFit()
            field.frame.size.width = 240
            alert.accessoryView = field
            alert.addButton(withTitle: "Ask Reception")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            let response = alert.runModal()
            if !MainWindow.shared.isOpen { NSApp.hide(nil) }
            let request = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !request.isEmpty else { return }
            city.askReception(request, in: buildingID)
        }
    }
}
