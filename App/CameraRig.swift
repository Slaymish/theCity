import CoreGraphics
import Observation
import RealityKit
import simd

@Observable @MainActor
final class CameraMotion {
    var settled = true
}

/// A spring-damped orbit camera: every input moves a goal, and the camera glides towards it.
/// Big moves fly instead: a timed arc that pulls back and up on the way, then settles on the goal.
@MainActor
final class CameraRig {
    struct Pose: Equatable {
        var target: SIMD3<Float>
        var yaw: Float
        var pitch: Float
        var distance: Float
    }

    let entity = Entity()
    let motion = CameraMotion()
    private(set) var current: Pose
    private(set) var goal: Pose
    private var anchor: Pose
    private(set) var velocity = CameraRig.still
    private var flight: Flight?
    var overview: Pose
    var smoothTime: Float = 0.45
    var frame: (scale: Float, offset: SIMD3<Float>) = (1, .zero) {
        didSet { apply() }
    }
    static let pitchRange: ClosedRange<Float> = 0.12...1.35
    static let distanceRange: ClosedRange<Float> = 4...80
    static let still = Pose(target: .zero, yaw: 0, pitch: 0, distance: 0)
    var distanceRange = CameraRig.distanceRange
    static let flightTime: ClosedRange<Float> = 0.9...2.2

    enum Steer: Hashable { case left, right, up, down, zoomIn, zoomOut }
    static var steering: Set<Steer> = []
    static let steerTurn: Float = .pi / 3
    static let steerZoom: Float = 2

    private struct Flight {
        var from: Pose
        var to: Pose
        var launch: Pose
        var elapsed: Float = 0
        let duration: Float
        let lift: Float
    }

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

    func place(at pose: Pose, moving velocity: Pose = CameraRig.still) {
        reset(to: pose, animated: false)
        self.velocity = velocity
    }

    func reset(to pose: Pose, animated: Bool = true) {
        if animated, pose == goal, pose == anchor { return }
        goal = pose
        anchor = pose
        guard animated else {
            flight = nil
            current = pose
            velocity = Self.still
            apply()
            return
        }
        if let trip = flight, Self.span(from: trip.to, to: pose) < 0.25 {
            let remaining = max(trip.duration - trip.elapsed, 0)
            let gap = simd_distance(current.target, pose.target)
            if pose == trip.to || remaining <= smoothTime || gap < simd_length(velocity.target) * remaining * 0.5 {
                flight = nil
                return
            }
            let t = min(trip.elapsed / trip.duration, 1)
            let bump = sin(.pi * t * t * (3 - 2 * t)) * trip.lift
            flight = Flight(from: current, to: pose, launch: velocity, duration: max(trip.duration - trip.elapsed, smoothTime),
                            lift: max(trip.lift - bump, 0))
        } else if Self.span(from: current, to: pose) > 0.25, !OfficeScene.reduceMotion {
            let travel = simd_distance(current.target, pose.target) / max(current.distance, pose.distance)
            flight = Flight(from: current, to: pose, launch: velocity,
                            duration: (0.9 + Self.span(from: current, to: pose) * 0.45).clamped(to: Self.flightTime),
                            lift: min(travel, 1.2) * 0.3)
        } else {
            flight = nil
        }
    }

    /// How big a move is, in units where 1 is a jump of one viewing distance.
    private static func span(from: Pose, to: Pose) -> Float {
        let travel = simd_distance(from.target, to.target) / max(from.distance, to.distance, 0.001)
        let zoom = abs(log(max(to.distance, 0.001) / max(from.distance, 0.001)))
        return max(travel, zoom * 0.6, abs(turn(from.yaw, to.yaw)) * 0.5)
    }

    private static func turn(_ from: Float, _ to: Float) -> Float {
        remainder(to - from, 2 * .pi)
    }

    /// Hands control back to the springs from wherever a flight has got to.
    private func land() {
        guard flight != nil else { return }
        flight = nil
        goal = current
    }

    func orbit(dx: Float, dy: Float) {
        land()
        goal.yaw -= dx * 0.006
        goal.pitch = Self.limit(goal.pitch + dy * 0.004, from: goal.pitch, to: Self.pitchRange)
    }

    func zoom(by factor: Float) {
        land()
        goal.distance = Self.limit(goal.distance * factor, from: goal.distance, to: distanceRange)
    }

    private static func limit(_ value: Float, from old: Float, to range: ClosedRange<Float>) -> Float {
        guard old.isFinite else { return value.isFinite ? value.clamped(to: range) : range.lowerBound }
        guard value.isFinite else { return old }
        return value.clamped(to: min(range.lowerBound, old)...max(range.upperBound, old))
    }

