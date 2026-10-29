import Foundation
import simd

/// Maps sensor axes to racket axes and removes gyro bias.
/// Racket frame: x = along the handle toward the tip, y = across the face, z = face normal.
public struct Calibration: Codable, Sendable, Equatable {
    /// Rows are the racket x, y, z axes expressed in MPU6050 sensor coordinates.
    public var mpuToRacket: simd_float3x3
    /// Same for the high-g accelerometer (the H3LIS331 on the original board; the LSM6DSV320X's high-g channel now).
    public var h3lisToRacket: simd_float3x3
    public var gyroBias: SIMD3<Float>
    public var h3lisBias: SIMD3<Float>
    public var isCalibrated: Bool
    /// Corrects MPU6050 clones whose accelerometer doesn't read exactly 1 g at rest (measured during calibration).
    public var accelScale: Float = 1

    /// Default from the CAD: both boards lie flat along the handle, MPU6050 Y axis along the handle.
    public static let `default` = Calibration(
        mpuToRacket: simd_float3x3(rows: [SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)]),
        h3lisToRacket: simd_float3x3(rows: [SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)]),
        gyroBias: .zero, h3lisBias: .zero, isCalibrated: false)

    /// Identity mapping, used by the simulator, which already produces racket-frame data.
    public static let identity = Calibration(
        mpuToRacket: matrix_identity_float3x3, h3lisToRacket: matrix_identity_float3x3,
        gyroBias: .zero, h3lisBias: .zero, isCalibrated: true)

    public func apply(_ s: IMUSample) -> IMUSample {
        IMUSample(time: s.time,
                  accel: mpuToRacket * s.accel * accelScale,
                  gyro: mpuToRacket * (s.gyro - gyroBias),
                  highG: h3lisToRacket * (s.highG - h3lisBias))
    }

    /// Mean readings while holding still in one pose.
    public struct PoseReading: Codable, Sendable {
        public var accel: SIMD3<Float>
        public var gyro: SIMD3<Float>
        public var highG: SIMD3<Float>

        public init(samples: [IMUSample]) {
            let n = Float(max(samples.count, 1))
            accel = samples.reduce(.zero) { $0 + $1.accel } / n
            gyro = samples.reduce(.zero) { $0 + $1.gyro } / n
            highG = samples.reduce(.zero) { $0 + $1.highG } / n
        }
    }

    /// Builds a calibration from two still poses: tip pointing straight up, then lying flat face-up.
    /// The LSM6DSV320X's high-g accelerometer shares the low-g one's axes (same die), so both use the rotation
    /// fitted from the precise low-g reading. Gravity is only about 10 high-g counts at the 200 g range, so fitting
    /// from it could pick the wrong axis or sign and corrupt every impact feature.
    public static func from(tipUp: PoseReading, faceUp: PoseReading) -> Calibration {
        let mpu = rotation(up1: tipUp.accel, up2: faceUp.accel)
        let h3 = mpu
        // H3LIS zero-g offset: average reading minus the gravity it should see (+1 g on racket z when face up).
        let expectedFaceUp = h3.transpose * SIMD3<Float>(0, 0, 1)
        let restMagnitude = (simd_length(tipUp.accel) + simd_length(faceUp.accel)) / 2
        var cal = Calibration(mpuToRacket: mpu, h3lisToRacket: h3,
                              gyroBias: (tipUp.gyro + faceUp.gyro) / 2,
                              h3lisBias: faceUp.highG - expectedFaceUp,
                              isCalibrated: true)
        cal.accelScale = restMagnitude > 0.3 ? 1 / restMagnitude : 1
        return cal
    }

    /// Accelerometers read +1 g pointing up, so tip-up gives racket x and face-up gives racket z.
    static func rotation(up1: SIMD3<Float>, up2: SIMD3<Float>) -> simd_float3x3 {
        let x = simd_normalize(up1)
        var z = up2 - simd_dot(up2, x) * x
        z = simd_length(z) > 1e-4 ? simd_normalize(z) : SIMD3(0, 0, 1)
        let y = simd_cross(z, x)
        return simd_float3x3(rows: [x, y, z])
    }
}

extension simd_float3x3: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let a = try c.decode([Float].self)
        self.init(rows: [SIMD3(a[0], a[1], a[2]), SIMD3(a[3], a[4], a[5]), SIMD3(a[6], a[7], a[8])])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        let t = transpose
        try c.encode([t[0].x, t[0].y, t[0].z, t[1].x, t[1].y, t[1].z, t[2].x, t[2].y, t[2].z])
    }
}

/// A person who hits with the racket. One racket can have many players.
public struct PlayerProfile: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var rightHanded: Bool = true
    /// Height in meters. Optional so it can stay blank.
    public var heightM: Float?

    public init(name: String, rightHanded: Bool = true, heightM: Float? = nil) {
        self.name = name
        self.rightHanded = rightHanded
        self.heightM = heightM
    }
}

/// Physical racket constants used by the shot physics. Edit after the ME measures the racket.
public struct RacketProfile: Codable, Sendable, Equatable {
    public var name: String = "Yonex VCore 98"
    public var massKg: Float = 0.325
    public var lengthM: Float = 0.686
    public var balancePointM: Float = 0.320
    /// Distance from the butt to the center of the string bed.
    public var stringCenterM: Float = 0.520
    /// Distance from the butt to the MPU6050 chip (from the CAD).
    public var imuFromButtM: Float = 0.039
    /// Effective rotation radius for swing speed (shoulder to sweet spot), tuned against slow-mo video.
    public var effectiveRadiusM: Float = 1.15
    /// Handedness of the active player. The app copies it from `PlayerProfile` when the player changes.
    public var rightHanded: Bool = true

    public init() {}
}
