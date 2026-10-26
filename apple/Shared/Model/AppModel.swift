import Foundation
import Observation
import RacketKit
import SwiftData
import simd

enum SourceKind: String, CaseIterable, Identifiable {
    case racket, simulator, replay
    var id: String { rawValue }
    var label: String {
        switch self {
        case .racket: "Racket"
        case .simulator: "Simulator"
        case .replay: "Replay"
        }
    }
}

/// App-wide state: data source, live orientation, the active session and settings.
@MainActor
@Observable
final class AppModel {
    // MARK: Source
    var sourceKind: SourceKind = .simulator
    var connectionLabel = "Simulator running"
    var isConnected = true
    var racketStatus: RacketProtocol.Status?
    /// Latest verdict from the racket's on-device sweet-spot model, and when it arrived.
    var lastVerdict: RacketProtocol.ShotVerdict?
    var lastVerdictDate: Date?
    var replayURL: URL?

    // MARK: Live
    var live = LiveState(orientation: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), gyroDps: 0, highG: 0,
                         samplesPerSecond: 0)
    var lastShot: ShotMetrics?
    var shotFlashID = UUID()

    // MARK: Session
    var activeSession: SessionRecord?
    private var lastEndedSession: SessionRecord?
    var sessionShots: [ShotMetrics] = []
    var isSessionActive: Bool { activeSession != nil }

    // MARK: Drill
    var activeDrill: Drill?

    // MARK: Settings
    var calibration: Calibration { didSet { save(calibration, key: "calibration"); engine.calibration = calibration } }
    var profile: RacketProfile { didSet { save(profile, key: "profile"); engine.profile = profile } }
    var impactModel: ImpactModel { didSet { save(impactModel, key: "impactModel"); engine.impactModel = impactModel } }

    // MARK: Recorder
    var isRecording = false
    var recordings: [URL] = []

    // MARK: Calibration flow
    var calibrationMode = false { didSet { engine.calibrationMode = calibrationMode } }
    var onCalibrationImpact: ((ShotMetrics) -> Void)?

    let engine = RacketEngine()
    let recorder = Recorder()
    let simulator = SimulatedRacket()
    /// Created on first use, so Bluetooth permission is only requested when the real racket is selected.
    @ObservationIgnored lazy var ble: RacketBLE = {
        let ble = RacketBLE()
        ble.onState = { [weak self] state in
            guard let self, self.sourceKind == .racket else { return }
            self.connectionLabel = state.label
            self.isConnected = state == .connected
        }
        ble.onStatus = { [weak self] status in self?.racketStatus = status }
        ble.onVerdict = { [weak self] v in self?.lastVerdict = v; self?.lastVerdictDate = Date() }
        return ble
    }()
    private var replay: ReplaySource?
    var modelContext: ModelContext?
    /// Hooks for the Watch bridge (iOS).
    var onShotForWatch: ((ShotMetrics) -> Void)?
    var onSessionChangeForWatch: ((Bool) -> Void)?
    var onDrillChangeForWatch: ((Drill?) -> Void)?

    static let recordingsDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Recordings", isDirectory: true)
    }()

    init() {
        calibration = Self.load(key: "calibration") ?? .default
        profile = Self.load(key: "profile") ?? RacketProfile()
        impactModel = Self.load(key: "impactModel") ?? ImpactModel()
        engine.calibration = calibration
        engine.profile = profile
        engine.impactModel = impactModel

        engine.onLive = { [weak self] state in self?.live = state }
        engine.onShot = { [weak self] shot in self?.handle(shot) }
        let recorder = recorder
        engine.onRaw = { batch in recorder.append(batch) }

        refreshRecordings()
        let stored = UserDefaults.standard.string(forKey: "sourceKind").flatMap(SourceKind.init(rawValue:))
        select(stored == .replay ? .simulator : (stored ?? .simulator))
    }

    // MARK: - Sources

    func select(_ kind: SourceKind, replay url: URL? = nil) {
        engine.detach()
        sourceKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: "sourceKind")
        racketStatus = nil
        switch kind {
        case .racket:
            engine.attach(ble)
            ble.start()
            connectionLabel = ble.state.label
            isConnected = ble.state == .connected
        case .simulator:
            engine.attach(simulator)
            simulator.start()
            connectionLabel = "Simulator running"
            isConnected = true
        case .replay:
            guard let url = url ?? replayURL, let source = try? ReplaySource(url: url) else {
                select(.simulator)
                return
            }
            replayURL = url
            replay = source
            engine.attach(source)
            source.start()
            connectionLabel = "Replaying \(url.deletingPathExtension().lastPathComponent)"
            isConnected = true
        }
    }

    func recenter() { engine.recenter() }

    // MARK: - Sessions

    func startSession() {
        guard activeSession == nil else { return }
        let session = SessionRecord()
        modelContext?.insert(session)
        activeSession = session
        sessionShots = []
        lastShot = nil
        onSessionChangeForWatch?(true)
    }

    func stopSession() {
        guard let session = activeSession else { return }
        session.endDate = Date()
        if session.shotRecords?.isEmpty ?? true {
            modelContext?.delete(session)
        }
        try? modelContext?.save()
        lastEndedSession = session
        activeSession = nil
        onSessionChangeForWatch?(false)
    }

    func logPoint(won: Bool) {
        guard let session = activeSession else { return }
        if won { session.pointsWon += 1 } else { session.pointsLost += 1 }
    }

    /// Heart rate and calories from the Watch workout, which may arrive just after the session ends.
    func recordHealth(averageHeartRate: Double, calories: Double) {
        guard let session = activeSession ?? lastEndedSession, averageHeartRate > 0 else { return }
        session.averageHeartRate = averageHeartRate
        session.activeCalories = calories
        try? modelContext?.save()
    }

    // MARK: - Drills

    func startDrill(_ drill: Drill) {
        activeDrill = drill
        onDrillChangeForWatch?(drill)
    }

    func cancelDrill() {
        activeDrill = nil
        onDrillChangeForWatch?(nil)
    }

    private func handle(_ shot: ShotMetrics) {
        if calibrationMode {
            onCalibrationImpact?(shot)
            return
        }
        if var drill = activeDrill, !drill.isDone, drill.matches(shot) {
            drill.completed += 1
            activeDrill = drill
            onDrillChangeForWatch?(drill)
        }
        lastShot = shot
        shotFlashID = UUID()
        if let session = activeSession {
            let record = ShotRecord(metrics: shot)
            record.session = session
            modelContext?.insert(record)
            sessionShots.append(shot)
        }
        onShotForWatch?(shot)
    }

    // MARK: - Recorder

    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            isRecording = false
            refreshRecordings()
        } else {
            let name = "session-" + Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "")
            try? recorder.start(in: Self.recordingsDirectory, name: name)
            isRecording = recorder.isRecording
        }
    }

    func refreshRecordings() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.recordingsDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        recordings = urls.filter { $0.pathExtension == RecordingFormat.fileExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func csvExport(for url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let csv = RecordingFormat.csv(RecordingFormat.decode(data))
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("csv")
        try? csv.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    // MARK: - Persistence helpers

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
