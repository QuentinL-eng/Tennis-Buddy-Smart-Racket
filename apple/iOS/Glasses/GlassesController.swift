import Foundation
import MWDATCore
import MWDATDisplay
import Observation
import RacketKit

/// Meta Ray-Ban Display link: registers the app with the Meta AI app, finds the glasses and mirrors the live session
/// (latest shot, sweet-spot rate, score, drill) to the lens while a session runs.
@MainActor
@Observable
final class GlassesController {
    enum Registration: Equatable { case unavailable, available, registering, registered }
    enum HUDState: Equatable { case off, connecting, live }

    static let hudEnabledKey = "glassesHUDEnabled"
    static let urlActionKey = "metaWearablesAction"

    private(set) var registration: Registration = .unavailable
    private(set) var deviceName: String?
    private(set) var displayDevicePresent = false
    private(set) var deviceReady = false
    private(set) var hud: HUDState = .off
    private(set) var needsGlassesAppUpdate = false
    private(set) var needsFirmwareUpdate = false
    private(set) var errorMessage: String?
    private(set) var configured = false

    var hudEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.hudEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.hudEnabledKey); sync() }
    }

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var account: AccountModel?
    @ObservationIgnored private var deviceSession: DeviceSession?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var displayReady = false
    @ObservationIgnored private var displayToken: AnyListenerToken?
    @ObservationIgnored private var linkToken: AnyListenerToken?
    @ObservationIgnored private var compatToken: AnyListenerToken?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var confirmTask: Task<Void, Never>?
    @ObservationIgnored private var teardownTask: Task<Void, Never>?
    @ObservationIgnored private var confirmingEnd = false
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var previewing = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var observedDevice: DeviceIdentifier?
    @ObservationIgnored private var lastSession: SessionRecord?

    init() {
        do {
            try Wearables.configure()
            configured = true
        } catch {
            errorMessage = "Glasses support is unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: Wiring

    func connect(to model: AppModel, account: AccountModel) {
        guard self.model == nil, configured else { return }
        self.model = model
        self.account = account
        let wearables = Wearables.shared
        tasks.append(Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                self?.apply(registration: state)
            }
        })
        tasks.append(Task { [weak self] in
            for await ids in wearables.devicesStream() {
                self?.apply(devices: ids)
            }
        })
        track()
    }

    /// Routes the Meta AI app's callback (registration and permission grants) into the SDK.
    func handle(url: URL) {
        guard configured,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == Self.urlActionKey }) == true else { return }
        Task {
            do { _ = try await Wearables.shared.handleUrl(url) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Actions

    func register() {
        errorMessage = nil
        Task {
            do { try await Wearables.shared.startRegistration() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func unregister() {
        errorMessage = nil
        Task {
            await tearDown()
            do { try await Wearables.shared.startUnregistration() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func openFirmwareUpdate() {
        Task { do { try await Wearables.shared.openFirmwareUpdate() } catch { errorMessage = error.localizedDescription } }
    }

    func openGlassesAppUpdate() {
        Task { do { try await Wearables.shared.openDATGlassesAppUpdate() } catch { errorMessage = error.localizedDescription } }
    }

    /// Reconnects the lens and shows a test card, even with no session running (it clears after 20 s).
    func reconnect() {
        errorMessage = nil
        needsGlassesAppUpdate = false
        guard registration == .registered else { errorMessage = "Connect to Meta AI first."; return }
        guard deviceReady else {
            errorMessage = displayDevicePresent
                ? "Your glasses aren't connected. Put them on and open the Meta AI app."
                : "No Meta Ray-Ban Display glasses found. Pair them in the Meta AI app."
            return
        }
        previewing = true
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            await self?.tearDown()
            self?.sync()
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            self.previewing = false
            if self.model?.isSessionActive != true { await self.tearDown() }
        }
    }

    // MARK: Registration and devices

    private func apply(registration state: RegistrationState) {
        switch state {
        case .registered: registration = .registered
        case .registering: registration = .registering
        case .available: registration = .available
        default: registration = .unavailable
        }
        if registration != .registered { Task { await tearDown() } }
        sync()
    }

    private func apply(devices ids: [DeviceIdentifier]) {
        let wearables = Wearables.shared
        let device = ids.lazy.compactMap { wearables.deviceForIdentifier($0) }.first { $0.supportsDisplay() }
        displayDevicePresent = device != nil
        deviceName = device?.nameOrId()
        guard device?.identifier != observedDevice else { return }
        observedDevice = device?.identifier
        linkToken = nil
        compatToken = nil
        guard let device else { deviceReady = false; sync(); return }
        let refresh: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.refreshReadiness(device) }
        }
        linkToken = device.addLinkStateListener { _ in refresh() }
        compatToken = device.addCompatibilityListener { _ in refresh() }
        refreshReadiness(device)
    }

    private func refreshReadiness(_ device: Device) {
        let compatibility = device.compatibility()
        needsFirmwareUpdate = compatibility == .deviceUpdateRequired
        deviceReady = device.linkState == .connected && compatibility == .compatible
        if !deviceReady { Task { await tearDown() } }
        sync()
    }

    // MARK: Session mirroring

    /// Re-runs `sync` whenever any value the HUD shows changes.
    private func track() {
        guard let model else { return }
        withObservationTracking {
            _ = model.isSessionActive
            _ = model.sessionShots.count
            _ = model.lastShot?.id
            _ = model.activeDrill?.completed
            _ = model.activeSession?.pointsWon
            _ = model.activeSession?.pointsLost
            _ = account?.sharedMatch?.revision
        } onChange: { [weak self] in
            Task { @MainActor in self?.sync(); self?.track() }
        }
    }

    private func sync() {
        guard let model else { return }
        let shouldRun = ((hudEnabled && model.isSessionActive) || previewing) && registration == .registered && deviceReady
        if let session = model.activeSession { lastSession = session }
        if shouldRun {
            teardownTask?.cancel()
            if deviceSession == nil && !connecting { Task { await startHUD() } }
            else { render() }
        } else if deviceSession != nil && !model.isSessionActive && hudEnabled && !previewing && teardownTask == nil {
            showSummaryThenStop()
        } else if deviceSession != nil && teardownTask == nil {
            Task { await tearDown() }
        }
    }

    private func startHUD() async {
        connecting = true
        hud = .connecting
        defer { connecting = false }
        do {
            let wearables = Wearables.shared
            // The device is already known and ready, so pick it directly: an auto selector may not have resolved yet.
            guard let id = observedDevice else { throw DeviceSessionError.noEligibleDevice }
            let session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: id))
            deviceSession = session
            tasks.append(Task { [weak self] in
                for await error in session.errorStream() { self?.handle(sessionError: error) }
            })
            let started = Task { for await state in session.stateStream() where state == .started { return } }
            do {
                try session.start()
                await started.value
            } catch {
                started.cancel()
                throw error
            }
            let capability = try session.addDisplay()
            display = capability
            displayToken = capability.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.displayReady = state == .started
                    if state == .started { self.hud = .live; self.render() }
                    else if state == .stopped { self.hud = .off }
                }
            }
            capability.start()
            clockTask?.cancel()
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    self?.render()
                }
            }
        } catch {
            handle(sessionError: error)
            await tearDown()
        }
    }

    private func handle(sessionError error: Error) {
        if case DeviceSessionError.datAppOnTheGlassesUpdateRequired = error {
            needsGlassesAppUpdate = true
        } else {
            errorMessage = error.localizedDescription
        }
    }

    private func render() {
        guard displayReady, let display, let model else { return }
        if !model.isSessionActive {
            Task {
                do { try await display.send(GlassesHUD.message("Tennis Buddee", "Glasses connected. Start a session to see your shots here.")) }
                catch { self.errorMessage = (error as? DisplayError)?.description ?? error.localizedDescription }
            }
            return
        }
        let snapshot = snapshot(model)
        let view = GlassesHUD.session(
            snapshot, confirmingEnd: confirmingEnd,
            onEnd: { [weak self] in Task { @MainActor in self?.askToEnd() } },
            onConfirm: { [weak self] in Task { @MainActor in self?.confirmEnd() } },
            onCancel: { [weak self] in Task { @MainActor in self?.cancelEnd() } })
        Task {
            do { try await display.send(view) }
            catch { self.errorMessage = (error as? DisplayError)?.description ?? error.localizedDescription }
        }
    }

    private func askToEnd() {
        confirmingEnd = true
        render()
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.cancelEnd()
        }
    }

    private func cancelEnd() {
        confirmTask?.cancel()
        confirmingEnd = false
        render()
    }

    private func confirmEnd() {
        confirmTask?.cancel()
        confirmingEnd = false
        model?.stopSession()
    }

    private func showSummaryThenStop() {
        guard let display, displayReady, let model else { Task { await tearDown() }; return }
        var s = snapshot(model, summarising: lastSession)
        s.summary = true
        let view = GlassesHUD.summary(s)
        teardownTask = Task { [weak self] in
            try? await display.send(view)
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            await self?.tearDown()
        }
    }

    private func tearDown() async {
        clockTask?.cancel(); clockTask = nil
        confirmTask?.cancel(); confirmingEnd = false
        teardownTask = nil
        displayReady = false
        display?.stop()
        deviceSession?.stop()
        displayToken = nil
        display = nil
        deviceSession = nil
        hud = .off
    }

    // MARK: Content

    private func snapshot(_ model: AppModel, summarising ended: SessionRecord? = nil) -> GlassesHUDSnapshot {
        let units = UnitSystem.current
        var s = GlassesHUDSnapshot()
        let session = model.activeSession ?? ended
        let summary = ShotSummary(model.sessionShots)
        s.shots = summary.count
        s.sweetSpotPercent = Int(summary.sweetSpotPercent.rounded())
        if let start = session?.startDate {
            let seconds = Int(((session?.endDate ?? Date()).timeIntervalSince(start)))
            s.elapsed = seconds >= 3600
                ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        if let shot = model.lastShot {
            s.lastShotTitle = shot.type.label
            s.lastShotSweet = shot.isSweetSpot
            let where_ = shot.isSweetSpot ? "Sweet spot" : String(format: "%.0f cm off", shot.impactDistanceCm)
            s.lastShotDetail = shot.hasMotion
                ? "\(units.speedValue(shot.ballSpeedKmh)) \(units.speedUnit) · \(where_)"
                : where_
        }
        if let session, session.pointsWon + session.pointsLost > 0 {
            s.points = "Points \(session.pointsWon)–\(session.pointsLost)"
        }
        if let state = account?.sharedMatch, let me = account?.userID, !state.ended, state.guest != nil {
            let t = state.tracker(for: me)
            s.score = t.setsText.isEmpty ? t.score.pointText : "\(t.setsText) · \(t.score.pointText)"
        }
        if let drill = model.activeDrill, !drill.isDone {
            s.drill = "\(drill.title) \(drill.completed)/\(drill.target)"
        }
        return s
    }
}
