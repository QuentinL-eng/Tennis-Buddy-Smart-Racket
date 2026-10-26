import Foundation
import simd

/// Anything that produces 1 kHz samples: the real racket over BLE, the simulator, or a recording.
public protocol SampleSource: AnyObject {
    /// Called on an arbitrary queue with batches of samples in sensor coordinates.
    var onSamples: (([IMUSample]) -> Void)? { get set }
    /// Calibration that maps this source's sensor axes to racket axes (the simulator is already in racket axes).
    var nativeCalibration: Calibration? { get }
    func start()
    func stop()
}

/// Live state for the UI, published ~30 times a second.
public struct LiveState: Sendable {
    public var orientation: simd_quatf
    public var gyroDps: Float
    public var highG: Float
    public var samplesPerSecond: Double
}

/// Processes the sample stream: calibration → orientation → shot detection → analysis.
/// All processing runs on a private serial queue; callbacks arrive on the main queue.
public final class RacketEngine: @unchecked Sendable {
    public var calibration: Calibration = .default { didSet { queue.async { self._calibration = self.calibration } } }
    public var profile = RacketProfile() { didSet { queue.async { self.analyzer.profile = self.profile } } }
    public var impactModel = ImpactModel() { didSet { queue.async { self.analyzer.model = self.impactModel } } }
    /// Calibration mode: detect gentle impacts (ball drops) with no swing.
    public var calibrationMode = false { didSet { queue.async { self._calibrationMode = self.calibrationMode } } }

    public var onLive: ((LiveState) -> Void)?
    public var onShot: ((ShotMetrics) -> Void)?
    /// Raw (sensor-frame) samples for the recorder, delivered on the engine queue.
    public var onRaw: (([IMUSample]) -> Void)?

    private let queue = DispatchQueue(label: "tennisbuddy.engine", qos: .userInitiated)
    private var _calibration: Calibration = .default
    private var _calibrationMode = false
    private var sourceCalibration: Calibration?
    private var filter = MahonyFilter()
    private var analyzer = ShotAnalyzer(profile: RacketProfile(), model: ImpactModel())
    private var ring: [(IMUSample, simd_quatf)] = []
    private let ringCapacity = 1500
    private var lastTime: Double?
    private var lastShotTime: Double = -10
    private var pendingImpactTime: Double?
    private var lastLivePublish: Double = 0
    private var rateCounter = 0
    private var rateWindowStart: Double = 0
    private var rate: Double = 0
    private var stillSamples: [IMUSample] = []

    private weak var source: SampleSource?

    public init() {}

    public func attach(_ source: SampleSource) {
        self.source?.stop()
        self.source?.onSamples = nil
        self.source = source
        let native = source.nativeCalibration
        queue.async {
            self.sourceCalibration = native
            self.reset()
        }
        source.onSamples = { [weak self] batch in self?.ingest(batch) }
    }

    public func detach() {
        source?.stop()
        source?.onSamples = nil
        source = nil
    }

    public func recenter() { queue.async { self.filter.recenter() } }

    /// Average of the most recent `seconds` of raw samples, for calibration poses.
    public func captureStill(seconds: Double, completion: @escaping (Calibration.PoseReading) -> Void) {
        queue.async { self.stillSamples = [] }
        queue.asyncAfter(deadline: .now() + seconds) {
            let reading = Calibration.PoseReading(samples: self.stillSamples)
            DispatchQueue.main.async { completion(reading) }
        }
    }

    public func ingest(_ batch: [IMUSample]) {
        queue.async { self.process(batch) }
    }

    private func reset() {
        filter = MahonyFilter()
        ring.removeAll(keepingCapacity: true)
        lastTime = nil
        pendingImpactTime = nil
        lastShotTime = -10
    }

    private func process(_ batch: [IMUSample]) {
        onRaw?(batch)
        let cal = sourceCalibration ?? _calibration
        for raw in batch {
            stillSamples.append(raw)
            if stillSamples.count > 5000 { stillSamples.removeFirst(1000) }
            let s = cal.apply(raw)
            let dt = Float(lastTime.map { min(max(s.time - $0, 0.0002), 0.02) } ?? 0.001)
            lastTime = s.time
            filter.update(gyro: s.gyro, accel: s.accel, dt: dt)
            ring.append((s, filter.q))
            if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
            detect(s)

            rateCounter += 1
            if s.time - rateWindowStart >= 1 {
                rate = Double(rateCounter) / (s.time - rateWindowStart)
                rateCounter = 0
                rateWindowStart = s.time
            }
        }
        if let last = ring.last, last.0.time - lastLivePublish > 1.0 / 30 {
            lastLivePublish = last.0.time
            let state = LiveState(orientation: filter.displayOrientation,
                                  gyroDps: simd_length(last.0.gyro) * 180 / .pi,
                                  highG: simd_length(last.0.highG),
                                  samplesPerSecond: rate)
            DispatchQueue.main.async { self.onLive?(state) }
        }
    }

    private func detect(_ s: IMUSample) {
        let n = ring.count
        if let t = pendingImpactTime {
            if s.time - t >= 0.15 { finishShot(at: t) }
            return
        }
        guard n > 400, s.time - lastShotTime > 0.4 else { return }
        let jump = simd_length(s.highG - ring[n - 4].0.highG)
        let threshold: Float = _calibrationMode ? 4 : 10
        guard jump > threshold else { return }
        if !_calibrationMode {
            // Must be in a real swing: fast rotation in the last 150 ms.
            let recent = ring[(n - 150)..<n].map { simd_length($0.0.gyro) }.max() ?? 0
            guard recent > 5 else { return }
        }
        pendingImpactTime = s.time
    }

    private func finishShot(at t: Double) {
        pendingImpactTime = nil
        lastShotTime = t
        guard let center = ring.lastIndex(where: { $0.0.time <= t }) else { return }
        // Refine: largest high-g jump within ±6 samples.
        var best = center, bestJump: Float = 0
        for k in max(3, center - 6)...min(ring.count - 1, center + 6) {
            let j = simd_length(ring[k].0.highG - ring[k - 3].0.highG)
            if j > bestJump { bestJump = j; best = k }
        }
        // Impact = first sample of the jump.
        let i0 = max(best - 2, 0)
        let lo = max(0, i0 - 700), hi = min(ring.count, i0 + 150)
        let window = ring[lo..<hi].map(\.0)
        let q = ring[max(i0 - 3, 0)].1
        let shot = analyzer.analyze(window: window, impact: i0 - lo, orientation: q, date: Date(),
                                    calibrationMode: _calibrationMode)
        DispatchQueue.main.async { self.onShot?(shot) }
    }
}
