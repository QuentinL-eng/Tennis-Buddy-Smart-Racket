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
    var signedInPlayerName: String?
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
    // MARK: Score
    /// The match being scored, nil when none is running. Kept across launches.
    var match: ScoreTracker? { didSet { saveOrRemove(match, key: "match"); onMatchChangeForWatch?(match) } }
    /// Recorded tap directions for the wide and narrow sides of the handle; nil until the taps are calibrated.
    var tapCalibration: TapCalibration? { didSet { saveOrRemove(tapCalibration, key: "tapCalibration") } }
    /// The recorded tap calibration, or a guess from the racket calibration until there is one.
    var effectiveTapCalibration: TapCalibration { tapCalibration ?? .fromRacket(calibration) }
    /// What the last handle tap did, for the on-screen confirmation.
    var lastTapFeedback: TapFeedback?
    /// Set by the tap calibration sheet: taps go there instead of the score.
    var onCalibrationTap: ((RacketProtocol.TapGesture) -> Void)?
    var onMatchChangeForWatch: ((ScoreTracker?) -> Void)?
    private let announcer = ScoreAnnouncer()

    struct TapFeedback: Equatable {
        var id = UUID()
        var date = Date()
        var text: String
        /// False when the tap wasn't a score command.
        var recognized: Bool
    }

    /// Everyone who hits with this racket. Sessions are tagged with the player active when they start.
    var players: [PlayerProfile] { didSet { save(players, key: "players"); applyActivePlayer() } }
    var activePlayerID: UUID { didSet { UserDefaults.standard.set(activePlayerID.uuidString, forKey: "activePlayerID"); applyActivePlayer() } }
    var activePlayer: PlayerProfile? { players.first { $0.id == activePlayerID } }
    /// v2: gains fitted by the old ball-drop calibration came from a racket held still (no swing impulse), which
    /// mis-scales hit location on real swings, so those saves are dropped for the defaults.
    static let impactModelKey = "impactModel.v2"
    var impactModel: ImpactModel { didSet { save(impactModel, key: Self.impactModelKey); engine.impactModel = impactModel } }

    // MARK: Recorder
    var isRecording = false
    var recordings: [URL] = []

    // MARK: Calibration flow
    var calibrationMode = false { didSet { engine.calibrationMode = calibrationMode; updateStreamMode() } }
    /// The calibration screen is open: its still poses and ball drops need every sample, not just hit windows.
    var calibrating = false { didSet { updateStreamMode() } }
    var onCalibrationImpact: ((ShotMetrics) -> Void)?
    /// The racket's sweet-spot verdicts while calibrating, for the sweet-spot check.
    var onCalibrationVerdict: ((RacketProtocol.ShotVerdict) -> Void)?

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
        ble.onTap = { [weak self] tap in self?.handleTap(tap) }
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
            if self.calibrationMode {
                self.onCalibrationVerdict?(v)
                return
            }
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
        var storedCalibration: Calibration = Self.load(key: Self.calibrationKey) ?? .default
        // Earlier builds fitted the high-g axes separately from coarse high-g gravity; on the LSM6DSV320X they
        // are the low-g axes (see Calibration.from).
        if storedCalibration.isCalibrated { storedCalibration.h3lisToRacket = storedCalibration.mpuToRacket }
        calibration = storedCalibration
        profile = Self.load(key: "profile") ?? RacketProfile()
        // Before player profiles, the handedness and height lived on the racket under "profile". Carry them over once.
        let legacy: LegacyPlayerFields? = Self.load(key: "profile")
        let storedPlayers: [PlayerProfile]? = Self.load(key: "players")
        let initialPlayers = storedPlayers ?? [PlayerProfile(name: "Player 1", rightHanded: legacy?.rightHanded ?? true,
                                                             heightM: legacy?.heightM)]
        players = initialPlayers
        activePlayerID = UserDefaults.standard.string(forKey: "activePlayerID").flatMap(UUID.init) ?? initialPlayers[0].id
        impactModel = Self.load(key: Self.impactModelKey) ?? ImpactModel()
        match = Self.load(key: "match")
        tapCalibration = Self.load(key: "tapCalibration")
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
            updateStreamMode()
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

    /// Firmware 1.5+ finds hits on the racket and sends only the samples around each one, which keeps the link
    /// light and shots quick. Calibration and a manual raw recording need the full stream instead.
    private func updateStreamMode() {
        guard sourceKind == .racket else { return }
        ble.setRawStream(calibrating || calibrationMode || (isRecording && !autoRecording))
    }

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
        let rightHanded = activePlayer?.rightHanded ?? true
        let sign = activePlayer?.forehandBodySign ?? 0
        guard profile.rightHanded != rightHanded || profile.forehandBodySign != sign else { return }
        profile.rightHanded = rightHanded
        profile.forehandBodySign = sign
    }

    // MARK: Teach forehand

    /// Shots the active player still has to hit while teaching, and what the last attempt said.
    var teachingForehand = false
    var teachCount = 0
    var teachMessage = ""
    private var teachSpins: [Float] = []
    private let teachShotsNeeded = 3

    /// Learns which way the racket spins on this player's forehand from their next few swings, so forehand and
    /// backhand no longer depend on the orientation estimate. The swings are not recorded as shots.
    func beginTeachingForehand() {
        guard !isSessionActive else { return }
        teachSpins = []
        teachCount = 0
        teachMessage = "Hit \(teachShotsNeeded) forehands."
        teachingForehand = true
    }

    func cancelTeachingForehand() {
        teachingForehand = false
        teachMessage = ""
    }

    func clearTaughtForehand() {
        guard let index = players.firstIndex(where: { $0.id == activePlayerID }) else { return }
        players[index].forehandBodySign = nil
        teachMessage = ""
    }

    /// Returns true when the shot was consumed as a teaching swing.
    private func consumeTeachingShot(_ shot: ShotMetrics) -> Bool {
        guard teachingForehand else { return false }
        guard shot.hasMotion, let spin = shot.features.spinAxisY, abs(spin) > 8 else {
            teachMessage = "That swing was too gentle to learn from. Hit a normal forehand."
            return true
        }
        teachSpins.append(spin)
        teachCount = teachSpins.count
        guard teachSpins.count >= teachShotsNeeded else {
            teachMessage = "\(teachCount) of \(teachShotsNeeded). Keep going."
            return true
        }
        let positive = teachSpins.filter { $0 > 0 }.count
        if positive == teachSpins.count || positive == 0 {
            if let index = players.firstIndex(where: { $0.id == activePlayerID }) {
                players[index].forehandBodySign = positive == 0 ? -1 : 1
            }
            teachMessage = "Learned. Forehands and backhands are now told apart by swing direction."
            teachingForehand = false
        } else {
            // Mixed directions: not a consistent forehand, so start again rather than learn a wrong sign.
            teachSpins = []
            teachCount = 0
            teachMessage = "Those swings went different ways. Hit \(teachShotsNeeded) forehands the same way."
        }
        return true
    }

    func startSession(id: UUID = UUID(), startDate: Date = Date()) {
        guard activeSession == nil else { return }
        let session = SessionRecord(startDate: startDate)
        session.id = id
        session.playerName = signedInPlayerName ?? activePlayer?.name ?? ""
        modelContext?.insert(session)
        activeSession = session
        sessionShots = []
        lastShot = nil
        beginAutoRecording(session: session)
        onSessionChangeForWatch?(true)
    }

    func startSharedRecording(matchID: UUID, playerID: UUID) {
        guard !isSessionActive else { return }
        startSession()
        activeSession?.sharedMatchID = matchID.uuidString
        activeSession?.sharedPlayerID = playerID.uuidString
    }

    func stopSession() {
        guard let session = activeSession else { return }
        session.endDate = Date()
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        session.title = title.isEmpty ? session.startDate.formatted(.dateTime.weekday(.wide).hour().minute()) : String(title.prefix(120))
        try? modelContext?.save()
        lastEndedSession = session
        activeSession = nil
        endAutoRecording()
        onSessionChangeForWatch?(false)
    }

    /// A point from the Watch or the on-screen buttons. Goes to the match score when one is running.
    func logPoint(won: Bool) {
        if match != nil {
            award(won ? .me : .opponent)
        } else {
            countSessionPoint(won ? .me : .opponent, by: 1)
        }
    }

    // MARK: - Score

    func startMatch(rules: MatchRules) {
        match = ScoreTracker(rules: rules)
        lastTapFeedback = nil
        announcer.say("New match. Double tap a wide side when you win a point, single tap a narrow side when you lose one.")
    }

    func endMatch() {
        match = nil
        lastTapFeedback = nil
    }

    func award(_ p: Player) {
        guard var m = match else { return }
        guard m.score.winner == nil else {
            announcer.say("The match is over. Triple tap to undo the last point.")
            return
        }
        let event = m.award(p)
        match = m
        countSessionPoint(p, by: 1)
        announcer.say(m.score.announcement(for: event))
    }

    func undoPoint() {
        guard var m = match, let undone = m.undo() else {
            announcer.say("Nothing to undo.")
            return
        }
        match = m
        countSessionPoint(undone, by: -1)
        announcer.say("Point removed. " + m.score.announcement(for: .point))
    }

    /// Mirrors points into the session record, so History shows them even without a match.
    private func countSessionPoint(_ p: Player, by delta: Int) {
        guard let session = activeSession else { return }
        if p == .me { session.pointsWon = max(0, session.pointsWon + delta) }
        else { session.pointsLost = max(0, session.pointsLost + delta) }
    }

    /// Handle taps: double tap on a wide side = point won, single tap on a narrow side = point lost,
    /// triple tap = undo.
    private func handleTap(_ tap: RacketProtocol.TapGesture) {
        if let calibrate = onCalibrationTap {
            calibrate(tap)
            return
        }
        guard match != nil else { return }
        let cal = effectiveTapCalibration
        // Until the taps are calibrated the sides are a guess, so any side counts.
        let side = cal.isCalibrated ? cal.classify(tap.direction)?.side : nil
        guard let command = ScoreCommand.from(count: tap.count, side: side) else {
            let what = tap.count == 1 ? "Single tap" : "Double tap"
            lastTapFeedback = TapFeedback(text: "\(what) on \(side.map { $0.label.lowercased() } ?? "an unclear side") — not a score tap",
                                          recognized: false)
            announcer.say("Didn't catch that.")
            return
        }
        switch command {
        case .won:
            award(.me)
            lastTapFeedback = TapFeedback(text: "Double tap, wide side: point to you", recognized: true)
        case .lost:
            award(.opponent)
            lastTapFeedback = TapFeedback(text: "Single tap, narrow side: point to your opponent", recognized: true)
        case .undo:
            undoPoint()
            lastTapFeedback = TapFeedback(text: "Triple tap: last point undone", recognized: true)
        }
    }


    /// Heart rate and calories from the Watch workout, which may arrive just after the session ends.
    func recordHealth(averageHeartRate: Double, calories: Double, sessionID: UUID? = nil) {
        let record: SessionRecord?
        if let sessionID {
            if activeSession?.id == sessionID { record = activeSession }
            else if lastEndedSession?.id == sessionID { record = lastEndedSession }
            else { record = try? modelContext?.fetch(FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == sessionID })).first }
        } else { record = activeSession ?? lastEndedSession }
        guard let session = record else { return }
        if averageHeartRate.isFinite && averageHeartRate > 0 { session.averageHeartRate = averageHeartRate }
        if calories.isFinite && calories >= 0 { session.activeCalories = max(session.activeCalories, calories) }
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
        if consumeTeachingShot(shot) { return }
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
            record.dataSourceRaw = sourceKind.rawValue
            if sourceKind == .racket && !session.sharedMatchID.isEmpty { session.sharedStatsPending = true }
            modelContext?.insert(record)
            sessionShots.append(shot)
        }
        logShotSidecar(shot)
        onShotForWatch?(shot)
    }

    // MARK: - Recorder

    /// Every session also writes its raw IMU stream plus a shot log to Documents/Recordings (visible in Files / Finder),
    /// so test data is captured without touching the Recorder toggle.
    @ObservationIgnored private var autoRecording = false
    @ObservationIgnored private var shotLog: FileHandle?

    private func beginAutoRecording(session: SessionRecord) {
        let name = "session-" + session.startDate.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "") + "-" + sourceKind.rawValue
        let dir = Self.recordingsDirectory
        if !recorder.isRecording {
            if (try? recorder.start(in: dir, name: name)) != nil { autoRecording = true; isRecording = true }
        }
        let url = dir.appendingPathComponent(name).appendingPathExtension("shots.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        shotLog = try? FileHandle(forWritingTo: url)
    }

    private func endAutoRecording() {
        if autoRecording { recorder.stop(); isRecording = false; autoRecording = false }
        try? shotLog?.close()
        shotLog = nil
        refreshRecordings()
    }

    private func logShotSidecar(_ shot: ShotMetrics) {
        guard let shotLog else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var data = try? enc.encode(shot) else { return }
        data.append(0x0A)
        try? shotLog.write(contentsOf: data)
    }

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
        updateStreamMode()
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

    private func saveOrRemove<T: Encodable>(_ value: T?, key: String) {
        if let value { save(value, key: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
