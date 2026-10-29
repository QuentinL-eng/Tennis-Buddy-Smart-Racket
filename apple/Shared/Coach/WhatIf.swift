import Foundation
import RacketKit

/// "What if" on the player's average shot: the baseline both `simulate_change` and the What-if screen start from.
/// Only shots with measured motion count; mic-only and gyro-saturated hits have no usable swing.
enum WhatIf {
    struct Deltas: Equatable {
        var swingPercent = 0.0
        var faceDeg = 0.0
        var pathDeg = 0.0
        var contactXcm = 0.0
        var contactYcm = 0.0

        static let swingLimit = 30.0, angleLimit = 15.0, contactLimit = 5.0

        var clamped: Deltas {
            func c(_ v: Double, _ l: Double) -> Double { min(l, max(-l, v.isFinite ? v : 0)) }
            return Deltas(swingPercent: c(swingPercent, Self.swingLimit), faceDeg: c(faceDeg, Self.angleLimit),
                          pathDeg: c(pathDeg, Self.angleLimit), contactXcm: c(contactXcm, Self.contactLimit),
                          contactYcm: c(contactYcm, Self.contactLimit))
        }
        var isZero: Bool { self == Deltas() }
    }

    struct Baseline {
        var parameters: ShotSimulator.Parameters
        var sampleCount: Int
    }

    static func usable(_ shots: [ShotMetrics]) -> [ShotMetrics] {
        shots.filter { $0.type != .calibration && $0.hasMotion && !$0.gyroSaturated
            && [$0.swingSpeedKmh, $0.faceAngleDeg, $0.swingPathDeg, $0.impactXcm, $0.impactYcm].allSatisfy(\.isFinite) }
    }

    /// nil when no shot of that stroke (or any stroke, for nil) has usable motion.
    static func baseline(_ shots: [ShotMetrics], type: ShotType? = nil) -> Baseline? {
        let shots = usable(shots).filter { type == nil || $0.type == type }
        guard !shots.isEmpty else { return nil }
        let s = ShotSummary(shots)
        let incoming = shots.reduce(0.0) { $0 + ($1.type == .serve ? 0 : $1.type == .volley ? 54 : 43.2) } / Double(shots.count)
        return Baseline(parameters: ShotSimulator.Parameters(swingSpeedKmh: s.avgSwingKmh, pathAngleDeg: s.avgPathAngle,
            faceAngleDeg: s.avgFaceAngle, contactXcm: s.avgImpactX, contactYcm: s.avgImpactY, incomingSpeedKmh: incoming),
            sampleCount: shots.count)
    }

    static func apply(_ deltas: Deltas, to base: ShotSimulator.Parameters) -> ShotSimulator.Parameters {
        let d = deltas.clamped
        var p = base
        p.swingSpeedKmh *= 1 + d.swingPercent / 100
        p.faceAngleDeg += d.faceDeg
        p.pathAngleDeg += d.pathDeg
        p.contactXcm += d.contactXcm
        p.contactYcm += d.contactYcm
        return p
    }

    /// Plain coaching words for a change, e.g. "close the face 3° and swing 5% slower". Mirrors ml/whatif_synth.py.
    static func describe(_ deltas: Deltas, units: UnitSystem) -> String {
        let d = deltas.clamped
        func n(_ v: Double) -> String { v.rounded() == v ? String(Int(abs(v))) : String(format: "%.1f", abs(v)) }
        var parts: [String] = []
        if d.faceDeg != 0 { parts.append(d.faceDeg < 0 ? "close the face \(n(d.faceDeg))°" : "open the face \(n(d.faceDeg))°") }
        if d.pathDeg != 0 { parts.append(d.pathDeg > 0 ? "swing \(n(d.pathDeg))° more low-to-high" : "flatten the path \(n(d.pathDeg))°") }
        if d.swingPercent != 0 { parts.append(d.swingPercent > 0 ? "swing \(n(d.swingPercent))% faster" : "swing \(n(d.swingPercent))% slower") }
        if d.contactYcm != 0 {
            parts.append("hit \(units.lengthText(abs(d.contactYcm))) closer to the \(d.contactYcm > 0 ? "tip" : "throat")")
        }
        if d.contactXcm != 0 {
            parts.append("hit \(units.lengthText(abs(d.contactXcm))) further \(d.contactXcm > 0 ? "right" : "left")")
        }
        switch parts.count {
        case 0: return "keep everything the same"
        case 1, 2: return parts.joined(separator: " and ")
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }
}
