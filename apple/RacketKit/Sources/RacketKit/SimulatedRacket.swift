import Foundation
import simd

/// Generates realistic racket-frame IMU data in real time: idle holding, then swings with impacts.
/// Lets the apps be built and demoed without hardware. The physics mirrors `ShotAnalyzer`, so the
/// analyzer recovers roughly the shot that was simulated.
public final class SimulatedRacket: SampleSource, @unchecked Sendable {
    public var onSamples: (([IMUSample]) -> Void)?
    public var nativeCalibration: Calibration? { .identity }
    /// Seconds between shots.
    public var shotInterval: Double = 3.0

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "tennisbuddy.simulator", qos: .userInitiated)
    private var buffer: [IMUSample] = []
    private var cursor = 0
    private var time: Double = 0
    private var q = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
    private var rng = SystemRandomNumberGenerator()

    public init() {}

    public func start() {
        stop()
        q = Self.idle
        time = 0
        buffer = makeIdle(seconds: 1.0)
        cursor = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        var out: [IMUSample] = []
        out.reserveCapacity(10)
        for _ in 0..<10 {
            if cursor >= buffer.count {
                buffer = makeShot() + makeIdle(seconds: max(0.5, shotInterval - 2.2))
                cursor = 0
            }
            out.append(buffer[cursor])
            cursor += 1
        }
        onSamples?(out)
    }

    // MARK: - Scenario generation

    static let up = SIMD3<Float>(0, 0, 1)
    /// Ready position: racket horizontal in front, face vertical.
    static let idle = orientation(x: SIMD3(0, 1, 0), y: SIMD3(0, 0, -1))

    static func orientation(x: SIMD3<Float>, y: SIMD3<Float>) -> simd_quatf {
        let xn = simd_normalize(x), yn = simd_normalize(y)
        let z = simd_cross(xn, yn)
        return simd_quatf(simd_float3x3(columns: (xn, yn, z)))
    }

    private func gauss(_ sigma: Float) -> Float {
        let u1 = Float.random(in: 1e-6..<1, using: &rng), u2 = Float.random(in: 0..<1, using: &rng)
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    private func noisy(_ v: SIMD3<Float>, _ s: Float) -> SIMD3<Float> { v + SIMD3(gauss(s), gauss(s), gauss(s)) }

    /// Emits one sample for the current orientation and body angular velocity.
    private func sample(omega: SIMD3<Float>, extraHighG: SIMD3<Float> = .zero) -> IMUSample {
        let gravity = q.inverse.act(Self.up)                       // +1 g pointing up, body frame
        let perp = SIMD3<Float>(0, omega.y, omega.z)
        let centripetal = SIMD3<Float>(-simd_length_squared(perp) * 0.6 / 9.81, 0, 0)
        let a = gravity + centripetal
        let mpuAccel = simd_clamp(a, SIMD3(repeating: -16), SIMD3(repeating: 16))
        let gyroClamped = simd_clamp(omega, SIMD3(repeating: -34.9), SIMD3(repeating: 34.9))
        time += 0.001
        return IMUSample(time: time,
                         accel: noisy(mpuAccel, 0.01),
                         gyro: noisy(gyroClamped, 0.01),
                         highG: noisy(a + extraHighG, 0.15))
    }

    private func advance(_ omega: SIMD3<Float>) {
        let angle = simd_length(omega) * 0.001
        if angle > 1e-9 { q = simd_normalize(q * simd_quatf(angle: angle, axis: simd_normalize(omega))) }
    }

    /// Smooth move to `target` over `seconds`, emitting gyro that matches the motion.
    private func moveTo(_ target: simd_quatf, seconds: Double) -> [IMUSample] {
        let n = Int(seconds * 1000)
        let start = q
        var out: [IMUSample] = []
        for k in 1...max(n, 1) {
            let t = Float(k) / Float(n)
            let eased = t * t * (3 - 2 * t)
            let next = simd_slerp(start, target, eased)
            let rel = q.inverse * next
            var w = rel.axis * rel.angle / 0.001
            if rel.angle > .pi { w = -rel.axis * (2 * .pi - rel.angle) / 0.001 }
            if !w.x.isFinite { w = .zero }
            out.append(sample(omega: w))
            q = next
        }
        return out
    }

    private func makeIdle(seconds: Double) -> [IMUSample] {
        var out = moveTo(Self.idle, seconds: 0.4)
        for k in 0..<Int(seconds * 1000) {
            let sway = SIMD3<Float>(0.05 * sin(Float(k) * 0.004), 0.08 * sin(Float(k) * 0.003), 0)
            advance(sway)
            out.append(sample(omega: sway))
        }
        return out
    }

    private func makeShot() -> [IMUSample] {
        enum Kind { case forehand, backhand, serve, volley }
        let roll = Float.random(in: 0..<1, using: &rng)
        let kind: Kind = roll < 0.45 ? .forehand : roll < 0.75 ? .backhand : roll < 0.9 ? .serve : .volley
        let slice = kind != .serve && Float.random(in: 0..<1, using: &rng) < 0.15

        // Contact orientation (racket → world) and rotation axis (body frame).
        var contact: simd_quatf
        var pathDeg = Float.random(in: 12...30, using: &rng)
        if slice { pathDeg = -Float.random(in: 8...18, using: &rng) }
        let tanPath = tan(pathDeg * .pi / 180)
        var axis: SIMD3<Float>
        var peak: Float
        switch kind {
        case .forehand:
            contact = Self.orientation(x: SIMD3(1, 0, 0), y: SIMD3(0, 0, -1))
            axis = SIMD3(0, -1, -tanPath)
            peak = Float.random(in: 17...26, using: &rng)
        case .backhand:
            contact = Self.orientation(x: SIMD3(-1, 0, 0), y: SIMD3(0, 0, 1))
            axis = SIMD3(0, -1, tanPath)
            peak = Float.random(in: 15...23, using: &rng)
        case .serve:
            contact = Self.orientation(x: SIMD3(0, 0.15, 1), y: SIMD3(1, 0, 0))
            axis = SIMD3(0, -1, Float.random(in: -0.2...0.1, using: &rng))
            peak = Float.random(in: 24...32, using: &rng)
        case .volley:
            contact = Self.orientation(x: SIMD3(1, 0.3, 0), y: SIMD3(0, 0, -1))
            axis = SIMD3(0, -1, -0.1)
            peak = Float.random(in: 4...7, using: &rng)
        }
        // Open the face a little for slices, close it a little for topspin.
        let faceTilt: Float = (slice ? 0.35 : -0.05) * (kind == .backhand ? -1 : 1)
        contact = contact * simd_quatf(angle: faceTilt, axis: SIMD3(1, 0, 0))
        axis = simd_normalize(axis)

        // Angular speed profile: Gaussian bump peaking just after contact.
        let sigma: Float = kind == .volley ? 0.06 : 0.13
        let tPre: Float = kind == .volley ? 0.15 : 0.45
        let profile = { (t: Float) -> Float in peak * exp(-pow((t - 0.02) / sigma, 2)) }
        // Integrated angle from t to contact, to find the start orientation.
        var phi: Float = 0
        var t = -tPre
        while t < 0 { phi += profile(t) * 0.001; t += 0.001 }
        let start = contact * simd_quatf(angle: -phi, axis: axis)

        var out = moveTo(start, seconds: 0.7)
        // Forward swing up to contact.
        t = -tPre
        while t < 0 {
            let w = axis * profile(t)
            out.append(sample(omega: w))
            advance(w)
            t += 0.001
        }

        // Impact: true hit position (cm), mostly near the sweet spot.
        let hitX = gauss(2.2), hitY = gauss(3.2)
        let impulse = 0.35 * peak                                  // rad/s drop about the swing axis
        let dOmega = SIMD3<Float>(-(hitX / 1.65) * impulse, impulse, 0) // slows the -y rotation, adds roll
        let ringAmp = abs(hitY) * impulse * 0.55                   // g; frame rings more away from the node
        let joltSign: Float = hitY > 0 ? 1 : -1                    // tip hits kick the handle forward (+z)
        let joltAmp = min(abs(hitY), 8) * impulse * 1.5           // g during the 4 ms of contact

        for k in 0..<450 {
            let tt = Float(k) * 0.001
            var w = axis * profile(tt) + dOmega * exp(-tt / 0.15)
            if kind != .volley && tt > 0.2 { w *= exp(-(tt - 0.2) / 0.1) }   // follow-through slows down
            var extra = SIMD3<Float>(repeating: 0)
            if k < 4 {
                extra.z += joltSign * joltAmp
                extra += SIMD3(0, 0, 30 * (k % 2 == 0 ? 1 : -1)) * (peak / 20)   // contact spike
            }
            // Phase chosen so the ring integrates to ~0 over contact and doesn't fake a handle kick.
            extra.z += ringAmp * sin(2 * .pi * 160 * tt - 0.4 * .pi) * exp(-tt / 0.03)
            out.append(sample(omega: w, extraHighG: extra))
            advance(w)
        }
        return out
    }
}
