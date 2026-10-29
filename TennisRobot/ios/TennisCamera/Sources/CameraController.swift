import AVFoundation
import CoreImage
import CoreMedia
import CoreMotion
import Foundation
import Photos
import UIKit
import simd

// MARK: - Frame processing

struct ProcessorSettings {
    var detectorEnabled = true
    var roi = BallDetector.Config.fullFrameROI
}

/// Runs on the `AVCaptureVideoDataOutput` queue. Everything here is per-frame
/// work: it must not block, allocate much or touch the UI.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let stats = CaptureStats()
    private let server: ObservationServer
    private let detector = BallDetector()
    private let settingsLock = NSLock()
    private var settings = ProcessorSettings()

    private let snapshotQueue = DispatchQueue(label: "tennisrobot.snapshot", qos: .userInitiated)
    private let snapshotLock = NSLock()
    private var snapshotRequest: ((CGImage?) -> Void)?
    private let ciContext = CIContext()

    /// Called with every candidate of a frame, on the capture queue. Candidate
    /// association and the flight fit run on the tracker queue so neither can eat
    /// into the 4.17 ms frame budget.
    var onDetections: ((UInt64, [BallDetection]) -> Void)?

    private let loggerLock = NSLock()
    private var sessionLogger: SessionLogger?

    /// The recording session, if one is active. Read once per frame.
    var logger: SessionLogger? {
        get {
            loggerLock.lock()
            defer { loggerLock.unlock() }
            return sessionLogger
        }
        set {
            loggerLock.lock()
            sessionLogger = newValue
            loggerLock.unlock()
        }
    }

    private var capturedWidth = 0
    private var capturedHeight = 0
    private var pixelFormatWarning: String?
    /// Deadline for the once-per-second status packet, on the capture clock so
    /// the cadence is 1.00 s rather than whatever the main runloop allows.
    private var nextStatusNs: UInt64 = 0

    /// Set when the capture system delivers something other than the 4:2:0
    /// full-range buffers the detector was built for. Silence here is the
    /// failure mode that is hardest to diagnose on a device.
    var formatWarning: String? {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return pixelFormatWarning
    }

    /// Size of the buffers the capture system is actually delivering, which can
    /// differ from the requested format after rotation.
    var capturedSize: (width: Int, height: Int) {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return (capturedWidth, capturedHeight)
    }

    init(server: ObservationServer) {
        self.server = server
        super.init()
    }

    func updateSettings(_ body: (inout ProcessorSettings) -> Void) {
        settingsLock.lock()
        body(&settings)
        settingsLock.unlock()
    }

    private var currentSettings: ProcessorSettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return settings
    }

    func requestSnapshot(_ completion: @escaping (CGImage?) -> Void) {
        snapshotLock.lock()
        snapshotRequest = completion
        snapshotLock.unlock()
    }

    private func takeSnapshotRequest() -> ((CGImage?) -> Void)? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        let request = snapshotRequest
        snapshotRequest = nil
        return request
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // The presentation timestamp is the capture time. The callback time is
        // useless for the estimator: it carries scheduling jitter.
        let tCapture = CaptureClock.nanoseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        logger?.appendVideo(sampleBuffer)

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            stats.recordFrame(tNs: tCapture)
            return
        }
        process(pixelBuffer: pixelBuffer, tCapture: tCapture)
    }

    /// The per-frame path, separated from the delegate so tests can push a
    /// synthetic `CVPixelBuffer` through exactly the code the phone runs.
    func process(pixelBuffer: CVPixelBuffer, tCapture: UInt64) {
        stats.recordFrame(tNs: tCapture)
        let log = logger
        log?.logFrame(tCapture)

        if let request = takeSnapshotRequest() {
            deliver(pixelBuffer, to: request)
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            let fourCC = withUnsafeBytes(of: pixelFormat.bigEndian) { bytes in
                String(bytes: bytes, encoding: .ascii) ?? "?"
            }
            settingsLock.lock()
            pixelFormatWarning = "delivered pixel format \(fourCC) is not 420f; detector skipped"
            settingsLock.unlock()
            return
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        settingsLock.lock()
        capturedWidth = width
        capturedHeight = height
        settingsLock.unlock()

        if nextStatusNs == 0 {
            nextStatusNs = tCapture &+ 1_000_000_000
        }
        if tCapture >= nextStatusNs {
            nextStatusNs = tCapture &+ 1_000_000_000
            sendStatusPacket(tCaptureNs: tCapture)
        }

        let settings = currentSettings
        guard settings.detectorEnabled else { return }

        let flags = CVPixelBufferLockFlags.readOnly
        guard CVPixelBufferLockBaseAddress(pixelBuffer, flags) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, flags) }

        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return }

        let start = DispatchTime.now().uptimeNanoseconds
        let detections = detector.detect(
            luma: luma.assumingMemoryBound(to: UInt8.self),
            lumaStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
            chroma: chroma.assumingMemoryBound(to: UInt8.self),
            chromaStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
            width: width,
            height: height,
            roi: settings.roi
        )
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        stats.recordDetector(milliseconds: elapsedMs)

        guard !detections.isEmpty else { return }
        for detection in detections {
            stats.recordDetection(detection)
        }
        onDetections?(tCapture, detections)
        log?.logDetections(tCapture, detections)

        // The detections are value types, so nothing here points into the pixel
        // buffer after the unlock below.
        guard server.isConnected else { return }
        for detection in detections {
            let sequence = stats.nextSequence()
            let packet = ObservationPacket.observation(
                detection,
                sequence: sequence,
                tCaptureNs: tCapture,
                width: width,
                height: height
            )
            server.send(packet.encode())
            stats.recordPacket(tNs: tCapture)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        stats.recordDropped()
    }

    // MARK: Status

    /// Called from the capture queue, so the cadence does not depend on the
    /// main thread being free. `ProcessInfo.thermalState` is cheap and safe to
    /// read off the main thread.
    func sendStatusPacket(tCaptureNs: UInt64) {
        guard server.isConnected else { return }
        let size = capturedSize
        let snapshot = stats.snapshot()
        let packet = ObservationPacket.status(
            sequence: stats.nextSequence(),
            tCaptureNs: tCaptureNs,
            measuredFPS: snapshot.captureFPS,
            detectorMedianMs: snapshot.detectorMedianMs,
            droppedFrames: snapshot.droppedFrames,
            thermalState: ObservationPacket.thermalLevel(ProcessInfo.processInfo.thermalState),
            width: size.width,
            height: size.height
        )
        server.send(packet.encode())
        stats.recordPacket(tNs: tCaptureNs)
    }

    // MARK: Calibration snapshot

    /// Render the full-resolution frame off the capture queue. Holding one
    /// buffer for a few milliseconds is cheaper than an extra output.
    private func deliver(_ pixelBuffer: CVPixelBuffer, to request: @escaping (CGImage?) -> Void) {
        let context = ciContext
        snapshotQueue.async {
            // The closure keeps the pixel buffer alive; CoreVideo objects are
            // ARC-managed in Swift, so no manual retain/release.
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            request(context.createCGImage(image, from: image.extent))
        }
    }
}