    private func steer(_ dt: Float) {
        land()
        let keys = Self.steering
        let turn = Self.steerTurn * dt
        if keys.contains(.left) { goal.yaw += turn }
        if keys.contains(.right) { goal.yaw -= turn }
        if keys.contains(.up) { goal.pitch = Self.limit(goal.pitch + turn, from: goal.pitch, to: Self.pitchRange) }
        if keys.contains(.down) { goal.pitch = Self.limit(goal.pitch - turn, from: goal.pitch, to: Self.pitchRange) }
        if keys.contains(.zoomIn) { goal.distance = Self.limit(goal.distance / pow(Self.steerZoom, dt), from: goal.distance, to: distanceRange) }
        if keys.contains(.zoomOut) { goal.distance = Self.limit(goal.distance * pow(Self.steerZoom, dt), from: goal.distance, to: distanceRange) }
    }

    func pan(dx: Float, dy: Float) {
        land()
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
        land()
        goal.target.y = height
        anchor.target.y = height
    }

    func recentre() {
        reset(to: anchor)
    }

    private static func focal(_ size: CGSize) -> Float { Float(size.height) / 2 / tan(26 * .pi / 360) }

    func pixels(_ metres: Float, atDepth depth: Float, in size: CGSize) -> Float { metres / depth * Self.focal(size) }

    func project(_ point: SIMD3<Float>, in size: CGSize) -> (SIMD2<Float>, Float)? {
        let eye = entity.position(relativeTo: nil)
        let forward = simd_normalize(current.target * frame.scale + frame.offset - eye)
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        let up = simd_cross(right, forward)
        let focal = Self.focal(size)
        let d = point - eye
        let depth = simd_dot(d, forward)
        guard depth > 0 else { return nil }
        return (SIMD2(Float(size.width) / 2 + simd_dot(d, right) / depth * focal,
                      Float(size.height) / 2 - simd_dot(d, up) / depth * focal), depth)
    }

    func update(_ dt: Float) {
        defer {
            let settled = flight == nil && current == goal
            if motion.settled != settled { motion.settled = settled }
        }
        if !Self.steering.isEmpty, entity.isEnabled { steer(dt) }
        if var trip = flight {
            let dt = min(dt, 1 / 30)
            trip.elapsed += dt
            fly(trip, dt: dt)
            flight = trip.elapsed < trip.duration ? trip : nil
            if flight == nil { velocity = Self.still }
            apply()
            return
        }
        guard current != goal else { return }
        current.target = Self.damp(current.target, goal.target, &velocity.target, smoothTime, dt)
        current.yaw = Self.damp(current.yaw, goal.yaw, &velocity.yaw, smoothTime, dt)
        current.pitch = Self.damp(current.pitch, goal.pitch, &velocity.pitch, smoothTime, dt)
        current.distance = Self.damp(current.distance, goal.distance, &velocity.distance, smoothTime, dt)
        // The springs only approach the goal, so snap once the gap is far below a pixel and stop moving the camera every frame.
        if Self.span(from: current, to: goal) < 0.00005, simd_length(velocity.target) + abs(velocity.yaw) + abs(velocity.pitch) + abs(velocity.distance) < 0.0005 {
            current = goal
            velocity = Self.still
        }
        apply()
    }

    /// Cubic Hermite from the launch velocity to rest, with the pull-back riding on top as a sine bump.
    private func fly(_ trip: Flight, dt: Float) {
        let t = min(trip.elapsed / trip.duration, 1), time = trip.duration
        let ease = t * t * (3 - 2 * t), push = (t * t * t - 2 * t * t + t) * time
        let bump = sin(.pi * ease) * trip.lift
        let previous = current
        let yaw = trip.from.yaw + Self.turn(trip.from.yaw, trip.to.yaw)
        current.target = trip.from.target + (trip.to.target - trip.from.target) * ease + trip.launch.target * push
        current.yaw = trip.from.yaw + (yaw - trip.from.yaw) * ease + trip.launch.yaw * push
        let lowest = min(trip.from.pitch, trip.to.pitch, Self.pitchRange.lowerBound) - 0.1
        let highest = min(max(trip.from.pitch, trip.to.pitch, Self.pitchRange.upperBound) + 0.15, .pi / 2 - 0.05)
        current.pitch = (trip.from.pitch + (trip.to.pitch - trip.from.pitch) * ease + trip.launch.pitch * push + bump * 0.35)
            .clamped(to: lowest...highest)
        let logFrom = log(trip.from.distance), logTo = log(trip.to.distance)
        current.distance = max(exp(logFrom + (logTo - logFrom) * ease) * (1 + bump) + trip.launch.distance * push,
                               min(trip.from.distance, trip.to.distance) * 0.25)
        if t >= 1 { current = trip.to }
        guard dt > 0 else { return }
        velocity = Pose(target: (current.target - previous.target) / dt, yaw: (current.yaw - previous.yaw) / dt,
                        pitch: (current.pitch - previous.pitch) / dt, distance: (current.distance - previous.distance) / dt)
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
