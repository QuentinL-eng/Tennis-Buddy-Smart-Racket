import Foundation
import simd

/// BLE protocol shared with the firmware. Keep in sync with firmware/include/protocol.h.
public enum RacketProtocol {
    public static let deviceName = "Tennis Buddy"
    public static let serviceUUID = "7E5B0001-6B1D-4D8E-9C1A-7E5B7E5B0001"
    public static let imuUUID = "7E5B0002-6B1D-4D8E-9C1A-7E5B7E5B0001"
    public static let statusUUID = "7E5B0003-6B1D-4D8E-9C1A-7E5B7E5B0001"
    public static let controlUUID = "7E5B0004-6B1D-4D8E-9C1A-7E5B7E5B0001"

    public static let samplesPerPacket = 8
    public static let packetSize = 152
    public static let sampleRate: Double = 1000

    public static let mpuAccelLSBPerG: Float = 2048
    public static let mpuGyroLSBPerDps: Float = 16.4

    public enum Command: UInt8 {
        case startStream = 0x01
        case stopStream = 0x02
        case h3lisRange = 0x10
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
    }

    public static func decodePacket(_ data: Data) -> Packet? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        func i16(_ i: Int) -> Int16 { Int16(bitPattern: u16(i)) }
        let seq = u16(0)
        let t0 = UInt32(u16(2)) | UInt32(u16(4)) << 16
        let count = Int(bytes[6])
        let flags = bytes[7]
        guard data.count >= 8 + count * 18 else { return nil }
        var samples: [RawSample] = []
        samples.reserveCapacity(count)
        for k in 0..<count {
            let o = 8 + k * 18
            samples.append(RawSample(ax: i16(o), ay: i16(o + 2), az: i16(o + 4),
                                     gx: i16(o + 6), gy: i16(o + 8), gz: i16(o + 10),
                                     hx: i16(o + 12), hy: i16(o + 14), hz: i16(o + 16)))
        }
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
            droppedPackets: UInt16(b[6]) | UInt16(b[7]) << 8)
    }

    /// Converts a raw sample to physical units in the sensor frames.
    public static func convert(_ r: RawSample, time: Double, h3lisRange: UInt8) -> IMUSample {
        let gPerCount = h3lisGPerCount(range: h3lisRange)
        let dps2rad = Float.pi / 180
        return IMUSample(
            time: time,
            accel: SIMD3(Float(r.ax), Float(r.ay), Float(r.az)) / mpuAccelLSBPerG,
            gyro: SIMD3(Float(r.gx), Float(r.gy), Float(r.gz)) / mpuGyroLSBPerDps * dps2rad,
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

    public static let gyroSaturation: Float = 1990 * .pi / 180
    public var gyroSaturated: Bool {
        abs(gyro.x) > Self.gyroSaturation || abs(gyro.y) > Self.gyroSaturation || abs(gyro.z) > Self.gyroSaturation
    }
}
