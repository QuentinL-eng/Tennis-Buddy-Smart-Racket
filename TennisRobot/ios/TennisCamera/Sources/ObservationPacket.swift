import CoreMedia
import Foundation

/// Fixed 40-byte observation packet shared with `tools/iproxy_receiver.py` and,
/// later, the Windows PC's `RemoteObservationSource`.
///
/// Little-endian, no padding, no framing beyond the 40 bytes:
///
///     offset  size  field
///     0       4     magic          UInt32 = 0x424F5254 ("TROB" on the wire)
///     4       1     version        UInt8  = 1
///     5       1     kind           UInt8  = 0 observation, 1 status,
///                                    2 flight state, 3 intercept
///     6       2     header_size    UInt16 = 40
///     8       4     sequence       UInt32
///     12      8     t_capture_ns   UInt64
///     20      4     u              Float32
///     24      4     v              Float32
///     28      4     radius         Float32
///     32      4     confidence     Float32
///     36      2     width          UInt16
///     38      2     height         UInt16
///
/// Python equivalent: `struct.Struct("<I B B H I Q f f f f H H")`.
struct ObservationPacket {
    static let magic: UInt32 = 0x424F_5254
    static let version: UInt8 = 1
    static let headerSize: UInt16 = 40
    static let byteCount = 40

    enum Kind: UInt8 {
        case observation = 0
        case status = 1
        /// Fitted 3D state, camera frame, metres.
        case state = 2
        /// Predicted crossing of the plane in front of the camera.
        case intercept = 3
    }

    var kind: Kind
    var sequence: UInt32
    /// Presentation timestamp of the sample buffer, in nanoseconds. Never the
    /// wall clock at send time.
    var tCaptureNs: UInt64
    var u: Float
    var v: Float
    var radius: Float
    var confidence: Float
    var width: UInt16
    var height: UInt16

    static func observation(
        _ detection: BallDetection,
        sequence: UInt32,
        tCaptureNs: UInt64,
        width: Int,
        height: Int
    ) -> ObservationPacket {
        ObservationPacket(
            kind: .observation,
            sequence: sequence,
            tCaptureNs: tCaptureNs,
            u: detection.u,
            v: detection.v,
            radius: detection.radius,
            confidence: detection.confidence,
            width: UInt16(clamping: width),
            height: UInt16(clamping: height)
        )
    }

    /// Status packets reuse the same layout with a different meaning:
    /// `u` = measured fps, `v` = median detector ms, `radius` = dropped frames,
    /// `confidence` = thermal state (0 nominal ... 3 critical).
    static func status(
        sequence: UInt32,
        tCaptureNs: UInt64,
        measuredFPS: Double,
        detectorMedianMs: Double,
        droppedFrames: Int,
        thermalState: Int,
        width: Int,
        height: Int
    ) -> ObservationPacket {
        ObservationPacket(
            kind: .status,
            sequence: sequence,
            tCaptureNs: tCaptureNs,
            u: Float(measuredFPS),
            v: Float(detectorMedianMs),
            radius: Float(droppedFrames),
            confidence: Float(thermalState),
            width: UInt16(clamping: width),
            height: UInt16(clamping: height)
        )
    }

    /// `kind = 2`, sent when the tracker produces a fit. Payload in the shared
    /// layout: `u, v, radius` are the ball position **x, y, z in metres in the
    /// camera frame** (`x` right, `y` down, `z` forward), and `confidence` is
    /// the centre residual RMS in pixels. `t_capture_ns` is the capture time of
    /// the newest observation in the fit.
    static func flightState(
        sequence: UInt32,
        tCaptureNs: UInt64,
        x: Double,
        y: Double,
        z: Double,
        rmsPx: Double,
        width: Int,
        height: Int
    ) -> ObservationPacket {
        ObservationPacket(
            kind: .state,
            sequence: sequence,
            tCaptureNs: tCaptureNs,
            u: Float(x),
            v: Float(y),
            radius: Float(z),
            confidence: Float(rmsPx),
            width: UInt16(clamping: width),
            height: UInt16(clamping: height)
        )
    }

