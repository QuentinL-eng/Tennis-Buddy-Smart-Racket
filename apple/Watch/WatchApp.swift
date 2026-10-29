import Foundation
import Observation
import RacketKit
import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct TennisBuddyWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView().environment(model)
        }
    }
}

/// Watch side of the link. Receives shots from the iPhone, plays a haptic per shot,
/// and sends start/stop and point results back.
@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    var sessionActive = false
    var sessionID: UUID?
    var sharedScore: ScoreTracker?
    var sharedScoreActive = false
    var sharedMatchID: UUID?
    var sharedRevision = 0
    var commandInFlight = false
    var commandError: String?
    var lastShot: ShotMetrics?
    var summary: ShotSummary?
    var pointsWon = 0
    var pointsLost = 0
    var phoneReachable = false
    var units = UnitSystem(metric: false)
    var drill: Drill?
    /// When the current session began, for the elapsed timer on the session page.
    var sessionStart: Date?
    let workout = WorkoutManager()

    override init() {
        super.init()
        workout.onFinished = { [weak self] id, average, calories in
            self?.sendHealth(id: id, average: average, calories: calories)
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func toggleSession() {
        let wasActive = sessionActive
        if !wasActive { sessionID = UUID() }
        send(["cmd": wasActive ? "stop" : "start", "sessionID": sessionID?.uuidString ?? ""])
        setSessionActive(!wasActive)
        WKInterfaceDevice.current().play(sessionActive ? .start : .stop)
    }

    /// Keeps the Tennis workout (heart rate, calories, Apple Health) in step with the racket session.
    func setSessionActive(_ active: Bool) {
        guard active != sessionActive else {
            if active { workout.setActive(true, recordID: sessionID) }
            return
        }
        if active && !sessionActive {
            pointsWon = 0; pointsLost = 0; lastShot = nil; summary = nil
            sessionStart = Date()
        }
        if !active { sessionStart = nil }
        if !active && sessionActive && workout.isRunning { sendHealth() }
        sessionActive = active
        workout.setActive(active, recordID: sessionID)
    }

    private func sendHealth(id: UUID? = nil, average: Double? = nil, calories: Double? = nil) {
        guard let recordID = id ?? sessionID else { return }
        let message: [String: Any] = ["cmd": "health", "sessionID": recordID.uuidString,
            "avgHR": average ?? workout.averageHeartRate, "kcal": calories ?? workout.activeCalories]
        // Queued delivery survives a temporarily unreachable iPhone; the record ID prevents misattribution.
        if WCSession.default.activationState == .activated { WCSession.default.transferUserInfo(message) }
    }

    /// New drill or progress from the iPhone: tap per counted shot, a celebration when it's done.
    func updateDrill(_ data: Data) {
        let new = data.isEmpty ? nil : try? JSONDecoder().decode(Drill.self, from: data)
        if let new, let old = drill, new.id == old.id, new.completed > old.completed {
            WKInterfaceDevice.current().play(new.isDone ? .success : .directionUp)
            if new.isDone {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { WKInterfaceDevice.current().play(.success) }
            }
        } else if let new, new.id != drill?.id {
            WKInterfaceDevice.current().play(.notification)
        }
        drill = new
    }

    func cancelDrill() {
        drill = nil
        send(["cmd": "cancelDrill"])
    }

    func logPoint(won: Bool) {
        guard !commandInFlight else { return }
        if sharedScore != nil && !sharedScoreActive { return }
        if !sharedScoreActive {
            if won { pointsWon += 1 } else { pointsLost += 1 }
        }
        send(["cmd": sharedScoreActive ? "sharedPoint" : "point", "won": won,
              "matchID": sharedMatchID?.uuidString ?? "", "revision": sharedRevision])
        WKInterfaceDevice.current().play(.click)
    }

    private func send(_ message: [String: Any]) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            commandError = "Open Tennis Buddee on your iPhone to sync."
            return
        }
        commandInFlight = true; commandError = nil
        WCSession.default.sendMessage(message, replyHandler: { reply in
            let error = reply["error"] as? String
            Task { @MainActor in
                self.commandInFlight = false
                self.commandError = error?.isEmpty == false ? error : nil
            }
            if let active = reply["sessionActive"] as? Bool {
                let id = (reply["sessionID"] as? String).flatMap(UUID.init(uuidString:))
                Task { @MainActor in
                    if let id { self.sessionID = id }
                    self.setSessionActive(active)
                }
            }
        }, errorHandler: { error in
            Task { @MainActor in self.commandInFlight = false; self.commandError = error.localizedDescription }
        })
    }

    private func handle(_ message: [String: Any]) {
        if message["type"] as? String == "shot", let data = message["shot"] as? Data,
           let shot = try? JSONDecoder().decode(ShotMetrics.self, from: data) {
            lastShot = shot
            if let metric = message["metric"] as? Bool { units = UnitSystem(metric: metric) }
            if let s = message["summary"] as? Data { summary = try? JSONDecoder().decode(ShotSummary.self, from: s) }
            // Crisp tap for a sweet-spot hit, a "retry" buzz for a mishit.
            WKInterfaceDevice.current().play(shot.isSweetSpot ? .success : .retry)
        } else if message["type"] as? String == "session", let active = message["active"] as? Bool {
            if let id = (message["sessionID"] as? String).flatMap(UUID.init(uuidString:)) { sessionID = id }
            setSessionActive(active)
        } else if message["type"] as? String == "sharedScore", let data = message["score"] as? Data {
            sharedScore = try? JSONDecoder().decode(ScoreTracker.self, from: data)
            sharedScoreActive = message["active"] as? Bool ?? false
            sharedMatchID = (message["matchID"] as? String).flatMap(UUID.init(uuidString:))
            sharedRevision = message["revision"] as? Int ?? 0
        } else if message["type"] as? String == "drill", let data = message["drill"] as? Data {
            updateDrill(data)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        nonisolated(unsafe) let msg = message
        Task { @MainActor in self.handle(msg) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        let active = ctx["sessionActive"] as? Bool
        let drill = ctx["drill"] as? Data
        let recordID = (ctx["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        let score = (ctx["sharedScore"] as? Data).flatMap { try? JSONDecoder().decode(ScoreTracker.self, from: $0) }
        let scoreActive = ctx["sharedScoreActive"] as? Bool ?? false
        let matchID = (ctx["sharedMatchID"] as? String).flatMap(UUID.init(uuidString:))
        let revision = ctx["sharedRevision"] as? Int ?? 0
        Task { @MainActor in
            if let recordID { self.sessionID = recordID }
            self.sharedScore = score; self.sharedScoreActive = scoreActive
            self.sharedMatchID = matchID; self.sharedRevision = revision
            if let active { self.setSessionActive(active) }
            if let drill { self.updateDrill(drill) }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in self.phoneReachable = reachable }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.phoneReachable = reachable }
    }
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        TabView {
            if model.drill != nil { DrillPage() }
            LastShotPage()
            PointsPage()
            SessionPage()
        }
        .tabViewStyle(.verticalPage)
    }
}


/// Colors from the Figma Watch mockup.
enum WatchPalette {
    static let green = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    static let red = Color(red: 1.0, green: 0.271, blue: 0.231) // #FF453B
    static let orange = Color(red: 1.0, green: 0.620, blue: 0.039) // #FF9E0A
    static let secondary = Color(red: 0.600, green: 0.600, blue: 0.631) // #9999A1
    static let ringTrack = Color.white.opacity(0.18)
    static let sweetSpotBackground = Color(red: 0.059, green: 0.251, blue: 0.122) // #0F401F
    static let mishitBackground = Color(red: 0.302, green: 0.071, blue: 0.071) // #4D1212
}

struct LastShotPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        VStack(spacing: 3) {
            if let shot = model.lastShot {
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: shot.type.symbol).font(.system(size: 13, weight: .semibold))
                        Text(shot.type.label).font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                    Circle().fill(shot.isSweetSpot ? WatchPalette.green : WatchPalette.red).frame(width: 10, height: 10)
                }
                Text(model.units.speedValue(shot.ballSpeedKmh))
                    .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                Text("\(model.units.speedUnit) · \(Int(shot.spinRPM)) rpm")
                    .font(.system(size: 12)).foregroundStyle(WatchPalette.secondary)
                if let s = model.summary {
                    Text("\(s.count) shots · \(Int(s.sweetSpotPercent))% sweet spot")
                        .font(.system(size: 10.5)).foregroundStyle(WatchPalette.secondary)
                }
                if model.workout.heartRate > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "heart").font(.system(size: 10))
                        Text("\(Int(model.workout.heartRate)) bpm")
                    }
                    .font(.system(size: 11)).foregroundStyle(WatchPalette.red)
                }
            } else {
                Image(systemName: "figure.tennis").font(.largeTitle).foregroundStyle(Color.accentColor)
                Text(model.sessionActive ? "Waiting for your first shot" : "Start a session to see shots here")
                    .font(.caption).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 4)
        .containerBackground(background, for: .tabView)
    }

    /// Solid green after a sweet-spot hit, deep red after a mishit.
    private var background: Color {
        guard let shot = model.lastShot else { return .black }
        return shot.isSweetSpot ? WatchPalette.sweetSpotBackground : WatchPalette.mishitBackground
    }
}

