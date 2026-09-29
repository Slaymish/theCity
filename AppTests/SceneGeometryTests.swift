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
