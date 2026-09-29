import Observation
import OfficeCore
import RealityKit
import UIKit

/// One floor of the tower on the phone: an office scene driven by snapshots instead of a stream.
@MainActor
final class PhoneStorey: Storey {
    let scene = OfficeScene()
    private(set) var floor: FloorSnapshot

    var isRunning: Bool { floor.isRunning }
    var waitingCount: Int { floor.questions.count }
    var waitingSince: Date? { nil }
    var roomCounts: RoomCounts { floor.roomCounts }

    init(_ floor: FloorSnapshot, dark: Bool) {
        self.floor = floor
        build(dark: dark)
        play(floor.events(since: nil))
    }

    func update(_ new: FloorSnapshot, dark: Bool) {
        guard new.hires == floor.hires, new.colours == floor.colours else {
            floor = new
            build(dark: dark)
            return play(new.events(since: nil))
        }
        let events = new.events(since: floor)
        floor = new
        play(events)
    }

    /// An empty list tells the scene to reset, so nothing is sent when nothing changed.
    private func play(_ events: [OfficeEvent]) {
        if !events.isEmpty { scene.apply(events) }
    }

    private func build(dark: Bool) {
        let colours = floor.colours
        scene.build(hired: floor.hires.map { Department(name: $0, description: "") }, servers: [],
                    colour: { room in colours[room].map(Palette.accent(forCatalogueIndex:)) ?? Palette.muted }, dark: dark)
    }
}

/// The phone shows one building at a time. Moving to the next one sinks this tower and raises the other in its place.
@MainActor
@Observable
final class PhoneCity {
    let tower = BuildingScene()
    private(set) var buildingID: UUID?
    private(set) var floorID: UUID?
    private(set) var flying = false
    @ObservationIgnored private var storeys: [UUID: PhoneStorey] = [:]
    @ObservationIgnored private var shownFloors: [UUID] = []
    @ObservationIgnored private var latest: CitySnapshot?
    @ObservationIgnored var dark = false

    init() {
        tower.showsGround = true
        tower.latestPlan = { [weak self] id in self?.latest?.buildings.first { $0.id == id }.map(Self.plan) }
        tower.latestStorey = { [weak self] id in self?.storeys[id] }
    }

    var building: BuildingSnapshot? { latest?.buildings.first { $0.id == buildingID } }
    var floor: FloorSnapshot? { building?.floors.first { $0.id == floorID } }

    func update(from snapshot: CitySnapshot) {
        latest = snapshot
        guard !flying else { return }
        guard let building = building ?? snapshot.buildings.first else {
            buildingID = nil
            return
        }
        if building.id != buildingID || building.floors.map(\.id) != shownFloors {
            show(building)
        } else {
            for floor in building.floors { storeys[floor.id]?.update(floor, dark: dark) }
        }
        if let floorID, !building.floors.contains(where: { $0.id == floorID }) { leaveFloor() }
    }

    private func show(_ building: BuildingSnapshot) {
        if building.id != buildingID {
            floorID = nil
            storeys = [:]
        }
        buildingID = building.id
        var next: [UUID: PhoneStorey] = [:]
        for floor in building.floors {
            if let existing = storeys[floor.id] {
                existing.update(floor, dark: dark)
                next[floor.id] = existing
            } else {
                next[floor.id] = PhoneStorey(floor, dark: dark)
            }
        }
        storeys = next
        shownFloors = building.floors.map(\.id)
        tower.show(Self.plan(building), storeys: building.floors.compactMap { floor in storeys[floor.id].map { (floor.id, $0 as any Storey) } }, dark: dark)
    }

    func fly(to id: UUID) async {
        guard id != buildingID, !flying, let target = latest?.buildings.first(where: { $0.id == id }) else { return }
        flying = true
        floorID = nil
        tower.raise(false, animated: true)
        try? await Task.sleep(for: .seconds(OfficeScene.reduceMotion ? 0 : BuildingScene.slide))
        show(target)
        tower.raise(true, animated: true)
        flying = false
        if let latest { update(from: latest) }
    }

    func enter(floor id: UUID) {
        floorID = id
        tower.enter(floor: id)
    }

    func leaveFloor() {
        floorID = nil
        tower.leaveFloor()
    }

    func tapped(_ entity: Entity) {
        if floorID != nil, tower.isReception(entity) { leaveFloor() } else if let id = tower.floor(of: entity), id != floorID { enter(floor: id) }
    }

    static func plan(_ building: BuildingSnapshot) -> TowerPlan {
        TowerPlan(id: building.id, name: building.name, title: building.title, floors: building.floors.map { floor in
            let outcome: String? = if case .completed = floor.phase { "completed" } else { nil }
            return TowerPlan.Floor(id: floor.id, name: floor.name, lastOutcome: outcome)
        })
    }
}
