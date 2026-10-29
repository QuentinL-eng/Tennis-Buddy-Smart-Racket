import Foundation
import RacketKit
import WatchConnectivity

/// iPhone side of the Watch link: pushes shots and session state, receives start/stop and point logging.
/// Message keys are shared with Watch/WatchModel.swift.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    private weak var model: AppModel?
    private weak var account: AccountModel?

    func connect(to model: AppModel, account: AccountModel) {
        self.model = model
        self.account = account
        account.onSharedMatchChange = { [weak self] state, player in self?.sendSharedScore(state, player: player) }
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

    private func sendSharedScore(_ state: SharedMatchState?, player: UUID?) {
        guard WCSession.default.activationState == .activated else { return }
        let tracker = state.flatMap { state in player.map { state.tracker(for: $0) } }
        let data = tracker.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        var ctx = WCSession.default.applicationContext
        ctx["sharedScore"] = data
        ctx["sharedMatchID"] = state?.id.uuidString ?? ""
        ctx["sharedRevision"] = state?.revision ?? 0
        ctx["sharedScoreActive"] = state.map { !$0.ended && $0.guest != nil } ?? false
        try? WCSession.default.updateApplicationContext(ctx)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["type": "sharedScore", "score": data,
                "active": ctx["sharedScoreActive"] as? Bool ?? false,
                "matchID": state?.id.uuidString ?? "", "revision": state?.revision ?? 0], replyHandler: nil)
        }
    }

    private func sendSessionState(active: Bool) {
        guard WCSession.default.activationState == .activated else { return }
        var ctx = WCSession.default.applicationContext
        ctx["sessionActive"] = active
        ctx["sessionID"] = model?.activeSession?.id.uuidString ?? ""
        ctx["updated"] = Date().timeIntervalSince1970
        try? WCSession.default.updateApplicationContext(ctx)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["type": "session", "active": active, "sessionID": model?.activeSession?.id.uuidString ?? ""], replyHandler: nil)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        handleCommand(message, replyHandler: replyHandler)
    }

    private nonisolated func handleCommand(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let cmd = message["cmd"] as? String
        let won = message["won"] as? Bool
        let avgHR = message["avgHR"] as? Double
        let kcal = message["kcal"] as? Double
        let recordID = (message["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        let matchID = (message["matchID"] as? String).flatMap(UUID.init(uuidString:))
        let revision = message["revision"] as? Int
        Task { @MainActor in
            guard let model = self.model else { return replyHandler([:]) }
            var commandError: String?
            switch cmd {
            case "start": model.startSession(id: recordID ?? UUID())
            case "stop": if recordID == nil || recordID == model.activeSession?.id { model.stopSession() }
            case "point":
                if let won { model.logPoint(won: won) }
            case "sharedPoint":
                if let won, let state = self.account?.sharedMatch, state.id == matchID, state.revision == revision {
                    await self.account?.award(won: won)
                    commandError = self.account?.errorMessage
                } else {
                    commandError = "The shared score changed. Check the score and try again."
                    self.sendSharedScore(self.account?.sharedMatch, player: self.account?.userID)
                }
            case "health":
                if let recordID { model.recordHealth(averageHeartRate: avgHR ?? 0, calories: kcal ?? 0, sessionID: recordID) }
            case "cancelDrill": model.cancelDrill()
            default: break
            }
            replyHandler(["sessionActive": model.isSessionActive, "sessionID": model.activeSession?.id.uuidString ?? "",
                          "error": commandError ?? ""])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleCommand(userInfo) { _ in }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
