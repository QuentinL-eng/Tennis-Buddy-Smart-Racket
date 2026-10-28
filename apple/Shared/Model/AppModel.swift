import Foundation
import Observation
import RacketKit
import SwiftData
import simd
#if canImport(UIKit)
import UIKit
#endif

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

/// The per-player fields that used to be stored on `RacketProfile`, read only to migrate old saves.
private struct LegacyPlayerFields: Decodable {
    var rightHanded: Bool?
    var heightM: Float?
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

    // MARK: Firmware update
    /// The racket firmware shipped inside the app (firmware/tools/bundle_for_app.sh).
    let bundledFirmware = FirmwareImage.bundled()
    var firmwareUpdate: RacketBLE.FirmwareUpdateState = .idle
    var racketSupportsFirmwareUpdate = false

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
    /// Bumped when the racket's IMU changes (MPU6050 + H3LIS331 -> LSM6DSV320X): a calibration from another sensor
    /// maps the wrong axes, so it is dropped and the app falls back to defaults until the user recalibrates.
    static let calibrationKey = "calibration.lsm6dsv320x"
    var calibration: Calibration { didSet { save(calibration, key: Self.calibrationKey); engine.calibration = calibration } }
    var profile: RacketProfile { didSet { save(profile, key: "profile"); engine.profile = profile } }
    /// Everyone who hits with this racket. Sessions are tagged with the player active when they start.
    var players: [PlayerProfile] { didSet { save(players, key: "players"); applyActivePlayer() } }
    var activePlayerID: UUID { didSet { UserDefaults.standard.set(activePlayerID.uuidString, forKey: "activePlayerID"); applyActivePlayer() } }
    var activePlayer: PlayerProfile? { players.first { $0.id == activePlayerID } }
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
        ble.onFirmwareUpdateSupport = { [weak self] supported in self?.racketSupportsFirmwareUpdate = supported }
        ble.onFirmwareUpdate = { [weak self] state in
            self?.firmwareUpdate = state
            #if canImport(UIKit)
            // A locked phone suspends the transfer, so keep the screen on while it runs.
            UIApplication.shared.isIdleTimerDisabled = state.isInProgress
            #endif
        }
        ble.onVerdict = { [weak self] v in
            guard let self else { return }
            self.lastVerdict = v
            self.lastVerdictDate = Date()
            // Motion sensors offline: the mic verdict is the only record of the hit, so log it as a shot.
            if self.motionSensorsMissing {
                self.handle(.fromMic(sweet: v.isSweet, offCenterPercent: v.offCenterPercent))
            }
        }
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
        calibration = Self.load(key: Self.calibrationKey) ?? .default
        profile = Self.load(key: "profile") ?? RacketProfile()
        // Before player profiles, the handedness and height lived on the racket under "profile". Carry them over once.
        let legacy: LegacyPlayerFields? = Self.load(key: "profile")
        let storedPlayers: [PlayerProfile]? = Self.load(key: "players")
        let initialPlayers = storedPlayers ?? [PlayerProfile(name: "Player 1", rightHanded: legacy?.rightHanded ?? true,
                                                             heightM: legacy?.heightM)]
        players = initialPlayers
        activePlayerID = UserDefaults.standard.string(forKey: "activePlayerID").flatMap(UUID.init) ?? initialPlayers[0].id
        impactModel = Self.load(key: "impactModel") ?? ImpactModel()
        profile.rightHanded = players.first { $0.id == activePlayerID }?.rightHanded ?? true
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

    /// The real racket is connected but neither motion sensor answered at boot (mic-only mode).
    var motionSensorsMissing: Bool {
        guard sourceKind == .racket, let s = racketStatus else { return false }
        return !s.mpuOK && !s.h3lisOK
    }

    // MARK: - Sessions

    func addPlayer() {
        let player = PlayerProfile(name: "Player \(players.count + 1)")
        players.append(player)
        activePlayerID = player.id
    }

    /// The last remaining player can't be deleted, so there is always someone to attribute sessions to.
    func deletePlayer(_ id: UUID) {
        guard players.count > 1 else { return }
        players.removeAll { $0.id == id }
        if activePlayerID == id { activePlayerID = players[0].id }
    }

    /// Copies the active player's handedness into the racket profile, which the shot classifier reads.
    private func applyActivePlayer() {
        guard let rightHanded = activePlayer?.rightHanded, profile.rightHanded != rightHanded else { return }
        profile.rightHanded = rightHanded
    }

    func startSession() {
        guard activeSession == nil else { return }
        let session = SessionRecord()
        session.playerName = activePlayer?.name ?? ""
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
