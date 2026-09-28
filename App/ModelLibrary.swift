import AppKit
import RealityKit

@MainActor
enum ModelLibrary {
    private static var cache: [String: Entity] = [:]
    private static var environments: [String: EnvironmentResource] = [:]

    /// Loads a bundled USDZ once and hands out clones; `name` is relative to `Models/`, without the extension.
    static func entity(_ name: String) -> Entity {
        if let cached = cache[name] { return cached.clone(recursive: true) }
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz", subdirectory: nil)
                ?? Bundle.main.url(forResource: (name as NSString).lastPathComponent, withExtension: "usdz"),
              let loaded = try? Entity.load(contentsOf: url) else {
            return Entity()
        }
        cache[name] = loaded
        return loaded.clone(recursive: true)
    }

    static let officeModels = ["table_medium_long", "monitor", "keyboard", "mug", "chair_C", "robot", "cactus_medium_A", "cactus_small_B",
                               "shelf_B_small_decorated", "lamp_standing", "lamp_table", "book_set", "pictureframe_standing_A", "armchair_pillows",
                               "couch_pillows", "cabinet_small_decorated", "tie", "glasses", "hardhat", "magnifier", "beret", "cap"]

    /// Loads models off the main thread ahead of use, so later calls only clone.
    static func warm(_ names: [String]) async {
        for name in names where cache[name] == nil {
            guard let url = Bundle.main.url(forResource: name, withExtension: "usdz", subdirectory: nil)
                    ?? Bundle.main.url(forResource: (name as NSString).lastPathComponent, withExtension: "usdz"),
                  let loaded = try? await Entity(contentsOf: url), cache[name] == nil else { continue }
            cache[name] = loaded
        }
    }

    static func environment(_ name: String) -> EnvironmentResource? {
        if let cached = environments[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "hdr"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let resource = try? EnvironmentResource(equirectangular: image, withName: name) else { return nil }
        environments[name] = resource
        return resource
    }

    /// Recolours every model part whose name starts with one of `prefixes`.
    static func tint(_ entity: Entity, parts prefixes: [String], colour: NSColor, emissive: Bool = false) {
        var seen = Set<ObjectIdentifier>()
        let matched = entity.descendants.filter { child in prefixes.contains { child.name.hasPrefix($0) } }
        let material = material(colour, roughness: 0.35, emissive: emissive ? 2 : 0)
        for child in matched.flatMap({ [$0] + $0.descendants }) where seen.insert(ObjectIdentifier(child)).inserted {
            guard var model = child.components[ModelComponent.self] else { continue }
            model.materials = model.materials.map { _ in material }
            child.components.set(model)
        }
    }

    private static var materials: [String: PhysicallyBasedMaterial] = [:]
    private static var boxes: [SIMD4<Float>: MeshResource] = [:]

    /// Setting a material's colour or roughness is the slowest part of building a scene, so each finish is made once and shared.
    static func material(_ colour: NSColor, roughness: Float?, emissive: Float = 0) -> PhysicallyBasedMaterial {
        let rgb = colour.usingColorSpace(.sRGB) ?? colour
        let key = "\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent),\(rgb.alphaComponent)|\(roughness ?? -1)|\(emissive)"
        if let cached = materials[key] { return cached }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: rgb)
        if let roughness { material.roughness = .init(floatLiteral: roughness) }
        if emissive > 0 {
            material.emissiveColor = .init(color: rgb)
            material.emissiveIntensity = emissive
        }
        materials[key] = material
        return material
    }

    /// Scenes repeat the same few box sizes, and generating each mesh is slow.
    static func box(width: Float, height: Float, depth: Float, cornerRadius: Float = 0) -> MeshResource {
        let key = SIMD4(width, height, depth, cornerRadius)
        if let cached = boxes[key] { return cached }
        let mesh = MeshResource.generateBox(width: width, height: height, depth: depth, cornerRadius: cornerRadius)
        boxes[key] = mesh
        return mesh
    }
}

extension Entity {
    /// Depth-first, parents before their children, in one array rather than one per level.
    var descendants: [Entity] {
        var found: [Entity] = []
        var stack = Array(children.reversed())
        while let next = stack.popLast() {
            found.append(next)
            stack.append(contentsOf: next.children.reversed())
        }
        return found
    }

    /// The first match in `descendants` order, stopping as soon as it's found.
    func descendant(named name: String) -> Entity? {
        var stack = Array(children.reversed())
        while let next = stack.popLast() {
            if next.name == name { return next }
            stack.append(contentsOf: next.children.reversed())
        }
        return nil
    }
}
