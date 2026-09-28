import RealityKit
import SwiftUI

@MainActor
final class World {
    let root = Entity()
    let city = CityScene()
    let building = BuildingScene()
    var updates: EventSubscription?
    private(set) var inBuilding: UUID?
    private var generation = 0
    static let slide = BuildingScene.slide

    init() {
        city.hostsCamera = false
        building.showsGround = false
        root.addChild(city.root)
        root.addChild(building.root)
        root.addChild(city.camera.entity)
        building.root.isEnabled = false
        building.camera.entity.isEnabled = false
    }

    var camera: CameraRig { inBuilding == nil ? city.camera : building.camera }

    var paused = false {
        didSet { root.isEnabled = !paused }
    }

    func update(_ dt: Double) {
        guard !paused else { return }
        city.update(dt)
        guard building.root.isEnabled else { return }
        building.update(dt)
        if let id = inBuilding, let frame = cityFrame(for: id) {
            let eye = (building.camera.entity.position(relativeTo: nil) - frame.offset) / frame.scale
            let target = (building.camera.current.target - frame.offset) / frame.scale
            city.hideOccluders(eye: eye, target: target, keeping: id)
            city.borrowedEye = (eye, target)
        }
    }

    func fit(_ size: CGSize) {
        city.fit(size)
        building.fit(size)
    }

    private func cityFrame(for id: UUID) -> (scale: Float, offset: SIMD3<Float>)? {
        guard let facade = city.facade(of: id) else { return nil }
        let scale = 1 / Facade.cityScale
        return (scale, [0, -0.3, 0] - facade.position * scale)
    }

    private func applyCity(frame: (scale: Float, offset: SIMD3<Float>)) {
        city.root.scale = SIMD3(repeating: frame.scale)
        city.root.position = frame.offset
        city.camera.frame = frame
    }

    func enter(_ id: UUID, animated: Bool) {
        generation += 1
        guard let frame = cityFrame(for: id) else { return }
        if let previous = inBuilding, previous != id { city.sinkFacade(previous, down: false, animated: false) }
        applyCity(frame: frame)
        city.setLabelsVisible(false)
        city.sunEnabled = false
        let seen = city.camera.current
        let overview = building.camera.goal
        if animated {
            building.camera.reset(to: .init(target: seen.target * frame.scale + frame.offset, yaw: seen.yaw, pitch: seen.pitch,
                                            distance: seen.distance * frame.scale), animated: false)
            building.camera.reset(to: overview)
        }
        city.camera.entity.isEnabled = false
        building.camera.entity.isEnabled = true
        building.root.isEnabled = true
        city.sinkFacade(id, down: true, animated: animated)
        building.raise(false, animated: false)
        building.raise(true, animated: animated)
        inBuilding = id
    }

    func leave(animated: Bool) {
        guard let id = inBuilding, let frame = cityFrame(for: id) else { return }
        generation += 1
        let ticket = generation
        building.leaveFloor()
        city.sinkFacade(id, down: false, animated: animated)
        building.raise(false, animated: animated)
        if animated, let closeUp = city.closeUpPose(of: id) {
            building.camera.reset(to: .init(target: closeUp.target * frame.scale + frame.offset, yaw: closeUp.yaw, pitch: closeUp.pitch,
                                            distance: closeUp.distance * frame.scale))
        }
        let finish = { [self] in
            guard ticket == generation else { return }
            let seen = building.camera.current
            city.camera.reset(to: .init(target: (seen.target - frame.offset) / frame.scale, yaw: seen.yaw, pitch: seen.pitch,
                                        distance: seen.distance / frame.scale), animated: false)
            building.camera.entity.isEnabled = false
            building.root.isEnabled = false
            city.camera.entity.isEnabled = true
            applyCity(frame: (1, .zero))
            city.hideOccluders(eye: nil, target: .zero, keeping: nil)
            city.borrowedEye = nil
            city.setLabelsVisible(true)
            city.sunEnabled = true
            inBuilding = nil
            city.camera.reset(to: city.camera.overview, animated: animated)
        }
        guard animated, !OfficeScene.reduceMotion else { return finish() }
        inBuilding = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.slide))
            finish()
        }
    }

    func cityRebuilt() {
        guard let id = inBuilding, let frame = cityFrame(for: id) else { return }
        applyCity(frame: frame)
        city.setLabelsVisible(false)
        city.sunEnabled = false
        city.sinkFacade(id, down: true, animated: false)
    }
}
