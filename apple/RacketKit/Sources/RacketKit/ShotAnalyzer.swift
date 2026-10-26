import Foundation
import simd

/// Turns a window of racket-frame samples around an impact into shot metrics.
/// Physics notes: docs/PLAN.md §3. All tunable constants live in `RacketProfile` / `ImpactModel`.
public struct ImpactModel: Codable, Sendable, Equatable {
    /// cm of side-to-side offset per unit of roll ratio (≈ 100·I_twist·b / I_swing).
    public var lateralGain: Float = 1.65
    /// cm of tip/throat offset per unit of normalized ring energy.
    public var longitudinalGain: Float = 10.0
    /// Jolt below this magnitude counts as "center" (no tip/throat sign).
    public var joltDeadband: Float = 0.02
    /// Apparent coefficient of restitution at the sweet spot.
    public var acorCenter: Float = 0.42
    /// Fraction of brushing speed that becomes ball surface speed.
    public var spinGain: Float = 0.7

    public init() {}
}

public struct ShotAnalyzer: Sendable {
    public var profile: RacketProfile
    public var model: ImpactModel

    public init(profile: RacketProfile, model: ImpactModel) {
        self.profile = profile
        self.model = model
    }

    /// - Parameters:
    ///   - window: racket-frame samples; `impact` indexes the impact sample.
    ///   - orientation: racket→world orientation at the impact sample.
    public func analyze(window: [IMUSample], impact i0: Int, orientation q: simd_quatf,
                        date: Date, calibrationMode: Bool) -> ShotMetrics {
        let n = window.count
        func mean(_ r: Range<Int>, _ f: (IMUSample) -> SIMD3<Float>) -> SIMD3<Float> {
            let lo = max(0, r.lowerBound), hi = min(n, r.upperBound)
            guard hi > lo else { return .zero }
            return window[lo..<hi].reduce(.zero) { $0 + f($1) } / Float(hi - lo)
        }

        // Rotation just before and just after contact (skip the ~5 ms of contact itself).
        let wPre = mean((i0 - 10)..<(i0 - 2)) { $0.gyro }
        let wPost = mean((i0 + 12)..<(i0 + 30)) { $0.gyro }
        let dW = wPost - wPre
        let peakGyro = window[max(0, i0 - 300)..<i0].map { simd_length($0.gyro) }.max() ?? 0

        // Racket speed at the sweet spot.
        let omega = simd_length(wPre)
        let vRacket = omega * profile.effectiveRadiusM          // m/s

        // World-frame geometry at contact.
        let up = SIMD3<Float>(0, 0, 1)
        let tipW = q.act(SIMD3(1, 0, 0))
        let normalW = q.act(SIMD3(0, 0, 1))
        let omegaW = q.act(wPre)
        var vDir = simd_cross(omegaW, tipW * profile.effectiveRadiusM)
        vDir = simd_length(vDir) > 1e-3 ? simd_normalize(vDir) : normalW
        let hitSign: Float = simd_dot(normalW, vDir) >= 0 ? 1 : -1   // which face meets the ball
        let hitNormal = normalW * hitSign
        let faceAngle = asin(max(-1, min(1, simd_dot(hitNormal, up)))) * 180 / .pi
        let pathAngle = asin(max(-1, min(1, simd_dot(vDir, up)))) * 180 / .pi

        // Shot type.
        let type: ShotType
        if calibrationMode {
            type = .calibration
        } else if simd_dot(tipW, up) > 0.5 && omega > 8 {
            type = .serve
        } else if peakGyro < 9 {
            type = .volley
        } else {
            let ccw = omegaW.z > 0
            type = (ccw == profile.rightHanded) ? .forehand : .backhand
        }

        // ---- Impact location ----
        let impulse = max(abs(dW.y), 0.5)
        let rollRatio = dW.x / impulse
        let impactX = max(-12, min(12, -rollRatio * model.lateralGain))

        // Frame ringing: band-pass (difference of two moving averages ≈ 120–250 Hz) on the face-normal axis.
        let ringStart = min(n, i0 + 4), ringEnd = min(n, i0 + 60)
        var ringEnergy: Float = 0
        if ringEnd - ringStart > 8 {
            let z = window[(ringStart - 4)..<ringEnd].map { $0.highG.z }
            var count: Float = 0
            for k in 4..<z.count {
                let fast = (z[k] + z[k - 1]) / 2
                let slow = (z[k] + z[k - 1] + z[k - 2] + z[k - 3]) / 4
                let b = fast - slow
                ringEnergy += b * b
                count += 1
            }
            ringEnergy = (ringEnergy / max(count, 1)).squareRoot()
        }
        let ringNorm = ringEnergy / impulse

        // Handle kick: velocity change along the face normal during contact, relative to the pre-impact trend.
        let base = mean((i0 - 14)..<(i0 - 4)) { $0.highG }.z
        var dv: Float = 0
        for k in max(0, i0 - 1)..<min(n, i0 + 5) {
            let excess: Float = window[k].highG.z - base
            dv += excess * Float(0.00981)
        }
        let jolt = dv * hitSign / impulse       // > 0: handle pushed back with the ball (throat); < 0: tip
        var impactY = min(14, ringNorm * model.longitudinalGain)
        if abs(jolt) < model.joltDeadband { impactY *= 0.3 } else if jolt > 0 { impactY = -impactY }

        let features = ImpactFeatures(rollRatio: rollRatio, ringNorm: ringNorm, jolt: jolt, impulse: impulse)
        let distance = (impactX * impactX + impactY * impactY).squareRoot()

        // ---- Ball speed ----
        let e = model.acorCenter * max(0.55, 1 - 0.035 * distance)
        let vIn: Float = type == .serve ? 0 : (type == .volley ? 15 : 12)
        let vBall = calibrationMode ? 0 : e * vIn + (1 + e) * vRacket

        // ---- Spin: brushing speed along the strings ----
        let along = vDir - simd_dot(vDir, hitNormal) * hitNormal
        let brush = vRacket * simd_length(along)
        let spinRPM = Double(model.spinGain * brush / 0.0335 * 60 / (2 * .pi))
        let spin: SpinType = spinRPM < 600 ? .flat : (simd_dot(along, up) > 0 ? .topspin : .slice)

        let peakG = window[max(0, i0 - 5)..<min(n, i0 + 10)].map { simd_length($0.highG) }.max() ?? 0
        let saturated = window[max(0, i0 - 300)..<min(n, i0 + 30)].contains { $0.gyroSaturated }

        return ShotMetrics(
            date: date, type: type,
            swingSpeedKmh: Double(vRacket * 3.6),
            ballSpeedKmh: Double(vBall * 3.6),
            spinRPM: calibrationMode ? 0 : spinRPM,
            spin: calibrationMode ? .flat : spin,
            faceAngleDeg: Double(faceAngle),
            swingPathDeg: Double(pathAngle),
            impactXcm: Double(impactX),
            impactYcm: Double(impactY),
            peakG: Double(peakG),
            gyroSaturated: saturated,
            features: features)
    }
}
