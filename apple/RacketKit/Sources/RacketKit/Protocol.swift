import Foundation
import simd

/// BLE protocol shared with the firmware. Keep in sync with firmware/include/protocol.h.
public enum RacketProtocol {
    public static let deviceName = "Tennis Buddy"
    public static let serviceUUID = "7E5B0001-6B1D-4D8E-9C1A-7E5B7E5B0001"
    public static let imuUUID = "7E5B0002-6B1D-4D8E-9C1A-7E5B7E5B0001"
    public static let statusUUID = "7E5B0003-6B1D-4D8E-9C1A-7E5B7E5B0001"
    public static let controlUUID = "7E5B0004-6B1D-4D8E-9C1A-7E5B7E5B0001"
    /// On-device ML verdict (sweet spot or not, and how far off), one notification per impact.
    public static let shotUUID = "7E5B0005-6B1D-4D8E-9C1A-7E5B7E5B0001"
    /// Handle-tap gesture (single/double/triple), one notification per gesture. Firmware 1.2+.
    public static let tapUUID = "7E5B0006-6B1D-4D8E-9C1A-7E5B7E5B0001"
    /// Impact mode (firmware 1.5+): the racket detects hits itself and sends only the samples around each one.
    /// A hit the moment it's seen, then its window in chunks, plus ~30 Hz orientation for live views.
    public static let hitUUID = "7E5B0008-6B1D-4D8E-9C1A-7E5B7E5B0001"
    public static let windowUUID = "7E5B0009-6B1D-4D8E-9C1A-7E5B7E5B0001"
    public static let poseUUID = "7E5B000A-6B1D-4D8E-9C1A-7E5B7E5B0001"

    // Legacy OTA firmware used 0006 for a writable control characteristic; tap firmware uses
    // that UUID for a notify-only gesture. RacketBLE distinguishes them by characteristic properties.
    public static let otaControlUUID = "7E5B0006-6B1D-4D8E-9C1A-7E5B7E5B0001"
    public static let otaDataUUID = "7E5B0007-6B1D-4D8E-9C1A-7E5B7E5B0001"
    public static let otaWindow = 4096

    public static let samplesPerPacket = 8
    public static let packetSize = 152
    public static let sampleRate: Double = 1000

    /// Impact window: samples before and after the impact sample (firmware TB_WINDOW_PRE / TB_WINDOW_POST).
    public static let windowPre = 384
    public static let windowPost = 64
    public static let windowSamples = windowPre + windowPost
    public static let windowChunkSize = 164

    public static let mpuAccelLSBPerG: Float = 2048
    public static let mpuGyroLSBPerDps: Float = 16.4

    public enum Command: UInt8 {
        case startStream = 0x01
        case stopStream = 0x02
        case h3lisRange = 0x10
        /// Second byte 1 = ±4000 dps (gyro at 8.2 LSB/dps, flagged per packet), 0 = ±2000 dps. Firmware 1.3+.
        case gyroRange = 0x11
        /// Second byte: a `StreamMode`. Firmware 1.5+; older firmware ignores it and keeps streaming raw.
        case streamMode = 0x12
    }

    public enum StreamMode: UInt8, Sendable {
        /// Every sample on the IMU characteristic; the app detects hits.
        case raw = 0
        /// Hits, their windows and live orientation only; the racket detects hits.
        case impacts = 1
    }

    /// Packet flag: this packet's gyro is at ±4000 dps, 8.2 LSB/dps.
    public static let flagGyro4000: UInt8 = 1 << 3
    public static let flagMotionOK: UInt8 = 1 << 0
    /// Status flag: the racket is in impact mode.
    public static let flagImpactMode: UInt8 = 1 << 4

    public enum OTACommand: UInt8 {
        case begin = 0x01   // then UInt32 size, UInt32 CRC-32 (little-endian)
        case end = 0x02
        case abort = 0x03
    }

    public enum OTAReply: UInt8 {
        case ready = 0x00
        case progress = 0x01   // then UInt32 bytes written
        case done = 0x02
        case error = 0x7F      // then UInt8 error code
    }

    public static func otaErrorMessage(_ code: UInt8) -> String {
        switch code {
        case 1: "The racket couldn't start the update (image too large?)"
        case 2: "The racket couldn't write to its flash"
        case 3: "The image size didn't match what was sent"
        case 4: "The image was corrupted in transit"
        case 5: "That file isn't valid racket firmware"
        case 6: "The racket wasn't expecting that step"
        default: "The racket reported update error \(code)"
        }
    }

    /// mg per 12-bit count for each H3LIS range code.
    public static func h3lisGPerCount(range: UInt8) -> Float {
        switch range {
        case 0: return 0.049
        case 3: return 0.195
        default: return 0.098
        }
    }

    public struct Packet: Sendable {
        public var seq: UInt16
        public var t0Micros: UInt32
        public var flags: UInt8
        public var samples: [RawSample]
    }

    public struct RawSample: Sendable {
        public var ax, ay, az, gx, gy, gz, hx, hy, hz: Int16
    }

