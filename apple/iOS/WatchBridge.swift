import Foundation
import RacketKit
import WatchConnectivity

/// iPhone side of the Watch link: pushes shots and session state, receives start/stop and point logging.
/// Message keys are shared with Watch/WatchModel.swift.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    private weak var model: AppModel?

    func connect(to model: AppModel) {
        self.model = model
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()

        model.onShotForWatch = { [weak self] shot in self?.send(shot: shot) }
        model.onSessionChangeForWatch = { [weak self] active in self?.sendSessionState(active: active) }
        model.onDrillChangeForWatch = { [weak self] drill in self?.send(drill: drill) }
    }

    private func send(shot: ShotMetrics) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable,
              let data = try? JSONEncoder().encode(shot) else { return }
        let summary = model.map { ShotSummary($0.sessionShots) }
        var msg: [String: Any] = ["type": "shot", "shot": data, "metric": UnitSystem.current.metric]
        if let summary, let s = try? JSONEncoder().encode(summary) { msg["summary"] = s }
        WCSession.default.sendMessage(msg, replyHandler: nil)
    }

    /// Drill updates go both as a live message and in the application context, so the Watch catches up on launch.
    private func send(drill: Drill?) {
        guard WCSession.default.activationState == .activated else { return }
        let data = drill.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        var ctx = WCSession.default.applicationContext
        ctx["drill"] = data
        ctx["updated"] = Date().timeIntervalSince1970
        try? WCSession.default.updateApplicationContext(ctx)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["type": "drill", "drill": data], replyHandler: nil)
        }
    }

    private func sendSessionState(active: Bool) {
        guard WCSession.default.activationState == .activated else { return }
        var ctx = WCSession.default.applicationContext
        ctx["sessionActive"] = active
        ctx["updated"] = Date().timeIntervalSince1970
        try? WCSession.default.updateApplicationContext(ctx)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["type": "session", "active": active], replyHandler: nil)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let cmd = message["cmd"] as? String
        let won = message["won"] as? Bool
        let avgHR = message["avgHR"] as? Double
        let kcal = message["kcal"] as? Double
        Task { @MainActor in
            guard let model = self.model else { return replyHandler([:]) }
            switch cmd {
            case "start": model.startSession()
            case "stop": model.stopSession()
            case "point": if let won { model.logPoint(won: won) }
            case "health": model.recordHealth(averageHeartRate: avgHR ?? 0, calories: kcal ?? 0)
            case "cancelDrill": model.cancelDrill()
            default: break
            }
            replyHandler(["sessionActive": model.isSessionActive])
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
