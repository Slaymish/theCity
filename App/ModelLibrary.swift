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
        let matched = entity.descendants.filter { child in prefixes.contains { child.name.hasPrefix($0) } }
        for child in Set(matched.flatMap { [$0] + $0.descendants }.map(ObjectIdentifier.init)).compactMap({ id in entity.descendants.first { ObjectIdentifier($0) == id } }) {
            guard var model = child.components[ModelComponent.self] else { continue }
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: colour)
            material.roughness = 0.35
            if emissive {
                material.emissiveColor = .init(color: colour)
                material.emissiveIntensity = 2
            }
            model.materials = model.materials.map { _ in material }
            child.components.set(model)
        }
    }
}

extension Entity {
    var descendants: [Entity] {
        children.flatMap { [$0] + $0.descendants }
    }

    func descendant(named name: String) -> Entity? {
        descendants.first { $0.name == name }
    }
}