    public struct Status: Sendable, Equatable {
        public var batteryMillivolts: UInt16
        public var firmwareVersion: String
        public var mpuOK: Bool
        public var h3lisOK: Bool
        public var streaming: Bool
        public var h3lisRange: UInt8
        public var droppedPackets: UInt16
        public var impactMode = false
        /// The gyro is at ±4000 dps (firmware 1.3+ reports it; 1.6+ starts there).
        public var gyro4000 = false

        public init(batteryMillivolts: UInt16, firmwareVersion: String, mpuOK: Bool, h3lisOK: Bool, streaming: Bool,
                    h3lisRange: UInt8, droppedPackets: UInt16, impactMode: Bool = false, gyro4000: Bool = false) {
            self.batteryMillivolts = batteryMillivolts; self.firmwareVersion = firmwareVersion
            self.mpuOK = mpuOK; self.h3lisOK = h3lisOK; self.streaming = streaming; self.h3lisRange = h3lisRange
            self.droppedPackets = droppedPackets; self.impactMode = impactMode; self.gyro4000 = gyro4000
        }
    }

    public enum HitSource: UInt8, Sendable {
        /// A high-g jump during a swing.
        case motion = 1
        /// The mic heard it and a smaller high-g jump confirmed it (blocks, soft volleys).
        case mic = 2
    }

    /// Sent by the racket the moment it detects a hit; the window with the same `seq` follows.
    public struct Hit: Sendable, Equatable {
        public var seq: UInt16
        public var tMicros: UInt32
        public var source: HitSource
        public var jumpG: Int
        public var swingDps: Int
        /// Sensor axes → world (z up), from the racket's own orientation filter.
        public var orientation: simd_quatf
    }

    /// One slice of a hit's window. Gyro is always at 8.2 LSB/dps, whatever range the racket is in.
    public struct WindowChunk: Sendable {
        public var seq: UInt16
        public var index: Int
        public var total: Int
        /// Index of the impact sample in the whole window.
        public var impact: Int
        /// Sensor axes → world at the window's first sample.
        public var startOrientation: simd_quatf
        public var t0Micros: UInt32
        public var samples: [RawSample]
    }

    /// Live orientation in impact mode, ~30 Hz.
    public struct Pose: Sendable {
        public var orientation: simd_quatf
        public var gyroDps: Float
        public var highG: Float
        public var flags: UInt8
    }

    static func quaternion(_ b: [UInt8], at o: Int) -> simd_quatf {
        func c(_ k: Int) -> Float { Float(Int16(bitPattern: UInt16(b[o + 2 * k]) | UInt16(b[o + 2 * k + 1]) << 8)) / 16384 }
        return simd_normalize(simd_quatf(ix: c(1), iy: c(2), iz: c(3), r: c(0)))
    }

