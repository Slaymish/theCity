import RealityKit
import Testing
@testable import TheCity

@MainActor
struct StoreyShellTests {
    @Test func wallsCloseTheSlotBetweenStoreys() {
        let walls = OfficeScene.walls(width: OfficeScene.footprint.x, depth: OfficeScene.footprint.y) { ModelEntity(mesh: $0, materials: []) }
        let bounds = walls.map { $0.visualBounds(relativeTo: nil) }
        let bottom = bounds.map(\.min.y).min() ?? 0
        let top = bounds.map(\.max.y).max() ?? 0
        #expect(top - bottom >= BuildingScene.storeyHeight - 0.001, "Walls stand outside the slab, so they must span a whole storey or light leaks between storeys.")
    }
}

@MainActor
struct SurfacePlacementTests {
    @Test func transformedAssetRestsOnItsSupport() {
        let root = Entity()
        let item = ModelEntity(mesh: ModelLibrary.box(width: 1, height: 2, depth: 3), materials: [])
        item.scale = [1.5, 0.8, 2]
        item.orientation = simd_quatf(angle: 0.7, axis: [0, 0, 1])
        item.position = [4, -5, 6]
        root.addChild(item)
        ModelLibrary.rest(item, on: 1.08, relativeTo: root)
        #expect(abs(item.visualBounds(relativeTo: root).min.y - 1.08) < 0.001)
        #expect(item.position.x == 4 && item.position.z == 6)
    }

    @Test func warmDawnAndTwilightHaveContinuousDaylight() {
        #expect(DayCycle(hour: 6).daylight == 0)
        #expect(DayCycle(hour: 7).daylight == 1)
        #expect(DayCycle(hour: 12).daylight == 1)
        #expect(DayCycle(hour: 19.5).daylight == 0)
        #expect(DayCycle(hour: 6.5).twilight == 1)
        #expect(DayCycle(hour: 18.75).twilight == 1)
        #expect(DayCycle(hour: 6.5).sky(dark: false) != DayCycle(hour: 18.75).sky(dark: false))
    }
}
