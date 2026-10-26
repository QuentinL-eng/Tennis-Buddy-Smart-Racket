import Foundation

/// Everything the UI and the status packet need, sampled atomically.
struct StatsSnapshot: Equatable {
    var captureFPS: Double = 0
    var detectorMedianMs: Double = 0
    var detectorP95Ms: Double = 0
    var packetRate: Double = 0
    var droppedFrames: Int = 0
    var frames: Int = 0
    var detections: Int = 0
    var packets: Int = 0
    var sequence: UInt32 = 0
    var lastDetectorMs: Double = 0
    /// u/v/radius/confidence of the most recent detection, for the UI.
    var lastUV: String = "—"
}

/// Lock-protected rolling counters written from the capture queue at 240 Hz and
/// read from the main thread at 5 Hz.
///
/// The windows are short on purpose: a 240-sample frame window is exactly one
/// second at the target rate, so "capture fps" is a one-second measurement
/// rather than a lifetime average that hides a stall.
final class CaptureStats: @unchecked Sendable {
    private static let windowFrames = 240
    private static let windowDetector = 240
    private static let windowPackets = 480

    private let lock = NSLock()

    private var frameTimes: [UInt64] = []
    private var detectorTimes: [Double] = []
    private var packetTimes: [UInt64] = []

    private var droppedFrames = 0
    private var frames = 0
    private var detections = 0
    private var packets = 0
    private var sequence: UInt32 = 0
    private var lastDetectorMs: Double = 0
    private var lastUV: String = "—"

    func recordFrame(tNs: UInt64) {
        lock.lock()
        frames &+= 1
        frameTimes.append(tNs)
        if frameTimes.count > Self.windowFrames {
            frameTimes.removeFirst(frameTimes.count - Self.windowFrames)
        }
        lock.unlock()
    }

    func recordDropped() {
        lock.lock()
        droppedFrames &+= 1
        lock.unlock()
    }

    func recordDetector(milliseconds: Double) {
        lock.lock()
        lastDetectorMs = milliseconds
        detectorTimes.append(milliseconds)
        if detectorTimes.count > Self.windowDetector {
            detectorTimes.removeFirst(detectorTimes.count - Self.windowDetector)
        }
        lock.unlock()
    }

    func recordDetection(_ detection: BallDetection) {
        lock.lock()
        detections &+= 1
        lastUV = String(format: "%.0f, %.0f  r %.1f", detection.u, detection.v, detection.radius)
        lock.unlock()
    }

    /// One counter for every packet on the wire, observations and statuses
    /// alike, so a receiver can detect a gap from any cause.
    func nextSequence() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let current = sequence
        sequence &+= 1
        return current
    }

    func recordPacket(tNs: UInt64) {
        lock.lock()
        packets &+= 1
        packetTimes.append(tNs)
        if packetTimes.count > Self.windowPackets {
            packetTimes.removeFirst(packetTimes.count - Self.windowPackets)
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        frameTimes.removeAll(keepingCapacity: true)
        detectorTimes.removeAll(keepingCapacity: true)
        packetTimes.removeAll(keepingCapacity: true)
        droppedFrames = 0
        frames = 0
        detections = 0
        packets = 0
        sequence = 0
        lastDetectorMs = 0
        lastUV = "—"
        lock.unlock()
    }

    func snapshot() -> StatsSnapshot {
        lock.lock()
        let framesCopy = frameTimes
        let detectorCopy = detectorTimes
        let packetsCopy = packetTimes
        var result = StatsSnapshot()
        result.droppedFrames = droppedFrames
        result.frames = frames
        result.detections = detections
        result.packets = packets
        result.sequence = sequence
        result.lastDetectorMs = lastDetectorMs
        result.lastUV = lastUV
        lock.unlock()

        result.captureFPS = Rate.measure(framesCopy)
        result.packetRate = Rate.measure(packetsCopy)

        if !detectorCopy.isEmpty {
            let sorted = detectorCopy.sorted()
            result.detectorMedianMs = Metrics.percentile(sorted, 0.5)
            result.detectorP95Ms = Metrics.percentile(sorted, 0.95)
        }
        return result
    }

    private enum Rate {
        /// Events per second over the span covered by the samples.
        static func measure(_ times: [UInt64]) -> Double {
            guard times.count >= 2, let first = times.first, let last = times.last, last > first else {
                return 0
            }
            let span = Double(last - first) / 1e9
            guard span > 0 else { return 0 }
            return Double(times.count - 1) / span
        }
    }

    private enum Metrics {
        /// Nearest-rank percentile on an ascending array.
        static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = Int((fraction * Double(sorted.count - 1)).rounded())
            return sorted[max(0, min(sorted.count - 1, index))]
        }
    }
}
