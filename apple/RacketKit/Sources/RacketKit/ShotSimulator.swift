import Foundation

/// A bounded sensitivity model, not a validated ball-flight predictor.
/// Speed and spin follow ShotAnalyzer's impact model; side spin and trajectory are not modeled.
public enum ShotSimulator {
    public struct Parameters: Codable, Sendable, Equatable {
        public var swingSpeedKmh: Double
        public var pathAngleDeg: Double
        public var faceAngleDeg: Double
        public var contactXcm: Double
        public var contactYcm: Double
        public var incomingSpeedKmh: Double

        public init(swingSpeedKmh: Double, pathAngleDeg: Double, faceAngleDeg: Double,
                    contactXcm: Double, contactYcm: Double, incomingSpeedKmh: Double = 43.2) {
            self.swingSpeedKmh = swingSpeedKmh
            self.pathAngleDeg = pathAngleDeg
            self.faceAngleDeg = faceAngleDeg
            self.contactXcm = contactXcm
            self.contactYcm = contactYcm
            self.incomingSpeedKmh = incomingSpeedKmh
        }

        public var clamped: Self {
            Self(swingSpeedKmh: bounded(swingSpeedKmh, 0...200),
                 pathAngleDeg: bounded(pathAngleDeg, -80...80),
                 faceAngleDeg: bounded(faceAngleDeg, -60...60),
                 contactXcm: bounded(contactXcm, -12...12), contactYcm: bounded(contactYcm, -14...14),
                 incomingSpeedKmh: bounded(incomingSpeedKmh, 0...200))
        }
    }

    public struct Result: Codable, Sendable, Equatable {
        public var parameters: Parameters
        public var ballSpeedKmh: Double
        public var spinRPM: Double
        public var spin: SpinType
        public var estimated: Bool { true }
    }

    /// Non-finite inputs become zero before clamping. No unmeasured launch/landing numbers are returned.
    public static func simulate(_ input: Parameters, model: ImpactModel = ImpactModel()) -> Result {
        let p = input.clamped
        let distance = hypot(p.contactXcm, p.contactYcm)
        let e = bounded(Double(model.acorCenter), 0...1) * max(0.55, 1 - 0.035 * distance)
        let speed = p.swingSpeedKmh / 3.6
        let brush = speed * sin((p.pathAngleDeg - p.faceAngleDeg) * .pi / 180)
        let rpm = bounded(Double(model.spinGain), 0...1) * abs(brush) / 0.0335 * 60 / (2 * .pi)
        return Result(parameters: p, ballSpeedKmh: e * p.incomingSpeedKmh + (1 + e) * p.swingSpeedKmh,
                      spinRPM: rpm, spin: rpm < 600 ? .flat : (brush > 0 ? .topspin : .slice))
    }

    private static func bounded(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : 0))
    }
}
