import Foundation

public enum ShotType: String, Codable, Sendable, CaseIterable, Identifiable {
    case forehand, backhand, serve, volley, hit, calibration
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .forehand: "Forehand"
        case .backhand: "Backhand"
        case .serve: "Serve"
        case .volley: "Volley"
        case .hit: "Hit"
        case .calibration: "Calibration"
        }
    }
    public var symbol: String {
        switch self {
        case .forehand: "arrow.turn.up.left"
        case .backhand: "arrow.turn.up.right"
        case .serve: "arrow.up.circle"
        case .volley: "hand.raised"
        case .hit: "tennisball"
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
    /// Racket-frame rotation about the across-face axis just before contact, rad/s. Its sign tells forehand from
    /// backhand without the orientation estimate. Optional so older saved shots still decode.
    public var spinAxisY: Float?
    /// Share of the pre-contact rotation that is about world vertical, -1...1, positive the player's forehand way
    /// (counter-clockwise from above for a right-hander); serves and backhands turn the other way. Optional like
    /// `spinAxisY`.
    public var verticalSpin: Float?
    /// Degrees the racket turned in the 350 ms before contact; volleys are short swings. Optional like `spinAxisY`.
    public var swingDeg: Float?

    public init(rollRatio: Float, ringNorm: Float, jolt: Float, impulse: Float, spinAxisY: Float? = nil) {
        self.rollRatio = rollRatio
        self.ringNorm = ringNorm
        self.jolt = jolt
        self.impulse = impulse
        self.spinAxisY = spinAxisY
    }
}

/// Everything we know about one shot. Shared by the apps, the Watch and the coach.
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
    /// True when only the racket's mic heard this hit (motion sensors offline): sweet spot and distance are
    /// known, but speeds, spin and angles are not. Optional so older saved shots still decode.
    public var micOnly: Bool?
    public var hasMotion: Bool { micOnly != true }

    /// A hit known only from the racket's on-device sound model.
    public static func fromMic(sweet: Bool, offCenterPercent: Int, date: Date = Date()) -> ShotMetrics {
        // 100% off = at the frame, ~12 cm from the sweet spot. Direction is unknown, so it's drawn toward the tip.
        let distance = sweet ? 1.0 : max(Double(offCenterPercent) / 100 * 12, sweetSpotRadiusCm + 0.5)
        var shot = ShotMetrics(date: date, type: .hit, swingSpeedKmh: 0, ballSpeedKmh: 0, spinRPM: 0, spin: .flat,
                               faceAngleDeg: 0, swingPathDeg: 0, impactXcm: 0, impactYcm: distance, peakG: 0,
                               gyroSaturated: false,
                               features: ImpactFeatures(rollRatio: 0, ringNorm: 0, jolt: 0, impulse: 0))
        shot.micOnly = true
        return shot
    }

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
        // Speeds, spin and angles only exist for shots the motion sensors saw.
        let moving = shots.filter(\.hasMotion)
        let nm = Double(max(moving.count, 1))
        func avg(_ f: (ShotMetrics) -> Double) -> Double { shots.reduce(0) { $0 + f($1) } / n }
        func avgMoving(_ f: (ShotMetrics) -> Double) -> Double { moving.reduce(0) { $0 + f($1) } / nm }
        count = shots.count
        sweetSpotPercent = shots.isEmpty ? 0 : Double(shots.filter(\.isSweetSpot).count) / n * 100
        avgSwingKmh = avgMoving(\.swingSpeedKmh)
        maxSwingKmh = shots.map(\.swingSpeedKmh).max() ?? 0
        avgBallKmh = avgMoving(\.ballSpeedKmh)
        maxBallKmh = shots.map(\.ballSpeedKmh).max() ?? 0
        avgSpinRPM = avgMoving(\.spinRPM)
        avgFaceAngle = avgMoving(\.faceAngleDeg)
        avgPathAngle = avgMoving(\.swingPathDeg)
        avgImpactX = avg(\.impactXcm)
        avgImpactY = avg(\.impactYcm)
        let mx = avgImpactX, my = avgImpactY
        impactSpreadCm = (shots.reduce(0) { $0 + pow($1.impactXcm - mx, 2) + pow($1.impactYcm - my, 2) } / n).squareRoot()
    }
}
