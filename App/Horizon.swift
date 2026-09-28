#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealityKit

/// Distance haze and drifting clouds, built from geometry because RealityView post-processing crashes on macOS 26 (#44).
@MainActor
enum Horizon {
    static let shells = 12
    static let reach: Float = 1.6
    static let wallHeight: Float = 4
    static let cloudDrift: Float = 0.012
    static let cloudFade: Float = 3
    private static let group = ModelSortGroup(depthPass: nil)

    /// Nested walls in the sky's colour around the eye: each hazes whatever lies beyond it a little more, and the outermost is opaque.
    static func haze() -> Entity {
        let holder = Entity()
        let mesh = wall()
        for index in 0..<shells {
            let shell = ModelEntity(mesh: mesh, materials: [])
            let radius = 1 + (reach - 1) * Float(index) / Float(shells - 1)
            shell.scale = [radius, 1, radius]
            shell.components.set(ModelSortGroupComponent(group: group, order: Int32(shells - index)))
            shell.components.set(DynamicLightShadowComponent(castsShadow: false))
            holder.addChild(shell)
        }
        return holder
    }

    static func tint(_ haze: Entity, sky: NSColor) {
        let density = 1 - pow(0.12, 1 / Float(shells - 1))
        for (index, shell) in haze.children.enumerated() {
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(tint: sky)
            material.faceCulling = .none
            if index < shells - 1 {
                material.blending = .transparent(opacity: .init(floatLiteral: density))
                material.writesDepth = false
            }
            (shell as? ModelEntity)?.model?.materials = [material]
        }
    }

    /// Centres the haze on the eye, starting `start` away from it.
    static func place(_ haze: Entity, eye: SIMD3<Float>, ground: Float, start: Float) {
        let position: SIMD3<Float> = [eye.x, ground - 0.05 * start, eye.z], scale = SIMD3<Float>(repeating: start)
        // Runs every frame, so leave the shells alone while the eye is still.
        guard haze.position != position || haze.scale != scale else { return }
        haze.position = position
        haze.scale = scale
    }

    private static func wall() -> MeshResource {
        let segments = 96
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        for index in 0...segments {
            let angle = Float(index) / Float(segments) * 2 * .pi
            positions += [[cos(angle), 0, sin(angle)], [cos(angle), wallHeight, sin(angle)]]
            guard index < segments else { continue }
            let base = UInt32(index * 2)
            indices += [base, base + 1, base + 2, base + 1, base + 3, base + 2]
        }
        var descriptor = MeshDescriptor(name: "haze")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generatePlane(width: 1, depth: 1)
    }

    /// A low-poly cumulus: a few flat-shaded puffs on a flattened base.
    static func cloud(seed: UInt64, colour: NSColor) -> ModelEntity {
        var generator = SeededGenerator(seed: seed)
        let puffs = Int.random(in: 3...5, using: &generator)
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = []
        for index in 0..<puffs {
            let along = (Float(index) - Float(puffs - 1) / 2) * 0.62
            let radius = Float.random(in: 0.42...0.62, using: &generator) * (1 - abs(along) * 0.35)
            let centre = SIMD3<Float>(along, radius * 0.35, Float.random(in: -0.2...0.2, using: &generator))
            for face in icosphere() {
                let corners = face.map { point -> SIMD3<Float> in
                    var p = centre + point * radius
                    p.y = max(p.y, 0)
                    return p
                }
                let normal = simd_normalize(simd_cross(corners[1] - corners[0], corners[2] - corners[0]))
                guard normal.x.isFinite else { continue }
                positions += corners
                normals += [normal, normal, normal]
            }
        }
        var descriptor = MeshDescriptor(name: "cloud")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles((0..<UInt32(positions.count)).map { $0 })
        var material = OfficeScene.material(colour)
        material.roughness = .init(floatLiteral: 1)
        let cloud = ModelEntity(mesh: (try? MeshResource.generate(from: [descriptor])) ?? .generateSphere(radius: 0.5), materials: [material])
        cloud.components.set(DynamicLightShadowComponent(castsShadow: false))
        return cloud
    }

    /// An icosahedron split once, as triangles of unit vectors wound outwards.
    private static func icosphere() -> [[SIMD3<Float>]] {
        let t = (1 + Float(5).squareRoot()) / 2
        let v: [SIMD3<Float>] = [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
                                 [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]].map(simd_normalize)
        let faces: [(Int, Int, Int)] = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
                                        (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
        return faces.flatMap { a, b, c -> [[SIMD3<Float>]] in
            let ab = simd_normalize(v[a] + v[b]), bc = simd_normalize(v[b] + v[c]), ca = simd_normalize(v[c] + v[a])
            return [[v[a], ab, ca], [v[b], bc, ab], [v[c], ca, bc], [ab, bc, ca]]
        }
    }
}

extension Horizon {
    static func ground(dark: Bool) -> ModelEntity {
        ModelEntity(mesh: .generateCylinder(height: 0.1, radius: 400), materials: [OfficeScene.material(Palette.resolved(Palette.grass, dark: dark))])
    }

    static func skyExposure(_ cycle: DayCycle) -> Float { cycle.mix(day: 0.2, night: -3) }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
