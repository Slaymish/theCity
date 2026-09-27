import RealityKit

/// Woodland and ground cover drawn with GPU instancing: one entity per model, however many copies.
@MainActor
enum Foliage {
    /// Every part of `name` drawn at each of `placements`, without shadows.
    /// Instanced models must not get a `GroundingShadowComponent`: RealityKit's mesh shadow system crashes on them.
    static func instanced(_ name: String, _ placements: [simd_float4x4]) -> Entity {
        let holder = Entity()
        guard !placements.isEmpty else { return holder }
        let source = ModelLibrary.entity(name)
        for part in [source] + source.descendants {
            guard let model = part.components[ModelComponent.self] else { continue }
            let local = part.transformMatrix(relativeTo: source)
            guard let data = try? LowLevelInstanceData(instanceCount: placements.count) else { continue }
            data.withMutableTransforms { transforms in
                for index in placements.indices { transforms[index] = placements[index] * local }
            }
            let bounds = placements.reduce(BoundingBox.empty) { $0.union(model.mesh.bounds.transformed(by: $1 * local)) }
            guard let instances = try? MeshInstancesComponent(mesh: model.mesh, instances: data, bounds: bounds) else { continue }
            let copy = Entity()
            copy.components.set(model)
            copy.components.set(instances)
            // Instances cast smeared shadows far from their trees, which reshape whenever the camera moves.
            copy.components.set(DynamicLightShadowComponent(castsShadow: false))
            holder.addChild(copy)
        }
        return holder
    }

    static func placement(_ position: SIMD3<Float>, yaw: Float, scale: Float) -> simd_float4x4 {
        Transform(scale: SIMD3(repeating: scale), rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: position).matrix
    }
}
