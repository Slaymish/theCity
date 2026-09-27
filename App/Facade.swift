import AppKit
import RealityKit

/// A building's exterior, built one storey module at a time so the city shows every floor at the interior's heights.
@MainActor
enum Facade {
    enum Style: Int, CaseIterable {
        case glass, brick, concrete
    }

    private enum Part: String {
        case ground, storey, roof
    }

    static let width: Float = 21.8
    static let depth: Float = 17.8
    static let storey = BuildingScene.storeyHeight
    static let cityScale: Float = 1.4 / width
    private static let slab = OfficeScene.floorThickness
    private static var meshes: [String: MeshResource] = [:]

    static func style(of building: CityStore.Building) -> Style {
        Style(rawValue: building.style % Style.allCases.count) ?? .glass
    }

    /// The lobby is the ground storey; each floor adds one module above it, then the roof caps the stack.
    static func tower(_ building: CityStore.Building, dark: Bool) -> Entity {
        let style = style(of: building)
        let materials = materials(for: style, dark: dark)
        let tower = Entity()
        let stack = Entity()
        stack.scale = SIMD3(repeating: cityScale)
        tower.addChild(stack)
        stack.addChild(ModelEntity(mesh: mesh(style, .ground), materials: materials))
        let module = ModelEntity(mesh: mesh(style, .storey), materials: materials)
        for index in 0..<building.floors.count {
            let floor = module.clone(recursive: false)
            floor.position.y = Float(index + 1) * storey
            stack.addChild(floor)
        }
        let roof = ModelEntity(mesh: mesh(style, .roof), materials: materials)
        roof.position.y = Float(building.floors.count + 1) * storey
        stack.addChild(roof)
        return tower
    }

