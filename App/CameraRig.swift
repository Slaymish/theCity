import CoreGraphics
import RealityKit
import simd

/// A spring-damped orbit camera: every input moves a goal, and the camera glides towards it.
@MainActor
final class CameraRig {
    struct Pose: Equatable {
        var target: SIMD3<Float>
        var yaw: Float
        var pitch: Float
        var distance: Float
    }

    let entity = Entity()
    private(set) var current: Pose
    private(set) var goal: Pose
    private var anchor: Pose
    private var velocity = Pose(target: .zero, yaw: 0, pitch: 0, distance: 0)
    var overview: Pose
    var smoothTime: Float = 0.45
    var frame: (scale: Float, offset: SIMD3<Float>) = (1, .zero) {
        didSet { apply() }
    }
    static let pitchRange: ClosedRange<Float> = 0.12...1.35
    static let distanceRange: ClosedRange<Float> = 4...80

    init(overview: Pose) {
        self.overview = overview
        current = overview
        goal = overview
        anchor = overview
        var lens = PerspectiveCameraComponent()
        lens.fieldOfViewInDegrees = 26
        lens.near = 0.1
        lens.far = 6000
        entity.components.set(lens)
        apply()
    }

    func reset(to pose: Pose, animated: Bool = true) {
        goal = pose
        anchor = pose
        if !animated {
            current = pose
            velocity = Pose(target: .zero, yaw: 0, pitch: 0, distance: 0)
            apply()
        }
    }

    func orbit(dx: Float, dy: Float) {
        goal.yaw -= dx * 0.006
        goal.pitch = (goal.pitch + dy * 0.004).clamped(to: Self.pitchRange)
    }

    func zoom(by factor: Float) {
        goal.distance = (goal.distance * factor).clamped(to: Self.distanceRange)
    }

    func pan(dx: Float, dy: Float) {
        let right = SIMD3<Float>(cos(current.yaw), 0, -sin(current.yaw))
        let forward = SIMD3<Float>(sin(current.yaw), 0, cos(current.yaw))
        let scale = current.distance * 0.0016
        goal.target += (-right * dx + forward * -dy) * scale
        var offset = goal.target - anchor.target
        offset.y = 0
        let limit = anchor.distance
        if simd_length(offset) > limit { goal.target -= offset - simd_normalize(offset) * limit }
    }

    func focus(on point: SIMD3<Float>, facing yaw: Float, distance: Float = 7, pitch: Float = 0.32) {
        reset(to: Pose(target: point, yaw: yaw, pitch: pitch, distance: distance))
    }

    func lift(to height: Float) {
        goal.target.y = height
        anchor.target.y = height
    }

    func recentre() {
        goal = anchor
    }

    func project(_ point: SIMD3<Float>, in size: CGSize) -> (SIMD2<Float>, Float)? {
        let eye = entity.position(relativeTo: nil)
        let forward = simd_normalize(current.target * frame.scale + frame.offset - eye)
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        let up = simd_cross(right, forward)
        let focal = Float(size.height) / 2 / tan(26 * .pi / 360)
        let d = point - eye
        let depth = simd_dot(d, forward)
        guard depth > 0 else { return nil }
        return (SIMD2(Float(size.width) / 2 + simd_dot(d, right) / depth * focal,
                      Float(size.height) / 2 - simd_dot(d, up) / depth * focal), depth)
    }

    func update(_ dt: Float) {
        current.target = Self.damp(current.target, goal.target, &velocity.target, smoothTime, dt)
        current.yaw = Self.damp(current.yaw, goal.yaw, &velocity.yaw, smoothTime, dt)
        current.pitch = Self.damp(current.pitch, goal.pitch, &velocity.pitch, smoothTime, dt)
        current.distance = Self.damp(current.distance, goal.distance, &velocity.distance, smoothTime, dt)
        apply()
    }

    private func apply() {
        let offset = SIMD3<Float>(sin(current.yaw) * cos(current.pitch), sin(current.pitch), cos(current.yaw) * cos(current.pitch))
        let target = current.target * frame.scale + frame.offset
        entity.look(at: target, from: target + offset * current.distance * frame.scale, relativeTo: nil)
    }

    /// Critically damped spring (as in Game Programming Gems 4): no overshoot, continuous velocity.
    static func damp<T: SIMD>(_ from: T, _ to: T, _ velocity: inout T, _ smoothTime: Float, _ dt: Float) -> T where T.Scalar == Float {
        let omega = 2 / max(smoothTime, 0.0001)
        let x = omega * dt
        let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        let change = from - to
        let temp = (velocity + change * omega) * dt
        velocity = (velocity - temp * omega) * decay
        return to + (change + temp) * decay
    }

    static func damp(_ from: Float, _ to: Float, _ velocity: inout Float, _ smoothTime: Float, _ dt: Float) -> Float {
        var v = SIMD2<Float>(velocity, 0)
        let result = damp(SIMD2(from, 0), SIMD2(to, 0), &v, smoothTime, dt)
        velocity = v.x
        return result.x
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
