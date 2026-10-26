import Foundation
import simd

/// Tennis ball constants, matching `[ball]` in `config/default.toml`.
struct BallProperties: Equatable {
    var radiusM = 0.0335
    var massKg = 0.0575
    var dragCoefficient = 0.507
    var airDensityKgM3 = 1.225

    var areaM2: Double { Double.pi * radiusM * radiusM }
}

/// Translational flight with gravity and quadratic drag, integrated with RK4.
///
/// This is `src/tennisrobot/physics.py::FlightModel` with spin and wind fixed at
/// zero, for the same reason the Python defaults are: one camera cannot observe
/// spin, so fitting it would make the prediction look more certain than it is.
///
/// Everything here is in the camera frame (`x` right, `y` down, `z` forward), so
/// `gravity` is whatever direction the phone measured down to be. Nothing in
/// this type knows about world coordinates.
struct FlightModel: Equatable {
    var ball = BallProperties()
    /// Gravity in camera axes, m/s^2. Supplied from `CMDeviceMotion`.
    var gravity: SIMD3<Double>

    /// 0.5 * rho * A / m * Cd — the coefficient of `-|v| * v`.
    var dragScale: Double {
        0.5 * ball.airDensityKgM3 * ball.areaM2 / ball.massKg * ball.dragCoefficient
    }

    func acceleration(_ velocity: SIMD3<Double>) -> SIMD3<Double> {
        let speed = simd_length(velocity)
        guard speed > 1e-6 else { return gravity }
        return gravity - dragScale * speed * velocity
    }

    /// One RK4 step. `dt` may be negative: the same integration runs backwards,
    /// which is how a state at the newest observation seeds the fit window.
    func step(
        position: SIMD3<Double>,
        velocity: SIMD3<Double>,
        dt: Double
    ) -> (position: SIMD3<Double>, velocity: SIMD3<Double>) {
        guard dt != 0, dt.isFinite else { return (position, velocity) }

        let k1v = acceleration(velocity)
        let k1p = velocity

        let v2 = velocity + 0.5 * dt * k1v
        let k2v = acceleration(v2)
        let k2p = v2

        let v3 = velocity + 0.5 * dt * k2v
        let k3v = acceleration(v3)
        let k3p = v3

        let v4 = velocity + dt * k3v
        let k4v = acceleration(v4)
        let k4p = v4

        let positionNext = position + (dt / 6.0) * (k1p + 2.0 * k2p + 2.0 * k3p + k4p)
        let velocityNext = velocity + (dt / 6.0) * (k1v + 2.0 * k2v + 2.0 * k3v + k4v)
        return (positionNext, velocityNext)
    }
}