    private static func materials(for style: Style, dark: Bool) -> [RealityKit.Material] {
        let (body, trim): (NSColor, NSColor) = switch style {
        case .glass: (Palette.mullion, Palette.facadeStone)
        case .brick: (Palette.facadeBrick, Palette.facadeStone)
        case .concrete: (Palette.facadeConcrete, Palette.mullion)
        }
        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: Palette.resolved(Palette.glazing, dark: dark))
        glass.roughness = 0.12
        glass.metallic = 0.35
        glass.emissiveColor = .init(color: Palette.resolved(Palette.lamp, dark: dark))
        glass.emissiveIntensity = 0
        return [OfficeScene.material(Palette.resolved(body, dark: dark)), glass, OfficeScene.material(Palette.resolved(trim, dark: dark)),
                OfficeScene.material(Palette.resolved(Palette.mullion, dark: dark))]
    }

    /// Sets how brightly the windows glow; the glass is every module's second material.
    static func light(_ tower: Entity, glow: Float) {
        for case let module as ModelEntity in tower.descendants {
            guard var model = module.model, model.materials.count == 4, var glass = model.materials[1] as? PhysicallyBasedMaterial else { continue }
            glass.emissiveIntensity = glow
            model.materials[1] = glass
            module.model = model
        }
    }

    private static func mesh(_ style: Style, _ part: Part) -> MeshResource {
        let key = "\(style.rawValue)-\(part.rawValue)"
        if let cached = meshes[key] { return cached }
        var shape = Shape()
        switch part {
        case .ground: shape.ground(style)
        case .storey: shape.storey(style)
        case .roof: shape.roof(style)
        }
        let mesh = shape.resource() ?? .generateBox(width: width, height: storey, depth: depth)
        meshes[key] = mesh
        return mesh
    }

    /// Boxes gathered per material (0 body, 1 glass, 2 trim, 3 frame) and merged into one mesh.
    @MainActor private struct Shape {
        private var parts: [(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32])] = Array(repeating: ([], [], []), count: 4)
        private let h = Facade.storey, w = Facade.width, d = Facade.depth, slab = Facade.slab

        mutating func box(_ material: Int, _ centre: SIMD3<Float>, _ size: SIMD3<Float>) {
            let half = size / 2
            for axis in 0..<3 {
                for sign: Float in [-1, 1] {
                    var normal = SIMD3<Float>.zero
                    normal[axis] = sign
                    var u = SIMD3<Float>.zero
                    u[(axis + 1) % 3] = 1
                    let v = simd_cross(normal, u)
                    let spanU = simd_dot(simd_abs(u), half), spanV = simd_dot(simd_abs(v), half)
                    let face = centre + normal * half[axis]
                    let base = UInt32(parts[material].positions.count)
                    for (a, b) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                        parts[material].positions.append(face + u * a * spanU + v * b * spanV)
                        parts[material].normals.append(normal)
                    }
                    parts[material].indices += [base, base + 1, base + 2, base, base + 2, base + 3]
                }
            }
        }

        /// A box on one of the four faces (0 front, 1 back, 2 right, 3 left), `proud` of the face and sunk `sunk` into it.
        mutating func onFace(_ side: Int, _ material: Int, along: Float, y: Float, width: Float, height: Float, proud: Float, sunk: Float = 0.1) {
            let front = side < 2
            let reach = (front ? d : w) / 2 + (proud - sunk) / 2
            let sign: Float = side % 2 == 0 ? 1 : -1
            let thickness = proud + sunk
            if front {
                box(material, [along, y, sign * reach], [width, height, thickness])
            } else {
                box(material, [sign * reach, y, along], [thickness, height, width])
            }
        }

        func length(of side: Int) -> Float { side < 2 ? w : d }

        /// Evenly spaced positions along a face, `spacing` apart at most, including both corners when `corners` is set.
        func stations(_ side: Int, spacing: Float, corners: Bool) -> [Float] {
            let length = length(of: side)
            let count = max(Int(length / spacing), 1)
            let step = length / Float(count)
            return corners ? (0...count).map { -length / 2 + Float($0) * step } : (0..<count).map { -length / 2 + (Float($0) + 0.5) * step }
        }

        mutating func ring(_ material: Int, y: Float, height: Float, thickness: Float, outset: Float) {
            let outerW = w + outset * 2, outerD = d + outset * 2
            box(material, [0, y, outerD / 2 - thickness / 2], [outerW, height, thickness])
            box(material, [0, y, -outerD / 2 + thickness / 2], [outerW, height, thickness])
            box(material, [outerW / 2 - thickness / 2, y, 0], [thickness, height, outerD - thickness * 2])
            box(material, [-outerW / 2 + thickness / 2, y, 0], [thickness, height, outerD - thickness * 2])
        }

        mutating func storey(_ style: Style) {
            switch style {
            case .glass:
                box(0, [0, 0.35, 0], [w, 0.7, d])
                box(1, [0, 0.7 + (h - 0.7) / 2, 0], [w - 0.2, h - 0.7, d - 0.2])
                for side in 0..<4 {
                    for along in stations(side, spacing: 2.2, corners: true) {
                        onFace(side, 0, along: along, y: 0.7 + (h - 0.7) / 2, width: 0.14, height: h - 0.7, proud: 0.12)
                    }
                    onFace(side, 0, along: 0, y: 3.4, width: length(of: side), height: 0.08, proud: 0.06)
                    onFace(side, 2, along: 0, y: 0.72, width: length(of: side) + 0.3, height: 0.12, proud: 0.22)
                    onFace(side, 3, along: 0, y: h - 0.12, width: length(of: side), height: 0.2, proud: 0.1)
                }
            case .brick:
                box(0, [0, h / 2, 0], [w, h, d])
                box(2, [0, slab / 2, 0], [w + 0.1, slab, d + 0.1])
                for side in 0..<4 {
                    for along in stations(side, spacing: 3.4, corners: false) {
                        onFace(side, 1, along: along, y: 2.7, width: 1.7, height: 2.6, proud: 0.03)
                        onFace(side, 2, along: along, y: 1.33, width: 2, height: 0.14, proud: 0.18)
                        onFace(side, 2, along: along, y: 4.1, width: 2, height: 0.22, proud: 0.06)
                        for jamb: Float in [-0.85, 0.85] {
                            onFace(side, 3, along: along + jamb, y: 2.7, width: 0.1, height: 2.6, proud: 0.07)
                        }
                        onFace(side, 3, along: along, y: 3.95, width: 1.8, height: 0.1, proud: 0.07)
                        onFace(side, 3, along: along, y: 2.7, width: 0.07, height: 2.6, proud: 0.05)
                        onFace(side, 3, along: along, y: 3.3, width: 1.7, height: 0.07, proud: 0.05)
                    }
                }
            case .concrete:
                box(0, [0, 0.7, 0], [w + 0.2, 1.4, d + 0.2])
                box(1, [0, 1.4 + (h - 1.4) / 2, 0], [w - 0.2, h - 1.4, d - 0.2])
                for side in 0..<4 {
                    for along in stations(side, spacing: 3, corners: true) {
                        onFace(side, 0, along: along, y: 1.4 + (h - 1.4) / 2, width: 0.25, height: h - 1.4, proud: 0.1)
                    }
                    for along in stations(side, spacing: 3, corners: false) {
                        onFace(side, 3, along: along, y: 1.4 + (h - 1.4) / 2, width: 0.06, height: h - 1.4, proud: 0.04)
                    }
                    onFace(side, 3, along: 0, y: 3.9, width: length(of: side), height: 0.07, proud: 0.04)
                    onFace(side, 2, along: 0, y: 1.42, width: length(of: side) + 0.3, height: 0.1, proud: 0.2)
                }
            }
        }

        mutating func ground(_ style: Style) {
            box(2, [0, slab / 2, 0], [w + 0.3, slab, d + 0.3])
            box(1, [0, slab + (h - 0.9) / 2, 0], [w - 0.4, h - 0.9, d - 0.4])
            box(0, [0, h - 0.3, 0], [w + 0.2, 0.6, d + 0.2])
            for side in 0..<4 {
                for along in stations(side, spacing: 4, corners: true) where side != 0 || abs(along) > 2.4 {
                    onFace(side, 0, along: along, y: slab + (h - 0.9) / 2, width: 0.5, height: h - 0.9, proud: 0.15, sunk: 0.3)
                }
            }
            onFace(0, 0, along: -1.7, y: slab + 1.85, width: 0.2, height: 3.7, proud: 0.2, sunk: 0.3)
            onFace(0, 0, along: 1.7, y: slab + 1.85, width: 0.2, height: 3.7, proud: 0.2, sunk: 0.3)
            onFace(0, 0, along: 0, y: slab + 3.6, width: 3.6, height: 0.2, proud: 0.2, sunk: 0.3)
            onFace(0, 0, along: 0, y: slab + 1.7, width: 0.06, height: 3.4, proud: 0.08, sunk: 0.3)
            box(2, [0, 4.1, d / 2 + 1.1], [6, 0.25, 2.2])
            box(3, [0, 4.1, d / 2 + 2.2], [6.1, 0.4, 0.12])
            for x: Float in [-2.7, 2.7] {
                box(3, [x, slab + (4 - slab) / 2, d / 2 + 1.95], [0.14, 4 - slab, 0.14])
            }
            onFace(0, 3, along: 0, y: slab + 3.1, width: 3.2, height: 0.08, proud: 0.12, sunk: 0.3)
            for x: Float in [-0.9, 0.9] {
                onFace(0, 3, along: x, y: slab + 1.55, width: 0.05, height: 3.1, proud: 0.1, sunk: 0.3)
            }
            box(2, [0, slab / 2, d / 2 + 0.6], [5, slab, 1.2])
            if style == .brick {
                ring(2, y: h - 0.05, height: 0.1, thickness: 0.2, outset: 0.15)
            }
        }

        mutating func roof(_ style: Style) {
            box(2, [0, 0.2, 0], [w, 0.4, d])
            let parapet = style == .glass ? 1 : 0
            ring(parapet, y: 0.85, height: 0.9, thickness: 0.3, outset: 0.05)
            if style != .glass { ring(2, y: 1.37, height: 0.14, thickness: 0.45, outset: 0.12) }
            box(style == .concrete ? 0 : 2, [w / 4, 1.3, -d / 6], [5, 1.8, 4])
            box(0, [-w / 4, 0.8, d / 8], [2.4, 0.8, 2.4])
            for x: Float in [-w / 4 - 3, -w / 4 + 3] {
                box(2, [x, 0.95, -d / 4], [2, 1.1, 1.6])
                box(3, [x, 1.53, -d / 4], [1.3, 0.06, 1.3])
                box(3, [x + 1.02, 0.95, -d / 4], [0.04, 0.8, 1.2])
            }
            for x: Float in [-1.2, 0, 1.2] {
                box(1, [x, 0.48, d / 4], [0.9, 0.16, 2.4])
            }
            box(3, [w / 4 + 1.5, 3.1, -d / 6 + 1], [0.12, 2.6, 0.12])
            for leg: SIMD2<Float> in [[-0.6, -0.6], [0.6, -0.6], [-0.6, 0.6], [0.6, 0.6]] {
                box(3, [w / 3 + leg.x, 0.9, d / 4 + leg.y], [0.12, 1, 0.12])
            }
            box(2, [w / 3, 2, d / 4], [1.8, 1.4, 1.8])
        }

        func resource() -> MeshResource? {
            let descriptors = parts.enumerated().compactMap { index, part -> MeshDescriptor? in
                guard !part.indices.isEmpty else { return nil }
                var descriptor = MeshDescriptor(name: "facade-\(index)")
                descriptor.positions = MeshBuffers.Positions(part.positions)
                descriptor.normals = MeshBuffers.Normals(part.normals)
                descriptor.primitives = .triangles(part.indices)
                descriptor.materials = .allFaces(UInt32(index))
                return descriptor
            }
            return try? MeshResource.generate(from: descriptors)
        }
    }
}
