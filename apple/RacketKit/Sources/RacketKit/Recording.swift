import Foundation

/// Raw sensor recordings (`.tbrec`): little-endian records of `f64 time` + 9 × `f32`
/// (accel xyz g, gyro xyz rad/s, high-g xyz g), all in sensor axes.
public enum RecordingFormat {
    public static let fileExtension = "tbrec"
    static let recordSize = 8 + 9 * 4

    public static func encode(_ samples: [IMUSample]) -> Data {
        var data = Data(capacity: samples.count * recordSize)
        for s in samples {
            var t = s.time
            withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
            for v in [s.accel.x, s.accel.y, s.accel.z, s.gyro.x, s.gyro.y, s.gyro.z, s.highG.x, s.highG.y, s.highG.z] {
                var f = v
                withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    public static func decode(_ data: Data) -> [IMUSample] {
        let n = data.count / recordSize
        var out: [IMUSample] = []
        out.reserveCapacity(n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let o = i * recordSize
                let t = raw.loadUnaligned(fromByteOffset: o, as: Double.self)
                func f(_ k: Int) -> Float { raw.loadUnaligned(fromByteOffset: o + 8 + k * 4, as: Float.self) }
                out.append(IMUSample(time: t, accel: SIMD3(f(0), f(1), f(2)),
                                     gyro: SIMD3(f(3), f(4), f(5)), highG: SIMD3(f(6), f(7), f(8))))
            }
        }
        return out
    }

    public static func csv(_ samples: [IMUSample]) -> String {
        var s = "time_s,ax_g,ay_g,az_g,gx_rads,gy_rads,gz_rads,hx_g,hy_g,hz_g\n"
        for x in samples {
            s += String(format: "%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f\n", x.time,
                        x.accel.x, x.accel.y, x.accel.z, x.gyro.x, x.gyro.y, x.gyro.z, x.highG.x, x.highG.y, x.highG.z)
        }
        return s
    }
}

/// Appends raw samples to a `.tbrec` file while recording.
public final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    public private(set) var url: URL?
    public private(set) var sampleCount = 0

    public init() {}

    public var isRecording: Bool { lock.withLock { handle != nil } }

    public func start(in directory: URL, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension(RecordingFormat.fileExtension)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        lock.withLock {
            handle = h
            self.url = url
            sampleCount = 0
        }
    }

    public func append(_ samples: [IMUSample]) {
        lock.withLock {
            guard let handle else { return }
            handle.write(RecordingFormat.encode(samples))
            sampleCount += samples.count
        }
    }

    @discardableResult
    public func stop() -> URL? {
        lock.withLock {
            try? handle?.close()
            handle = nil
            return url
        }
    }
}

/// Plays a recording back in real time as if it were the live racket.
public final class ReplaySource: SampleSource, @unchecked Sendable {
    public var onSamples: (([IMUSample]) -> Void)?
    public var nativeCalibration: Calibration? { nil }
    public var loop = true

    private let samples: [IMUSample]
    private var cursor = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "tennisbuddy.replay", qos: .userInitiated)
    private var timeOffset: Double = 0

    public init(url: URL) throws {
        samples = RecordingFormat.decode(try Data(contentsOf: url))
    }

    public var duration: Double { (samples.last?.time ?? 0) - (samples.first?.time ?? 0) }

    public func start() {
        stop()
        guard !samples.isEmpty else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        var batch: [IMUSample] = []
        for _ in 0..<10 {
            if cursor >= samples.count {
                guard loop else { stop(); break }
                timeOffset += duration + 0.001
                cursor = 0
            }
            var s = samples[cursor]
            s.time += timeOffset
            batch.append(s)
            cursor += 1
        }
        if !batch.isEmpty { onSamples?(batch) }
    }
}
