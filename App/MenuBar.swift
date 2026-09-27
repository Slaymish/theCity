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

    private func symbol(for building: CityStore.Building) -> String {
        let status = city.status(of: building)
        return status.waiting > 0 ? "hand.raised.fill" : status.working > 0 ? "bolt.fill" : "building.2"
    }

    private func floorLine(_ floor: CityStore.Floor) -> (text: String, symbol: String) {
        let session = city.sessions[floor.id]
        if session?.state.pendingRequests.isEmpty == false { return ("\(floor.name) is waiting for you", "hand.raised.fill") }
        if session?.isRunning == true { return ("\(floor.name) · Working", "bolt.fill") }
        return (floor.name, "square.stack.3d.up")
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
            guard response == .alertFirstButtonReturn, !request.isEmpty, !city.isBusy(buildingID),
                  let building = city.building(buildingID) else { return }
            if let (floor, rest) = ReceptionDesk.directFloor(in: request, floors: building.floors), !rest.isEmpty {
                return city.send(rest, toFloor: floor.id, in: buildingID, navigate: false)
            }
            city.routing.insert(buildingID)
            Task {
                let suggestion = await ReceptionDesk.route(request: request, floors: building.floors)
                city.routing.remove(buildingID)
                if let floorID = suggestion.floorID, city.floor(floorID, in: buildingID) != nil {
                    city.send(request, toFloor: floorID, in: buildingID, navigate: false)
                } else {
                    city.hireNewFloor(in: buildingID, request: request, name: suggestion.newFloorName, preset: FloorPreset.named(suggestion.presetID))
                }
            }
        }
    }
}
