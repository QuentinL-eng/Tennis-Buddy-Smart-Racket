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
    var lastShot: ShotMetrics?
    var summary: ShotSummary?
    var pointsWon = 0
    var pointsLost = 0
    var phoneReachable = false
    var units = UnitSystem(metric: false)
    let workout = WorkoutManager()

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func toggleSession() {
        if sessionActive { sendHealth() }
        send(["cmd": sessionActive ? "stop" : "start"])
        setSessionActive(!sessionActive)
        WKInterfaceDevice.current().play(sessionActive ? .start : .stop)
    }

    /// Keeps the Tennis workout (heart rate, calories, Apple Health) in step with the racket session.
    func setSessionActive(_ active: Bool) {
        guard active != sessionActive || active != workout.isRunning else { return }
        if active && !sessionActive { pointsWon = 0; pointsLost = 0; lastShot = nil; summary = nil }
        if !active && sessionActive && workout.isRunning { sendHealth() }
        sessionActive = active
        Task { active ? await workout.start() : await workout.stop() }
    }

    private func sendHealth() {
        send(["cmd": "health", "avgHR": workout.averageHeartRate, "kcal": workout.activeCalories])
    }

    func logPoint(won: Bool) {
        if won { pointsWon += 1 } else { pointsLost += 1 }
        send(["cmd": "point", "won": won])
        WKInterfaceDevice.current().play(.click)
    }

    private func send(_ message: [String: Any]) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(message, replyHandler: { reply in
            if let active = reply["sessionActive"] as? Bool {
                Task { @MainActor in self.setSessionActive(active) }
            }
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
            setSessionActive(active)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        nonisolated(unsafe) let msg = message
        Task { @MainActor in self.handle(msg) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        let active = ctx["sessionActive"] as? Bool
        Task { @MainActor in if let active { self.setSessionActive(active) } }
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
            LastShotPage()
            PointsPage()
            SessionPage()
        }
        .tabViewStyle(.verticalPage)
    }
}

struct LastShotPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if let shot = model.lastShot {
                HStack {
                    Image(systemName: shot.type.symbol)
                    Text(shot.type.label).font(.headline)
                    Spacer()
                    Circle().fill(shot.isSweetSpot ? .green : .red).frame(width: 10, height: 10)
                }
                Text(model.units.speedValue(shot.ballSpeedKmh))
                    .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                Text("\(model.units.speedUnit) · \(Int(shot.spinRPM)) rpm").font(.caption).foregroundStyle(.secondary)
                if let s = model.summary {
                    Text("\(s.count) shots · \(Int(s.sweetSpotPercent))% sweet spot")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if model.workout.heartRate > 0 {
                    Label("\(Int(model.workout.heartRate)) bpm", systemImage: "heart.fill")
                        .font(.caption2).foregroundStyle(.red)
                }
            } else {
                Image(systemName: "figure.tennis").font(.largeTitle).foregroundStyle(Color.accentColor)
                Text(model.sessionActive ? "Waiting for your first shot" : "Start a session to see shots here")
                    .font(.caption).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 4)
        .containerBackground(
            (model.lastShot?.isSweetSpot ?? true ? Color.green : Color.red).opacity(model.lastShot == nil ? 0 : 0.25)
                .gradient, for: .tabView)
    }
}

struct PointsPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Text("\(model.pointsWon) – \(model.pointsLost)")
                .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
            HStack {
                Button { model.logPoint(won: true) } label: { Label("Won", systemImage: "checkmark") }
                    .tint(.green)
                Button { model.logPoint(won: false) } label: { Label("Lost", systemImage: "xmark") }
                    .tint(.red)
            }
            .disabled(!model.sessionActive)
            Text("Log each point").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct SessionPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Button {
                model.toggleSession()
            } label: {
                Label(model.sessionActive ? "End" : "Start", systemImage: model.sessionActive ? "stop.fill" : "play.fill")
                    .font(.headline)
            }
            .tint(model.sessionActive ? .red : .accentColor)
            .foregroundStyle(model.sessionActive ? .white : .black)
            if model.workout.isRunning {
                HStack {
                    Label("\(Int(model.workout.heartRate))", systemImage: "heart.fill").foregroundStyle(.red)
                    Label("\(Int(model.workout.activeCalories)) kcal", systemImage: "flame.fill").foregroundStyle(.orange)
                }
                .font(.caption)
            }
            Text(model.phoneReachable ? "iPhone connected" : "Open Tennis Buddy on your iPhone")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