/// What the tracker needs besides the detection itself. Written from the
/// session queue and the motion callback, read on the tracker queue.
private struct TrackerInputs {
    var model: CameraModel?
    /// Camera-frame gravity. Assumed level until CoreMotion reports something
    /// better, which is also what the simulator and a phone flat on a tripod do.
    var gravity = SIMD3<Double>(0, 9.80665, 0)
}

// MARK: - Session controller

final class CameraController: NSObject, ObservableObject {
    enum CameraError: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput
        case noFormat

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No back camera available."
            case .cannotAddInput: return "The capture session refused the camera input."
            case .cannotAddOutput: return "The capture session refused the video data output."
            case .noFormat: return "No 1920x1080 format on this device."
            }
        }
    }

    struct FormatInfo {
        var width = 0
        var height = 0
        var requestedFPS: Double = 0
        var actualFPS: Double = 0
        var sdr = false
        var ranges = ""

        var summary: String {
            guard width > 0 else { return "not configured" }
            let fps = actualFPS > 0 ? actualFPS : requestedFPS
            return String(format: "%dx%d @ %.0f fps%@", width, height, fps, sdr ? " SDR" : " HDR?")
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var stats = StatsSnapshot()
    @Published private(set) var format = FormatInfo()
    @Published private(set) var detail = ""
    @Published private(set) var connected = false
    @Published private(set) var serverError: String?
    @Published private(set) var thermalText = "nominal"
    @Published private(set) var flight: FlightPrediction?
    @Published private(set) var gravityText = "assumed level"
    @Published private(set) var lastSnapshot: UIImage?
    @Published private(set) var snapshotNote = ""
    @Published private(set) var listening = false

    @Published private(set) var sessionActive = false
    @Published private(set) var sessionNote = ""
    @Published private(set) var racket = RacketLink.Snapshot()
    @Published var recordVideo = true

    @Published var detectorEnabled = true {
        didSet { applySettings() }
    }
    @Published var strikeZoneROI = false {
        didSet { applySettings() }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "tennisrobot.camera.session")
    private let videoQueue = DispatchQueue(label: "tennisrobot.camera.frames", qos: .userInteractive)
    private let server = ObservationServer()
    private let processor: FrameProcessor
    private let tracker = FlightTracker()
    private let trackerQueue = DispatchQueue(label: "tennisrobot.flight", qos: .userInitiated)
    private let motion = CMMotionManager()
    private let racketLink = RacketLink()
    private let inputsLock = NSLock()
    private var inputs = TrackerInputs()

    private var uiTimer: Timer?
    /// Authoritative copy of the applied format, owned by `sessionQueue` so
    /// `beginCapture` never races the main-queue publish.
    private var appliedFormat = FormatInfo()

    override init() {
        processor = FrameProcessor(server: server)
        super.init()

        processor.onDetections = { [weak self] tCapture, detections in
            self?.track(tNs: tCapture, detections: detections)
        }

        server.onStateChange = { [weak self] connected, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = connected
                self.serverError = error
                self.listening = self.server.lastError == nil
            }
        }

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        output.setSampleBufferDelegate(processor, queue: videoQueue)

        racketLink.onRecord = { [weak processor] t, kind, data in
            processor?.logger?.logRacket(tNs: t, kind: kind, payload: data)
        }

        startUITimer()
    }

    deinit {
        uiTimer?.invalidate()
    }

    // MARK: Public control

    func start() {
        guard !isRunning else { return }
        trackerQueue.async { [weak self] in self?.tracker.reset() }
        flight = nil
        startMotion()
        racketLink.start()
        // The Task captures no state, only the answer, so it stays Sendable
        // without an isolation escape hatch on the controller.
        Task {
            let granted = await Self.requestCameraAccess()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard granted else {
                    self.detail = "Camera access denied. Settings > Privacy & Security > Camera."
                    return
                }
                self.beginCapture()
            }
        }
    }

    // MARK: Recording session

    /// Begin logging frames, ball detections, racket packets and (optionally) the 240 fps video.
    func startSession() {
        guard isRunning, !sessionActive else { return }
        let size = processor.capturedSize
        var info: [String: Any] = [
            "device": Self.deviceModel(),
            "os": UIDevice.current.systemVersion,
            "width": size.width,
            "height": size.height,
            "fps_requested": format.requestedFPS,
            "fps_actual": format.actualFPS,
            "rotation_angle": Self.rotationAngle(),
            "thermal_at_start": thermalText,
            "detector_enabled": detectorEnabled,
            "racket_state_at_start": racket.state,
        ]
        if let fx = currentInputs.model?.fx { info["fx_px"] = fx }
        guard let logger = SessionLogger(info: info, recordVideo: recordVideo) else {
            sessionNote = "Could not create the session folder."
            return
        }
        // The racket's last known settings go in first so the offline converter knows the ranges.
        if let status = racketLink.latestStatus {
            logger.logRacket(tNs: CaptureClock.nowNs, kind: .status, payload: status)
        }
        processor.logger = logger
        sessionActive = true
        sessionNote = "recording \(logger.name)"
    }

    func endSession() {
        guard sessionActive, let logger = processor.logger else { return }
        processor.logger = nil
        sessionActive = false
        let snapshot = processor.stats.snapshot()
        let link = racketLink.snapshot()
        sessionNote = "saving \(logger.name)…"
        logger.finish(extra: [
            "dropped_frames_total": snapshot.droppedFrames,
            "racket_imu_packets": link.imuPackets,
            "racket_lost_packets": link.lostPackets,
            "thermal_at_stop": thermalText,
        ]) { [weak self] summary in
            DispatchQueue.main.async { self?.sessionNote = "\(logger.name): \(summary)" }
        }
    }

    /// A timestamped note, e.g. a clap or a racket knock in view of the camera at the start.
    func markEvent() {
        processor.logger?.mark("mark")
    }

    private static func deviceModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    func stop() {
        endSession()
        racketLink.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        motion.stopDeviceMotionUpdates()
        trackerQueue.async { [weak self] in self?.tracker.reset() }
        flight = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    func takeSnapshot() {
        guard isRunning else {
            snapshotNote = "Start the camera first."
            return
        }
        snapshotNote = "capturing…"
        processor.requestSnapshot { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let image else {
                    self.snapshotNote = "snapshot failed"
                    return
                }
                self.lastSnapshot = UIImage(cgImage: image)
                self.snapshotNote = "\(image.width)x\(image.height) frame"
            }
        }
    }

    func saveSnapshotToPhotos() {
        guard let image = lastSnapshot, let data = image.jpegData(compressionQuality: 0.95) else {
            snapshotNote = "Nothing to save — take a snapshot first."
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self?.snapshotNote = "Photo library access denied." }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if success {
                        self.snapshotNote = "saved to Photos"
                    } else {
                        self.snapshotNote = error?.localizedDescription ?? "save failed"
                    }
                }
            }
        }
    }

    func updateRotation() {
        let angle = Self.rotationAngle()
        sessionQueue.async { [weak self] in
            guard let self, let connection = self.output.connection(with: .video) else { return }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    // MARK: Session configuration

    private func beginCapture() {
        server.start(port: 5000)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if self.session.inputs.isEmpty {
                    self.appliedFormat = try self.configureSession()
                }
                self.session.startRunning()
                let info = self.appliedFormat
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.detail = ""
                    if let warning = self.processor.formatWarning {
                        self.detail = warning
                    } else if info.requestedFPS < 240 {
                        self.detail = String(
                            format: "This device did not offer 1920x1080 at 240 fps; running at %.0f fps.",
                            info.actualFPS
                        )
                    } else if abs(info.actualFPS - info.requestedFPS) > 1 {
                        self.detail = String(
                            format: "Requested %.0f fps but the hardware set %.0f fps.",
                            info.requestedFPS, info.actualFPS
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.detail = "configure failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @discardableResult
    private func configureSession() throws -> FormatInfo {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)

        let info = try applyFormat(to: device)

        if let connection = output.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
            let angle = Self.rotationAngle()
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }

        DispatchQueue.main.async {
            self.format = info
            self.processor.stats.reset()
        }
        return info
    }

    private func applyFormat(to device: AVCaptureDevice) throws -> FormatInfo {
        guard let choice = Self.chooseFormat(device) else {
            throw CameraError.noFormat
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = choice.format
        if choice.format.supportedColorSpaces.contains(.sRGB) {
            // SDR: HDR processing adds latency and shifts the colour response,
            // which would invalidate the HSV thresholds.
            device.activeColorSpace = .sRGB
        }
        let duration = CMTime(value: 1, timescale: CMTimeScale(choice.fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        // Intrinsics for the format actually selected: the 240 fps mode can crop
        // relative to slower modes, so the field of view belongs to this format.
        let model = CameraModel(format: choice.format, width: Int(dims.width), height: Int(dims.height))
        updateInputs { $0.model = model }
        let readBack = device.activeVideoMinFrameDuration
        let ranges = choice.format.videoSupportedFrameRateRanges
            .map { String(format: "%.0f-%.0f", $0.minFrameRate, $0.maxFrameRate) }
            .joined(separator: ", ")

        return FormatInfo(
            width: Int(dims.width),
            height: Int(dims.height),
            requestedFPS: choice.fps,
            actualFPS: readBack.timescale > 0 ? Double(readBack.timescale) / Double(readBack.value) : choice.fps,
            sdr: choice.format.supportedColorSpaces.contains(.sRGB),
            ranges: ranges
        )
    }

    private struct FormatChoice {
        var format: AVCaptureDevice.Format
        var fps: Double
    }

    /// Highest supported rate at 1920x1080, preferring an SDR (sRGB) format.
    /// Falls back 240 -> 120 -> 60 -> 30 and never claims more than it set.
    private static func chooseFormat(_ device: AVCaptureDevice) -> FormatChoice? {
        let candidates = device.formats.filter {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width == 1920 && dims.height == 1080
        }
        for target in [240.0, 120.0, 60.0, 30.0] {
            let usable = candidates.filter { format in
                format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= target + 0.01 && $0.maxFrameRate >= target - 0.01
                }
            }
            if let best = usable.first(where: { $0.supportedColorSpaces.contains(.sRGB) }) ?? usable.first {
                return FormatChoice(format: best, fps: target)
            }
        }
        return nil
    }

    private static func rotationAngle() -> CGFloat {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .landscapeRight
        switch orientation {
        case .portrait: return 90
        case .landscapeLeft: return 180
        case .portraitUpsideDown: return 270
        default: return 0 // landscapeRight
        }
    }

    private static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    // MARK: 3D flight tracking

    private func updateInputs(_ body: (inout TrackerInputs) -> Void) {
        inputsLock.lock()
        body(&inputs)
        inputsLock.unlock()
    }

    private var currentInputs: TrackerInputs {
        inputsLock.lock()
        defer { inputsLock.unlock() }
        return inputs
    }

    /// Gravity in camera axes comes from the accelerometer: a single camera
    /// cannot tell which way is down over a 0.2 s window, and an extrapolation
    /// with the wrong gravity is wrong by centimetres.
    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let gravity = CameraGravity.inCameraFrame(
                deviceGravity: SIMD3<Double>(Double(data.gravity.x), Double(data.gravity.y), Double(data.gravity.z)),
                rotationAngleDegrees: Double(Self.rotationAngle())
            )
            self.updateInputs { $0.gravity = gravity }
            self.gravityText = String(format: "measured, %.1f m/s²", simd_length(gravity))
        }
    }

    private func track(tNs: UInt64, detections: [BallDetection]) {
        let snapshot = currentInputs
        guard let model = snapshot.model, !detections.isEmpty else { return }
        let flightModel = FlightModel(gravity: snapshot.gravity)
        let samples = detections.map { detection in
            FlightSample(
                tNs: tNs,
                u: Double(detection.u),
                v: Double(detection.v),
                radius: Double(detection.radius),
                confidence: Double(detection.confidence)
            )
        }
        trackerQueue.async { [weak self] in
            guard let self else { return }
            guard let prediction = self.tracker.add(samples, camera: model, model: flightModel) else { return }
            self.publish(prediction, width: model.width, height: model.height)
        }
    }

    /// Queue a fit result for the PC and the UI. Kind 2 is the state now; kind 3
    /// is the crossing of the plane in front of the camera. Both stay inside the
    /// fixed 40-byte layout, so a receiver written for kinds 0 and 1 still reads
    /// the stream and simply ignores them.
    private func publish(_ prediction: FlightPrediction, width: Int, height: Int) {
        let stats = processor.stats
        if server.isConnected {
            let state = ObservationPacket.flightState(
                sequence: stats.nextSequence(),
                tCaptureNs: prediction.tNs,
                x: prediction.state.position.x,
                y: prediction.state.position.y,
                z: prediction.state.position.z,
                rmsPx: prediction.rmsPx,
                width: width,
                height: height
            )
            server.send(state.encode())
            stats.recordPacket(tNs: prediction.tNs)

            if let point = prediction.intercept, let timeToPlane = prediction.interceptTimeS {
                let crossing = ObservationPacket.intercept(
                    sequence: stats.nextSequence(),
                    tCaptureNs: prediction.tNs,
                    x: point.x,
                    y: point.y,
                    z: point.z,
                    timeToPlaneS: timeToPlane,
                    width: width,
                    height: height
                )
                server.send(crossing.encode())
                stats.recordPacket(tNs: prediction.tNs)
            }
        }
        DispatchQueue.main.async {
            self.flight = prediction
        }
    }

    // MARK: Periodic UI + status

    private func applySettings() {
        let roi = strikeZoneROI ? BallDetector.Config.strikeZoneROI : BallDetector.Config.fullFrameROI
        let enabled = detectorEnabled
        processor.updateSettings { settings in
            settings.detectorEnabled = enabled
            settings.roi = roi
        }
    }

    private func startUITimer() {
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stats = self.processor.stats.snapshot()
            self.racket = self.racketLink.snapshot()
            self.updateThermal()
            if self.isRunning, let warning = self.processor.formatWarning, self.detail != warning {
                self.detail = warning
            }
        }
    }

    private func updateThermal() {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal: thermalText = "nominal"
        case .fair: thermalText = "fair"
        case .serious: thermalText = "serious"
        case .critical: thermalText = "critical"
        @unknown default: thermalText = "unknown"
        }

        if isRunning {
            UIApplication.shared.isIdleTimerDisabled = true
            if state == .critical {
                detail = "Stopped: the device reported a critical thermal state."
                stop()
            }
        }
    }
}
