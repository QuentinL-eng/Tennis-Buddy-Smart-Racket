import Foundation
import RacketKit

/// Sample shots for the coach self-test and previews.
enum CoachSelfTest {
    static func sampleShots() -> [ShotMetrics] {
        var shots: [ShotMetrics] = []
        let base = Date()
        for i in 0..<40 {
            let type: ShotType = i % 3 == 0 ? .backhand : (i % 7 == 0 ? .serve : .forehand)
            let tired = Double(i) / 40
            let off = type == .backhand ? 5.5 : 2.0
            shots.append(ShotMetrics(
                date: base.addingTimeInterval(Double(i) * 30), type: type,
                swingSpeedKmh: (type == .serve ? 120 : 85) - tired * 10,
                ballSpeedKmh: (type == .serve ? 160 : 120) - tired * 15,
                spinRPM: type == .forehand ? 1900 : 1100, spin: .topspin,
                faceAngleDeg: -2, swingPathDeg: type == .forehand ? 18 : 9,
                impactXcm: Double(i % 5) - 2, impactYcm: off * (i % 2 == 0 ? 1 : 0.4),
                peakG: 120, gyroSaturated: false,
                features: ImpactFeatures(rollRatio: 0, ringNorm: 0, jolt: 0, impulse: 5)))
        }
        return shots
    }
}
