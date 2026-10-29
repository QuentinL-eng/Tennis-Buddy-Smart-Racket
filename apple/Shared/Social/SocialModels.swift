import Foundation
import RacketKit

struct SocialProfile: Codable, Identifiable {
    var id: UUID
    var name: String
    var friendCode: String
}

struct FriendRequest: Codable, Identifiable {
    var id: UUID { player.id }
    var player: SocialProfile
    var incoming: Bool
}

struct MatchInvitation: Codable, Identifiable {
    var id: UUID
    var title: String
    var hostName: String
}

struct SocialDashboard: Codable {
    var profile: SocialProfile
    var friends: [SocialProfile]
    var requests: [FriendRequest]
    var invitations: [MatchInvitation]
    var matches: [MatchInvitation]
}

struct SharedPoint: Codable, Identifiable {
    var id: UUID
    var winner: UUID
}

struct SharedPlayerStats: Codable, Identifiable {
    var id: UUID
    var shots: Int
    var sweetPercent: Double
    var averageBallKmh: Double?
    var topBallKmh: Double?
}

struct SharedMatchState: Codable, Identifiable {
    var id: UUID
    var title: String
    var host: SocialProfile
    var guest: SocialProfile?
    var inviteCode: String
    var ended: Bool
    var revision: Int
    var points: [SharedPoint]
    var stats: [SharedPlayerStats]

    /// The same ordered log is replayed from either player's perspective.
    func tracker(for player: UUID) -> ScoreTracker {
        var tracker = ScoreTracker()
        for point in points { tracker.award(point.winner == player ? .me : .opponent) }
        return tracker
    }
}