/// The drill countdown: a ring that fills as matching shots land.
struct DrillPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        if let drill = model.drill {
            VStack(spacing: 4) {
                Text(drill.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                ZStack {
                    Circle().stroke(WatchPalette.ringTrack, lineWidth: 8)
                    Circle().trim(from: 0, to: drill.progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.snappy, value: drill.completed)
                    VStack(spacing: 0) {
                        if drill.isDone {
                            Image(systemName: "checkmark").font(.title.bold()).foregroundStyle(WatchPalette.green)
                            Text("Done!").font(.system(size: 10.5)).foregroundStyle(WatchPalette.secondary)
                        } else {
                            Text("\(drill.remaining)").font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("to go").font(.system(size: 10.5)).foregroundStyle(WatchPalette.secondary)
                        }
                    }
                }
                .frame(width: 92, height: 92)
                Text(drill.goal).font(.system(size: 10.5)).foregroundStyle(WatchPalette.secondary)
                    .multilineTextAlignment(.center).lineLimit(2)
                Button(drill.isDone ? "Close" : "Stop drill") { model.cancelDrill() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(drill.isDone ? Color.accentColor : WatchPalette.red)
            }
        }
    }
}

struct PointsPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Text(model.sharedScore?.score.pointText ?? "\(model.pointsWon) – \(model.pointsLost)")
                .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
            HStack(spacing: 8) {
                PointButton(title: "Won", symbol: "checkmark", color: WatchPalette.green) { model.logPoint(won: true) }
                PointButton(title: "Lost", symbol: "xmark", color: WatchPalette.red) { model.logPoint(won: false) }
            }
            .disabled(!(model.sessionActive || model.sharedScoreActive) || (model.sharedScoreActive && !model.phoneReachable) || model.commandInFlight || model.sharedScore?.score.winner != nil || (model.sharedScore != nil && !model.sharedScoreActive))
            .opacity(model.sessionActive || model.sharedScoreActive ? 1 : 0.4)
            if let error = model.commandError { Text(error).font(.caption2).foregroundStyle(.red) }
            if let score = model.sharedScore { Text(score.setsText).font(.caption.monospacedDigit()) }
            Text(model.sharedScore != nil ? "Shared score · open Together on iPhone" : "Log each point").font(.system(size: 10.5)).foregroundStyle(WatchPalette.secondary)
        }
    }
}

