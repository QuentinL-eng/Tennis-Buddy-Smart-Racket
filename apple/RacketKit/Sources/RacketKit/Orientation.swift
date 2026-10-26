import Foundation
import simd

/// Mahony complementary filter. Quaternion maps racket frame → world frame (world z = up).
/// The accelerometer only corrects tilt when the racket is near-still (|a| ≈ 1 g, slow rotation),
/// so fast swings rely on the gyro, which is accurate over the ~1 s a swing takes.
public struct MahonyFilter: Sendable {
    public var q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    public var kp: Float = 2.0
    public var ki: Float = 0.05
    var integral = SIMD3<Float>(repeating: 0)
    var initialized = false
    /// Yaw offset applied when reporting, so "recenter" makes the current heading face forward.
    public var yawOffset = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    public init() {}

    public mutating func update(gyro: SIMD3<Float>, accel: SIMD3<Float>, dt: Float) {
        let aNorm = simd_length(accel)
        if !initialized, aNorm > 0.5 {
            q = Self.tiltOnly(accel: accel)
            initialized = true
        }
        var w = gyro
        if aNorm > 0.85, aNorm < 1.15, simd_length(gyro) < 3 {
            let a = accel / aNorm
            let upBody = q.inverse.act(SIMD3(0, 0, 1))
            let e = simd_cross(a, upBody)
            integral += ki * e * dt
            w += kp * e + integral
        }
        let angle = simd_length(w) * dt
        if angle > 1e-9 {
            q = simd_normalize(q * simd_quatf(angle: angle, axis: simd_normalize(w)))
        }
    }

    /// Orientation for display, with the recenter offset applied.
    public var displayOrientation: simd_quatf { yawOffset * q }

    /// Rotates the world about the vertical so the racket's current tip direction points along world +x (screen right).
    public mutating func recenter() {
        let tip = q.act(SIMD3(1, 0, 0))
        let yaw = atan2(tip.y, tip.x)
        yawOffset = simd_quatf(angle: -yaw, axis: SIMD3(0, 0, 1))
    }

    static func tiltOnly(accel: SIMD3<Float>) -> simd_quatf {
        // Rotation taking the measured "up" (body frame) to world up.
        simd_quatf(from: simd_normalize(accel), to: SIMD3(0, 0, 1))
    }
}
