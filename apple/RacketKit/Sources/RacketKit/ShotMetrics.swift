import Foundation

public enum ShotType: String, Codable, Sendable, CaseIterable, Identifiable {
    case forehand, backhand, serve, volley, calibration
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .forehand: "Forehand"
        case .backhand: "Backhand"
        case .serve: "Serve"
        case .volley: "Volley"
        case .calibration: "Calibration"
        }
    }
    public var symbol: String {
        switch self {
        case .forehand: "arrow.turn.up.left"
        case .backhand: "arrow.turn.up.right"
        case .serve: "arrow.up.circle"
        case .volley: "hand.raised"
        case .calibration: "scope"
        }
    }
}

public enum SpinType: String, Codable, Sendable {
    case topspin, flat, slice
    public var label: String { rawValue.capitalized }
}

/// Raw impact features, kept so calibration can refit the location model later.
public struct ImpactFeatures: Codable, Sendable, Equatable {
    /// Roll-rate jump ÷ swing-axis jump (side-to-side hit position).
    public var rollRatio: Float
    /// Frame ringing (120–250 Hz) at the butt ÷ impact strength (distance from the vibration node).
    public var ringNorm: Float
    /// Handle velocity kick against the ball direction; negative = toward the tip.
    public var jolt: Float
    /// Size of the swing-axis rotation jump, rad/s (impact strength proxy).
    public var impulse: Float

    public init(rollRatio: Float, ringNorm: Float, jolt: Float, impulse: Float) {
        self.rollRatio = rollRatio
        self.ringNorm = ringNorm
        self.jolt = jolt
        self.impulse = impulse
    }
}

/// Everything we know about one shot. Shared by the apps, the Watch and the Gemma coach.
public struct ShotMetrics: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var date: Date
    public var type: ShotType
    public var swingSpeedKmh: Double
    public var ballSpeedKmh: Double
    public var spinRPM: Double
    public var spin: SpinType
    /// Face tilt at contact; positive = open (face tilted up).
    public var faceAngleDeg: Double
    /// Racket path at contact; positive = low to high.
    public var swingPathDeg: Double
    /// Hit location relative to the sweet spot, cm. x = across the face, y = toward the tip.
    public var impactXcm: Double
    public var impactYcm: Double
    public var peakG: Double
    public var gyroSaturated: Bool
    public var features: ImpactFeatures

    public var impactDistanceCm: Double { (impactXcm * impactXcm + impactYcm * impactYcm).squareRoot() }
    public var isSweetSpot: Bool { impactDistanceCm <= ShotMetrics.sweetSpotRadiusCm }
    public static let sweetSpotRadiusCm = 4.0

    public init(date: Date, type: ShotType, swingSpeedKmh: Double, ballSpeedKmh: Double, spinRPM: Double,
                spin: SpinType, faceAngleDeg: Double, swingPathDeg: Double, impactXcm: Double, impactYcm: Double,
                peakG: Double, gyroSaturated: Bool, features: ImpactFeatures) {
        self.date = date
        self.type = type
        self.swingSpeedKmh = swingSpeedKmh
        self.ballSpeedKmh = ballSpeedKmh
        self.spinRPM = spinRPM
        self.spin = spin
        self.faceAngleDeg = faceAngleDeg
        self.swingPathDeg = swingPathDeg
        self.impactXcm = impactXcm
        self.impactYcm = impactYcm
        self.peakG = peakG
        self.gyroSaturated = gyroSaturated
        self.features = features
    }
}

/// Aggregates for a set of shots (a session, or one stroke within it).
public struct ShotSummary: Codable, Sendable, Equatable {
    public var count: Int
    public var sweetSpotPercent: Double
    public var avgSwingKmh: Double
    public var maxSwingKmh: Double
    public var avgBallKmh: Double
    public var maxBallKmh: Double
    public var avgSpinRPM: Double
    public var avgFaceAngle: Double
    public var avgPathAngle: Double
    public var avgImpactX: Double
    public var avgImpactY: Double
    /// Spread of impact positions (cm); lower = more consistent.
    public var impactSpreadCm: Double

    public init(_ shots: [ShotMetrics]) {
        let n = Double(max(shots.count, 1))
        func avg(_ f: (ShotMetrics) -> Double) -> Double { shots.reduce(0) { $0 + f($1) } / n }
        count = shots.count
        sweetSpotPercent = shots.isEmpty ? 0 : Double(shots.filter(\.isSweetSpot).count) / n * 100
        avgSwingKmh = avg(\.swingSpeedKmh)
        maxSwingKmh = shots.map(\.swingSpeedKmh).max() ?? 0
        avgBallKmh = avg(\.ballSpeedKmh)
        maxBallKmh = shots.map(\.ballSpeedKmh).max() ?? 0
        avgSpinRPM = avg(\.spinRPM)
        avgFaceAngle = avg(\.faceAngleDeg)
        avgPathAngle = avg(\.swingPathDeg)
        avgImpactX = avg(\.impactXcm)
        avgImpactY = avg(\.impactYcm)
        let mx = avgImpactX, my = avgImpactY
        impactSpreadCm = (shots.reduce(0) { $0 + pow($1.impactXcm - mx, 2) + pow($1.impactYcm - my, 2) } / n).squareRoot()
    }
}