/// A tinted tile with an icon over its label, as in the mockup's Won / Lost buttons.
private struct PointButton: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(color)
            .frame(width: 80, height: 64)
            .background(color.opacity(0.28), in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

struct SessionPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            if model.sessionActive {
                if let start = model.sessionStart {
                    Text(start, style: .timer)
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                }
            } else {
                Image(systemName: "tennis.racket").font(.system(size: 34)).foregroundStyle(Color.accentColor)
            }
            Button {
                model.toggleSession()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.sessionActive ? "stop.fill" : "play.fill").font(.system(size: 14))
                    Text(model.sessionActive ? "End" : "Start").font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(model.sessionActive ? .white : .black)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(model.sessionActive ? WatchPalette.red : Color.accentColor, in: .capsule)
            }
            .buttonStyle(.plain)
            if model.workout.isRunning {
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        Image(systemName: "heart")
                        Text("\(Int(model.workout.heartRate))")
                    }
                    .foregroundStyle(WatchPalette.red)
                    HStack(spacing: 3) {
                        Image(systemName: "flame")
                        Text("\(Int(model.workout.activeCalories)) kcal")
                    }
                    .foregroundStyle(WatchPalette.orange)
                }
                .font(.system(size: 12.5, weight: .medium))
            }
            if model.workout.isTransitioning { ProgressView() }
            if let status = model.workout.statusMessage {
                Text(status).font(.caption2).multilineTextAlignment(.center)
            }
            Text(model.phoneReachable ? "iPhone connected" : "Open Tennis Buddee on your iPhone")
                .font(.system(size: 10.5)).foregroundStyle(WatchPalette.secondary).multilineTextAlignment(.center)
        }
    }
}