    static func rawSample(_ b: [UInt8], at o: Int) -> RawSample {
        func i16(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8) }
        return RawSample(ax: i16(o), ay: i16(o + 2), az: i16(o + 4), gx: i16(o + 6), gy: i16(o + 8), gz: i16(o + 10),
                         hx: i16(o + 12), hy: i16(o + 14), hz: i16(o + 16))
    }

    public static func decodeHit(_ data: Data) -> Hit? {
        guard data.count >= 18 else { return nil }
        let b = [UInt8](data)
        let t = UInt32(b[2]) | UInt32(b[3]) << 8 | UInt32(b[4]) << 16 | UInt32(b[5]) << 24
        return Hit(seq: UInt16(b[0]) | UInt16(b[1]) << 8, tMicros: t, source: HitSource(rawValue: b[6]) ?? .motion,
                   jumpG: Int(b[7]), swingDps: Int(UInt16(b[8]) | UInt16(b[9]) << 8), orientation: quaternion(b, at: 10))
    }

    public static func decodeWindowChunk(_ data: Data) -> WindowChunk? {
        guard data.count >= 20 else { return nil }
        let b = [UInt8](data)
        let count = Int(b[18])
        guard data.count >= 20 + count * 18 else { return nil }
        let t0 = UInt32(b[14]) | UInt32(b[15]) << 8 | UInt32(b[16]) << 16 | UInt32(b[17]) << 24
        return WindowChunk(seq: UInt16(b[0]) | UInt16(b[1]) << 8, index: Int(b[2]), total: Int(b[3]),
                           impact: Int(UInt16(b[4]) | UInt16(b[5]) << 8), startOrientation: quaternion(b, at: 6),
                           t0Micros: t0, samples: (0..<count).map { rawSample(b, at: 20 + $0 * 18) })
    }

    public static func decodePose(_ data: Data) -> Pose? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data)
        return Pose(orientation: quaternion(b, at: 0), gyroDps: Float(UInt16(b[8]) | UInt16(b[9]) << 8),
                    highG: Float(b[10]), flags: b[11])
    }

    /// The racket's own sweet-spot verdict from its on-device model (firmware/src/sweetspot.cpp, ml/README.md).
    public struct ShotVerdict: Sendable, Equatable {
        public var seq: UInt16
        public var isSweet: Bool
        /// 0 when sweet; otherwise roughly 33...100, how far toward the frame the ball hit (100 = at the frame).
        public var offCenterPercent: Int
        public var confidencePercent: Int
        /// Impact loudness 0...255 (near 255 means the mic clipped).
        public var level: Int
    }

    public static func decodeShotVerdict(_ data: Data) -> ShotVerdict? {
        guard data.count >= 6 else { return nil }
        let b = [UInt8](data)
        return ShotVerdict(seq: UInt16(b[0]) | UInt16(b[1]) << 8, isSweet: b[2] != 0,
                           offCenterPercent: Int(b[3]), confidencePercent: Int(b[4]), level: Int(b[5]))
    }

    /// Taps on the handle, grouped by the racket into one gesture (firmware/src/tap.cpp). Swings and ball
    /// impacts are filtered out on the racket.
    public struct TapGesture: Sendable, Equatable {
        public var seq: UInt16
        /// Taps in the gesture: 1 single, 2 double, 3+ triple.
        public var count: Int
        /// Strongest tap's jolt, 0...255 (255 = 2 g or more).
        public var strength: Int
        /// Strongest tap's push direction, unit vector in accel (sensor) axes. See TapCalibration.
        public var direction: SIMD3<Float>

        public init(seq: UInt16, count: Int, strength: Int, direction: SIMD3<Float>) {
            self.seq = seq
            self.count = count
            self.strength = strength
            self.direction = direction
        }
    }

    public static func decodeTap(_ data: Data) -> TapGesture? {
        guard data.count >= 9 else { return nil }
        let b = [UInt8](data)
        let dir = SIMD3(Float(Int8(bitPattern: b[6])), Float(Int8(bitPattern: b[7])), Float(Int8(bitPattern: b[8]))) / 127
        return TapGesture(seq: UInt16(b[0]) | UInt16(b[1]) << 8, count: Int(b[2]), strength: Int(b[3]), direction: dir)
    }

    public static func decodePacket(_ data: Data) -> Packet? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        let seq = u16(0)
        let t0 = UInt32(u16(2)) | UInt32(u16(4)) << 16
        let count = Int(bytes[6])
        let flags = bytes[7]
        guard data.count >= 8 + count * 18 else { return nil }
        let samples = (0..<count).map { rawSample(bytes, at: 8 + $0 * 18) }
        return Packet(seq: seq, t0Micros: t0, flags: flags, samples: samples)
    }

    public static func decodeStatus(_ data: Data) -> Status? {
        guard data.count >= 8 else { return nil }
        let b = [UInt8](data)
        return Status(
            batteryMillivolts: UInt16(b[0]) | UInt16(b[1]) << 8,
            firmwareVersion: "\(b[2]).\(b[3])",
            mpuOK: b[4] & 1 != 0,
            h3lisOK: b[4] & 2 != 0,
            streaming: b[4] & 4 != 0,
            h3lisRange: b[5],
            droppedPackets: UInt16(b[6]) | UInt16(b[7]) << 8,
            impactMode: b[4] & flagImpactMode != 0,
            gyro4000: b[4] & flagGyro4000 != 0)
    }

    /// Converts a raw sample to physical units in the sensor frames.
    public static func convert(_ r: RawSample, time: Double, h3lisRange: UInt8,
                               gyroLSBPerDps: Float = mpuGyroLSBPerDps) -> IMUSample {
        let gPerCount = h3lisGPerCount(range: h3lisRange)
        let dps2rad = Float.pi / 180
        return IMUSample(
            time: time,
            accel: SIMD3(Float(r.ax), Float(r.ay), Float(r.az)) / mpuAccelLSBPerG,
            gyro: SIMD3(Float(r.gx), Float(r.gy), Float(r.gz)) / gyroLSBPerDps * dps2rad,
            highG: SIMD3(Float(r.hx >> 4), Float(r.hy >> 4), Float(r.hz >> 4)) * gPerCount)
    }
}

/// One 1 kHz sample in physical units.
/// `accel` and `highG` are in g, `gyro` in rad/s. Before calibration these are sensor axes;
/// after `Calibration.apply` they are racket axes (x = toward the tip, y = across the face, z = face normal).
public struct IMUSample: Sendable, Codable, Equatable {
    public var time: Double
    public var accel: SIMD3<Float>
    public var gyro: SIMD3<Float>
    public var highG: SIMD3<Float>

    public init(time: Double, accel: SIMD3<Float>, gyro: SIMD3<Float>, highG: SIMD3<Float>) {
        self.time = time
        self.accel = accel
        self.gyro = gyro
        self.highG = highG
    }

    /// Best available acceleration: the precise MPU6050 below ~14 g, the H3LIS331 above (MPU saturates at 16 g).
    public var fusedAccel: SIMD3<Float> {
        simd_length(accel) < 14 ? accel : highG
    }

    /// Just under the gyro's full scale; RacketBLE raises it while the racket streams at ±4000 dps.
    public static var gyroSaturation: Float = 1990 * .pi / 180
    public var gyroSaturated: Bool {
        abs(gyro.x) > Self.gyroSaturation || abs(gyro.y) > Self.gyroSaturation || abs(gyro.z) > Self.gyroSaturation
    }
}