    /// `kind = 3`, the predicted crossing of the camera-frame plane `z = const`.
    /// `u, v, radius` are `x, y, z` at that crossing in metres and
    /// `confidence` is the time from `t_capture_ns` to the crossing in seconds.
    /// The PC still has to rotate this into court coordinates; the phone does
    /// not know where the court is.
    static func intercept(
        sequence: UInt32,
        tCaptureNs: UInt64,
        x: Double,
        y: Double,
        z: Double,
        timeToPlaneS: Double,
        width: Int,
        height: Int
    ) -> ObservationPacket {
        ObservationPacket(
            kind: .intercept,
            sequence: sequence,
            tCaptureNs: tCaptureNs,
            u: Float(x),
            v: Float(y),
            radius: Float(z),
            confidence: Float(timeToPlaneS),
            width: UInt16(clamping: width),
            height: UInt16(clamping: height)
        )
    }

    /// The wire encoding of `ProcessInfo.thermalState`: 0 nominal, 1 fair,
    /// 2 serious, 3 critical. Unknown future states report nominal rather than
    /// inventing a value the PC would misread.
    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    /// Encode byte by byte. A Swift struct's memory layout is not the wire
    /// format: padding and field order are both compiler details.
    func encode() -> Data {
        var data = Data(capacity: Self.byteCount)
        data.appendLittleEndian(Self.magic)
        data.appendLittleEndian(Self.version)
        data.appendLittleEndian(kind.rawValue)
        data.appendLittleEndian(Self.headerSize)
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(tCaptureNs)
        data.appendLittleEndianFloat(u)
        data.appendLittleEndianFloat(v)
        data.appendLittleEndianFloat(radius)
        data.appendLittleEndianFloat(confidence)
        data.appendLittleEndian(width)
        data.appendLittleEndian(height)
        return data
    }

    /// Decoder used by the unit tests to prove round-tripping and offsets.
    init?(decoding data: Data) {
        guard data.count == Self.byteCount else { return nil }
        let bytes = [UInt8](data)
        func read<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
            var value: T = 0
            Swift.withUnsafeMutableBytes(of: &value) { raw in
                for i in 0..<MemoryLayout<T>.size {
                    raw[i] = bytes[offset + i]
                }
            }
            return T(littleEndian: value)
        }
        func readFloat(_ offset: Int) -> Float {
            Float(bitPattern: read(offset, UInt32.self))
        }

        guard read(0, UInt32.self) == Self.magic else { return nil }
        guard read(4, UInt8.self) == Self.version else { return nil }
        guard let kind = Kind(rawValue: read(5, UInt8.self)) else { return nil }
        guard read(6, UInt16.self) == Self.headerSize else { return nil }

        self.kind = kind
        self.sequence = read(8, UInt32.self)
        self.tCaptureNs = read(12, UInt64.self)
        self.u = readFloat(20)
        self.v = readFloat(24)
        self.radius = readFloat(28)
        self.confidence = readFloat(32)
        self.width = read(36, UInt16.self)
        self.height = read(38, UInt16.self)
    }

    init(
        kind: Kind,
        sequence: UInt32,
        tCaptureNs: UInt64,
        u: Float,
        v: Float,
        radius: Float,
        confidence: Float,
        width: UInt16,
        height: UInt16
    ) {
        self.kind = kind
        self.sequence = sequence
        self.tCaptureNs = tCaptureNs
        self.u = u
        self.v = v
        self.radius = radius
        self.confidence = confidence
        self.width = width
        self.height = height
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndianFloat(_ value: Float) {
        appendLittleEndian(value.bitPattern)
    }
}

/// Presentation timestamps from `CMSampleBuffer` and wall-clock status stamps
/// both come from the host time clock, so a receiver can compare them.
enum CaptureClock {
    /// Nanoseconds for a `CMTime` without going through `Double` seconds.
    static func nanoseconds(from time: CMTime) -> UInt64 {
        guard time.isValid, !time.isIndefinite, time.timescale > 0 else { return 0 }
        let converted = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
        return converted.value > 0 ? UInt64(converted.value) : 0
    }
}
