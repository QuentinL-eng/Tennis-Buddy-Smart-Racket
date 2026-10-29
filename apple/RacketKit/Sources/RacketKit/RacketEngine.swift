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

    public init(orientation: simd_quatf, gyroDps: Float, highG: Float, samplesPerSecond: Double) {
        self.orientation = orientation
        self.gyroDps = gyroDps
        self.highG = highG
        self.samplesPerSecond = samplesPerSecond
    }
}

/// Processes the sample stream: calibration → orientation → shot detection → analysis. From an `ImpactSource`
/// (the racket in impact mode) it analyses the windows the racket sends instead, and shows the racket's own
/// orientation live. All processing runs on a private serial queue; callbacks arrive on the main queue.
public final class RacketEngine: @unchecked Sendable {
    public var calibration: Calibration = .default {
        didSet { queue.async { self._calibration = self.calibration; self.pushShotConfig() } }
    }
    public var profile = RacketProfile() { didSet { queue.async { self.analyzer.profile = self.profile; self.pushShotConfig() } } }
    public var impactModel = ImpactModel() {
        didSet { queue.async { self.analyzer.model = self.impactModel; self.pushShotConfig() } }
    }
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
    /// A racket that computes shots itself, and the config generation it was last sent (all on `queue`).
    private weak var summarySource: ShotSummarySource?
    private var configGen: UInt8 = 0
    /// Windows whose shot already came from the racket's summary.
    private var summarized: Set<WindowKey> = []

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
        if let impacts = source as? ImpactSource {
            impacts.onImpactWindow = { [weak self] window in self?.queue.async { self?.process(window) } }
            impacts.onPose = { [weak self] pose in self?.queue.async { self?.process(pose) } }
        }
        let summaries = source as? ShotSummarySource
        summaries?.onShotSummary = { [weak self] s in self?.queue.async { self?.process(s) } }
        queue.async {
            self.summarySource = summaries
            self.summarized.removeAll()
            self.pushShotConfig()
        }
    }

    /// Sends the racket what it needs to compute shots exactly as `analyzer` would. Each change gets a new
    /// generation, and summaries from an older one are ignored (their windows are analysed here instead).
    private func pushShotConfig() {
        guard let s = summarySource else { return }
        configGen = configGen == 255 ? 1 : configGen + 1
        s.setShotConfig(RacketProtocol.shotConfigPayload(gen: configGen, calibration: sourceCalibration ?? _calibration,
                                                         profile: analyzer.profile, model: analyzer.model))
    }

    private func process(_ summary: RacketProtocol.ShotSummary) {
        guard !_calibrationMode, summary.gen == configGen else { return }
        let key = WindowKey(boot: summary.boot, seq: summary.seq)
        guard summarized.insert(key).inserted else { return }
        if summarized.count > 512 { summarized.removeAll() }
        let shot = summary.metrics(receivedAt: Date())
        DispatchQueue.main.async { self.onShot?(shot) }
    }

    public func detach() {
        source?.stop()
        source?.onSamples = nil
        if let impacts = source as? ImpactSource {
            impacts.onImpactWindow = nil
            impacts.onPose = nil
        }
        (source as? ShotSummarySource)?.onShotSummary = nil
        source = nil
        queue.async { self.summarySource = nil }
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
        lastLivePublish = 0
        rateCounter = 0
        rateWindowStart = 0
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
            // Timestamps jumped backwards: the racket rebooted (e.g. replugged). Restart timing, or the
            // live view and shot detection would wait for the old clock to catch up.
            if let lt = lastTime, s.time < lt - 0.05 {
                let yaw = filter.yawOffset
                reset()
                filter.yawOffset = yaw
            }
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
        analyzeImpact(ring, near: center)
    }

    /// `frames` are racket-frame samples with the orientation after each; `center` is roughly the impact.
    private func analyzeImpact(_ frames: [(IMUSample, simd_quatf)], near center: Int) {
        guard let shot = Self.shot(frames: frames, near: center, analyzer: analyzer, calibrationMode: _calibrationMode,
                                   date: Date()) else { return }
        DispatchQueue.main.async { self.onShot?(shot) }
    }

    static func shot(frames: [(IMUSample, simd_quatf)], near center: Int, analyzer: ShotAnalyzer,
                     calibrationMode: Bool, date: Date) -> ShotMetrics? {
        guard frames.count > 3 else { return nil }
        // Refine: largest high-g jump within ±6 samples.
        var best = center, bestJump: Float = 0
        for k in max(3, center - 6)...max(3, min(frames.count - 1, center + 6)) {
            let j = simd_length(frames[k].0.highG - frames[k - 3].0.highG)
            if j > bestJump { bestJump = j; best = k }
        }
        // Impact = first sample of the jump.
        let i0 = max(best - 2, 0)
        let lo = max(0, i0 - 700), hi = min(frames.count, i0 + 150)
        let window = frames[lo..<hi].map(\.0)
        let q = frames[max(i0 - 3, 0)].1
        return analyzer.analyze(window: window, impact: i0 - lo, orientation: q, date: date,
                                calibrationMode: calibrationMode)
    }

    // MARK: - Impact mode

    /// The racket's orientation (sensor axes → world) turned into racket axes → world.
    static func racketOrientation(_ sensorToWorld: simd_quatf, _ cal: Calibration) -> simd_quatf {
        // mpuToRacket maps sensor vectors to racket vectors; its transpose takes racket vectors back to sensor ones.
        simd_normalize(sensorToWorld * simd_quatf(cal.mpuToRacket.transpose))
    }

    private func process(_ window: ImpactWindow) {
        onRaw?(window.samples)
        // The racket already sent this shot; the window is only for the recording.
        if summarized.remove(window.key) != nil { return }
        let cal = sourceCalibration ?? _calibration
        lastShotTime = window.samples[min(window.impactIndex, window.samples.count - 1)].time
        guard let shot = Self.shot(window: window, calibration: cal, analyzer: analyzer,
                                   calibrationMode: _calibrationMode, date: Date()) else { return }
        DispatchQueue.main.async { self.onShot?(shot) }
    }

    /// The shot in one impact window: the same path the racket's firmware/src/shot.cpp follows.
    static func shot(window: ImpactWindow, calibration cal: Calibration, analyzer: ShotAnalyzer,
                     calibrationMode: Bool, date: Date) -> ShotMetrics? {
        // Integrate from the racket's orientation at the window's start, so the shot sees the same geometry it
        // would have from the full stream.
        var f = MahonyFilter()
        f.q = Self.racketOrientation(window.startOrientation, cal)
        f.initialized = true
        var frames: [(IMUSample, simd_quatf)] = []
        frames.reserveCapacity(window.samples.count)
        var last: Double?
        for raw in window.samples {
            let s = cal.apply(raw)
            let dt = Float(last.map { min(max(s.time - $0, 0.0002), 0.02) } ?? 0.001)
            last = s.time
            f.update(gyro: s.gyro, accel: s.accel, dt: dt)
            frames.append((s, f.q))
        }
        return shot(frames: frames, near: window.impactIndex + 2, analyzer: analyzer, calibrationMode: calibrationMode,
                    date: date)
    }

    private func process(_ pose: RacketProtocol.Pose) {
        filter.q = Self.racketOrientation(pose.orientation, sourceCalibration ?? _calibration)
        filter.initialized = true
        let state = LiveState(orientation: filter.displayOrientation, gyroDps: pose.gyroDps, highG: pose.highG,
                              // The racket keeps sampling at 1 kHz; only the hits' windows come over the air.
                              samplesPerSecond: pose.flags & RacketProtocol.flagMotionOK != 0 ? RacketProtocol.sampleRate : 0)
        DispatchQueue.main.async { self.onLive?(state) }
    }
}
