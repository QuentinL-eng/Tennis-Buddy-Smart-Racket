import Foundation
import RacketKit
import SwiftData

/// A practice session. All properties have defaults so the store can sync with CloudKit later.
@Model
final class SessionRecord {
    var id: UUID = UUID()
    var startDate: Date = Date()
    var endDate: Date?
    var title: String = ""
    /// Name of the player who was active when the session started.
    var playerName: String = ""
    var sharedMatchID: String = ""
    var sharedPlayerID: String = ""
    var sharedStatsPending: Bool = false
    var notes: String = ""
    var coachSummary: String = ""
    var pointsWon: Int = 0
    var pointsLost: Int = 0
    var averageHeartRate: Double = 0
    var activeCalories: Double = 0
    @Relationship(deleteRule: .cascade, inverse: \ShotRecord.session) var shotRecords: [ShotRecord]? = []

    init(startDate: Date = Date()) {
        self.startDate = startDate
        self.title = startDate.formatted(.dateTime.weekday(.wide).hour().minute())
    }

    var shots: [ShotMetrics] {
        (shotRecords ?? []).compactMap(\.metrics).sorted { $0.date < $1.date }
    }

    var duration: TimeInterval { (endDate ?? Date()).timeIntervalSince(startDate) }
    var summary: ShotSummary { ShotSummary(shots.filter { $0.type != .calibration }) }
}

@Model
final class ShotRecord {
    var date: Date = Date()
    var typeRaw: String = ShotType.forehand.rawValue
    var metricsData: Data = Data()
    var bookmarked: Bool = false
    var dataSourceRaw: String = ""
    var session: SessionRecord?

    init(metrics: ShotMetrics) {
        date = metrics.date
        typeRaw = metrics.type.rawValue
        metricsData = (try? JSONEncoder().encode(metrics)) ?? Data()
    }

    var metrics: ShotMetrics? { try? JSONDecoder().decode(ShotMetrics.self, from: metricsData) }
}
