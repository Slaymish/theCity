import Testing
import simd
@testable import TheCity

@MainActor
struct CameraRigFlightTests {
    static let dt: Float = 1 / 60
    static let start = CameraRig.Pose(target: [0, 0, 0], yaw: 0, pitch: 0.5, distance: 20)

    /// Steps the rig for `frames` frames and returns the pose after each one.
    static func step(_ rig: CameraRig, frames: Int) -> [CameraRig.Pose] {
        (0..<frames).map { _ in
            rig.update(dt)
            return rig.current
        }
    }

    @Test func aFlightBelowThePitchRangeLandsWithoutAJump() throws {
        try #require(!OfficeScene.reduceMotion, "Flights are off under Reduce Motion")
        let rig = CameraRig(overview: Self.start)
        let kiosk = CameraRig.Pose(target: [30, 0, 0], yaw: 0, pitch: 0, distance: 8)
        rig.reset(to: kiosk)

        var previous = rig.current.pitch
        var biggest: Float = 0, worstFrame = 0
        for frame in 1...240 {
            rig.update(Self.dt)
            let change = abs(rig.current.pitch - previous)
            if change > biggest { (biggest, worstFrame) = (change, frame) }
            previous = rig.current.pitch
        }
        #expect(rig.current.pitch == 0)
        #expect(biggest < 0.03, "pitch jumped \(biggest) rad on frame \(worstFrame)")
    }

    @Test func aFlightBelowThePitchRangeKeepsHeadingForItsPitch() throws {
        try #require(!OfficeScene.reduceMotion, "Flights are off under Reduce Motion")
        let rig = CameraRig(overview: Self.start)
        rig.reset(to: CameraRig.Pose(target: [30, 0, 0], yaw: 0, pitch: 0, distance: 8))

        let poses = Self.step(rig, frames: 240)
        let lastFlying = try #require(poses.lastIndex { $0.pitch != 0 })
        let tail = poses[max(0, lastFlying - 5)...lastFlying].map(\.pitch)
        #expect(zip(tail, tail.dropFirst()).allSatisfy { $1 < $0 }, "pitch stalled before landing: \(tail)")
    }

    @Test func retargetingAFlightSlightlyDoesNotJumpThePitch() throws {
        try #require(!OfficeScene.reduceMotion, "Flights are off under Reduce Motion")
        let rig = CameraRig(overview: Self.start)
        let settled: Float = 0.32
        var room = CameraRig.Pose(target: [25, 0, 10], yaw: 1, pitch: settled + 2 * .pi / 180, distance: 8.5)
        rig.reset(to: room)

        let before = Self.step(rig, frames: 27)
        let steady = abs(before[26].pitch - before[25].pitch)
        room.pitch = settled
        rig.reset(to: room)
        rig.update(Self.dt)
        let retargeted = abs(rig.current.pitch - before[26].pitch)
        #expect(retargeted <= steady * 2 + 0.001, "pitch moved \(retargeted) on the retarget frame, \(steady) the frame before")
    }

    @Test func retargetingAFlightDoesNotJumpTheTarget() throws {
        try #require(!OfficeScene.reduceMotion, "Flights are off under Reduce Motion")
        let rig = CameraRig(overview: Self.start)
        var room = CameraRig.Pose(target: [25, 0, 10], yaw: 1, pitch: 0.34, distance: 8.5)
        rig.reset(to: room)

        let before = Self.step(rig, frames: 27)
        let lastStep = before[26].target - before[25].target
        let curve = simd_distance(lastStep, before[25].target - before[24].target)
        room.target.z += 0.2 * room.distance
        rig.reset(to: room)
        rig.update(Self.dt)
        let kink = simd_distance(rig.current.target - before[26].target, lastStep)
        #expect(kink <= curve * 3 + 0.02, "the target's step changed by \(kink) on the retarget frame, \(curve) the frame before")
    }

    @Test func aHandOffKeepsTheCameraMoving() throws {
        try #require(!OfficeScene.reduceMotion, "Flights are off under Reduce Motion")
        let city = CameraRig(overview: Self.start)
        city.reset(to: CameraRig.Pose(target: [40, 0, 0], yaw: 0.3, pitch: 0.4, distance: 30))
        _ = Self.step(city, frames: 20)
        let scale: Float = 3
        let moving = city.velocity
        let speed = simd_length(moving.target) * scale
        try #require(speed > 1, "the city camera should be moving")

        let building = CameraRig(overview: Self.start)
        let seen = city.current
        building.place(at: .init(target: seen.target * scale, yaw: seen.yaw, pitch: seen.pitch, distance: seen.distance * scale),
                       moving: .init(target: moving.target * scale, yaw: moving.yaw, pitch: moving.pitch, distance: moving.distance * scale))
        building.reset(to: CameraRig.Pose(target: [0, 6, 0], yaw: 0.62, pitch: 0.2, distance: 60))
        let before = building.current.target
        building.update(Self.dt)
        let step = building.current.target - before
        #expect(simd_length(step) >= speed * Self.dt * 0.5, "moved \(simd_length(step)) after the hand-off, expected about \(speed * Self.dt)")
        #expect(simd_dot(simd_normalize(step), simd_normalize(moving.target)) > 0.7, "the hand-off turned the camera")
    }
}
