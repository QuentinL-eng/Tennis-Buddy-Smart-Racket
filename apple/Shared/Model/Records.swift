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

/// Something the coach should remember about a player across sessions ("rushes the backhand when tired",
/// "sore right elbow in 2025"). Written by the player, or by Muse through `remember_note`.
@Model
final class CoachNote {
    var id: UUID = UUID()
    /// `PlayerProfile.id` of the player the note is about.
    var playerID: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var text: String = ""
    var categoryRaw: String = CoachNote.Category.technique.rawValue
    /// "player" or "coach".
    var source: String = "player"
    /// The session that prompted the note, when there was one.
    var sessionID: UUID?

    enum Category: String, CaseIterable, Identifiable, Codable {
        case technique, fitness, injury, goal, preference, other
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .technique: "figure.tennis"
            case .fitness: "bolt.heart"
            case .injury: "bandage"
            case .goal: "flag"
            case .preference: "slider.horizontal.3"
            case .other: "note.text"
            }
        }
    }

    init(playerID: UUID, text: String, category: Category, source: String = "player", sessionID: UUID? = nil) {
        self.playerID = playerID
        self.text = text
        self.categoryRaw = category.rawValue
        self.source = source
        self.sessionID = sessionID
    }

    var category: Category {
        get { Category(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }
    var addedByCoach: Bool { source == "coach" }
}
