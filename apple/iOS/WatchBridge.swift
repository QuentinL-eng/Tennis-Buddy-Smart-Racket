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
    }

    private func send(shot: ShotMetrics) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable,
              let data = try? JSONEncoder().encode(shot) else { return }
        let summary = model.map { ShotSummary($0.sessionShots) }
        var msg: [String: Any] = ["type": "shot", "shot": data]
        if let summary, let s = try? JSONEncoder().encode(summary) { msg["summary"] = s }
        WCSession.default.sendMessage(msg, replyHandler: nil)
    }

    private func sendSessionState(active: Bool) {
        guard WCSession.default.activationState == .activated else { return }
        let ctx: [String: Any] = ["sessionActive": active, "updated": Date().timeIntervalSince1970]
        try? WCSession.default.updateApplicationContext(ctx)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["type": "session", "active": active], replyHandler: nil)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let cmd = message["cmd"] as? String
        let won = message["won"] as? Bool
        Task { @MainActor in
            guard let model = self.model else { return replyHandler([:]) }
            switch cmd {
            case "start": model.startSession()
            case "stop": model.stopSession()
            case "point": if let won { model.logPoint(won: won) }
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
