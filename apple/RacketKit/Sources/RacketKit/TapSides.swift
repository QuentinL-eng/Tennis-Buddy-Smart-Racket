import Foundation
import simd

/// The handle is an elongated octagon: two wide sides parallel to the string bed and two narrower sides on
/// the edges. A tap pushes the handle along the normal of the side it lands on, so the racket's push
/// direction (RacketProtocol.TapGesture.direction) says which kind of side was hit.
public enum TapSide: String, Codable, Sendable {
    case wide, narrow
    public var label: String { self == .wide ? "Wide side" : "Narrow side" }
}

/// Score keeping by handle taps.
public enum ScoreCommand: Equatable, Sendable {
    /// Double tap (on a wide side, or any side before the taps are calibrated): you won the point.
    case won
    /// Single tap (on a narrow side, or any side before calibration): your opponent won the point.
    case lost
    /// Triple tap anywhere: take back the last point.
    case undo

    public static func from(count: Int, side: TapSide?) -> ScoreCommand? {
        if count >= 3 { return .undo }
        // An unknown side (taps not calibrated, or an unclear tap) still counts: double tap = you, single = them.
        if count == 2 && side != .narrow { return .won }
        if count == 1 && side != .wide { return .lost }
        return nil
    }
}

/// Which push direction belongs to which side, in the racket's accel (sensor) axes. Directions are compared
/// without their sign, because opposite sides of the handle push the same axis in opposite directions.
public struct TapCalibration: Codable, Sendable, Equatable {
    public var wideAxis: SIMD3<Float>
    public var narrowAxis: SIMD3<Float>
    /// False while the axes come from the racket calibration rather than recorded taps.
    public var isCalibrated: Bool

    /// Below this difference in |cos| between the two axes the side is reported as unknown.
    public static let minimumMargin: Float = 0.15

    public init(wideAxis: SIMD3<Float>, narrowAxis: SIMD3<Float>, isCalibrated: Bool) {
        self.wideAxis = simd_normalize(wideAxis)
        self.narrowAxis = simd_normalize(narrowAxis)
        self.isCalibrated = isCalibrated
    }

    /// Best guess before any taps are recorded: the wide sides face along the string-bed normal (racket z),
    /// the narrow sides across the face (racket y).
    public static func fromRacket(_ c: Calibration) -> TapCalibration {
        let rows = c.mpuToRacket.transpose
        return TapCalibration(wideAxis: rows[2], narrowAxis: rows[1], isCalibrated: false)
    }

    /// Fits each side's axis from recorded tap directions. Needs at least two taps per side.
    public static func fit(wide: [SIMD3<Float>], narrow: [SIMD3<Float>]) -> TapCalibration? {
        guard let w = principalAxis(wide), let n = principalAxis(narrow) else { return nil }
        return TapCalibration(wideAxis: w, narrowAxis: n, isCalibrated: true)
    }

    /// The side a push direction points at, and the |cos| margin over the other side (0...1).
    public func classify(_ direction: SIMD3<Float>) -> (side: TapSide, margin: Float)? {
        guard simd_length(direction) > 1e-3 else { return nil }
        let d = simd_normalize(direction)
        let w = abs(simd_dot(d, wideAxis)), n = abs(simd_dot(d, narrowAxis))
        guard abs(w - n) >= Self.minimumMargin else { return nil }
        return w > n ? (.wide, w - n) : (.narrow, n - w)
    }

    /// Angle between the two axes, 0...90°. Near 90° the sides are easy to tell apart; under ~40° they are not.
    public var separationDegrees: Float {
        acos(min(1, abs(simd_dot(wideAxis, narrowAxis)))) * 180 / .pi
    }

    /// Sign-free mean direction: the dominant eigenvector of the sum of outer products d·dᵀ.
    static func principalAxis(_ dirs: [SIMD3<Float>]) -> SIMD3<Float>? {
        let units = dirs.filter { simd_length($0) > 1e-3 }.map { simd_normalize($0) }
        guard units.count >= 2 else { return nil }
        var m = simd_float3x3()
        for d in units { m = m + simd_float3x3(columns: (d * d.x, d * d.y, d * d.z)) }
        // Power iteration from the direction that agrees best with the others.
        var v = units.max { a, b in
            units.reduce(0) { $0 + abs(simd_dot(a, $1)) } < units.reduce(0) { $0 + abs(simd_dot(b, $1)) }
        }!
        for _ in 0..<32 {
            let next = m * v
            guard simd_length(next) > 1e-6 else { break }
            v = simd_normalize(next)
        }
        return v
    }
}
