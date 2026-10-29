import Foundation

/// The two sides of a match, from the wearer's point of view.
public enum Player: String, Codable, Sendable, CaseIterable {
    case me, opponent
    public var other: Player { self == .me ? .opponent : .me }
}

/// A score for both players (points, games or sets).
public struct ScorePair: Codable, Sendable, Equatable {
    public var me = 0
    public var opponent = 0
    public init(me: Int = 0, opponent: Int = 0) {
        self.me = me
        self.opponent = opponent
    }
    public subscript(_ p: Player) -> Int {
        get { p == .me ? me : opponent }
        set { if p == .me { me = newValue } else { opponent = newValue } }
    }
}

public struct MatchRules: Codable, Sendable, Equatable {
    /// 2 = best of three sets, 1 = a single set.
    public var setsToWin = 2
    public var gamesPerSet = 6
    /// No-ad scoring: at deuce the next point wins the game.
    public var noAd = false
    /// The deciding set is a 10-point match tiebreak (common in club doubles).
    public var matchTiebreak = false
    /// Just count points up, one for you and one for your opponent: no games, sets or tiebreaks.
    public var simpleCount = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case setsToWin, gamesPerSet, noAd, matchTiebreak, simpleCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setsToWin = try c.decodeIfPresent(Int.self, forKey: .setsToWin) ?? 2
        gamesPerSet = try c.decodeIfPresent(Int.self, forKey: .gamesPerSet) ?? 6
        noAd = try c.decodeIfPresent(Bool.self, forKey: .noAd) ?? false
        matchTiebreak = try c.decodeIfPresent(Bool.self, forKey: .matchTiebreak) ?? false
        simpleCount = try c.decodeIfPresent(Bool.self, forKey: .simpleCount) ?? false
    }
}

/// What a point decided, for the announcement.
public enum ScoreEvent: Equatable, Sendable {
    case point, game(Player), set(Player), match(Player)
}

/// Standard tennis scoring: points, games (deuce/advantage or no-ad), sets with a 7-point tiebreak at 6–6,
/// optionally a 10-point match tiebreak instead of the deciding set.
public struct MatchScore: Codable, Sendable, Equatable {
    public var rules: MatchRules
    /// Finished sets, in games (a match tiebreak is stored as its points).
    public var sets: [ScorePair] = []
    public var games = ScorePair()
    /// Points in the current game, or in the tiebreak.
    public var points = ScorePair()
    public var winner: Player?

    public init(rules: MatchRules = MatchRules()) { self.rules = rules }

    public func setsWon(_ p: Player) -> Int {
        sets.filter { $0[p] > $0[p.other] }.count
    }

    /// The deciding set is being played as a match tiebreak.
    public var isMatchTiebreak: Bool {
        rules.matchTiebreak && rules.setsToWin > 1
            && setsWon(.me) == rules.setsToWin - 1 && setsWon(.opponent) == rules.setsToWin - 1
    }

    public var isTiebreak: Bool {
        isMatchTiebreak || (games.me == rules.gamesPerSet && games.opponent == rules.gamesPerSet)
    }

    @discardableResult
    public mutating func award(_ p: Player) -> ScoreEvent {
        guard winner == nil else { return .match(winner!) }
        points[p] += 1
        if rules.simpleCount { return .point }
        let a = points[p], b = points[p.other]
        if isTiebreak {
            let target = isMatchTiebreak ? 10 : 7
            guard a >= target, a - b >= 2 else { return .point }
            if isMatchTiebreak {
                sets.append(points)
            } else {
                games[p] += 1
                sets.append(games)
            }
            return finishSet(p)
        }
        let gameOver = rules.noAd ? a >= 4 : (a >= 4 && a - b >= 2)
        guard gameOver else { return .point }
        points = ScorePair()
        games[p] += 1
        let g = games[p], o = games[p.other]
        guard g >= rules.gamesPerSet, g - o >= 2 else { return .game(p) }
        sets.append(games)
        return finishSet(p)
    }

    private mutating func finishSet(_ p: Player) -> ScoreEvent {
        games = ScorePair()
        points = ScorePair()
        if setsWon(p) >= rules.setsToWin {
            winner = p
            return .match(p)
        }
        return .set(p)
    }

    // MARK: - Text

    private static let calls = ["0", "15", "30", "40"]
    private static let spokenCalls = ["love", "fifteen", "thirty", "forty"]

    /// The current game score for display, wearer first: "30–15", "Deuce", "Ad you", or "5–3" in a tiebreak.
    public var pointText: String {
        if isTiebreak || rules.simpleCount { return "\(points.me)–\(points.opponent)" }
        let a = points.me, b = points.opponent
        if a >= 3 && b >= 3 {
            if a == b { return rules.noAd ? "Deciding point" : "Deuce" }
            return a > b ? "Ad you" : "Ad opponent"
        }
        return "\(Self.calls[min(a, 3)])–\(Self.calls[min(b, 3)])"
    }

    /// One player's column on a scoreboard: "0", "15", "30", "40", "AD", or tiebreak points.
    public func pointCall(_ p: Player) -> String {
        if isTiebreak || rules.simpleCount { return "\(points[p])" }
        let a = points[p], b = points[p.other]
        if a >= 3 && b >= 3 { return a > b ? "AD" : "40" }
        return Self.calls[min(a, 3)]
    }

    /// What to say after a point, wearer first.
    public func announcement(for event: ScoreEvent) -> String {
        func name(_ p: Player) -> String { p == .me ? "you" : "opponent" }
        func lead(_ s: ScorePair) -> String {
            if s.me == s.opponent { return "\(s.me) all" }
            let (hi, lo) = (max(s.me, s.opponent), min(s.me, s.opponent))
            return s.me > s.opponent ? "you lead \(hi) \(lo)" : "opponent leads \(hi) \(lo)"
        }
        switch event {
        case .match(let p):
            return p == .me ? "Game, set and match. You win." : "Game, set and match to your opponent."
        case .set(let p):
            let last = sets.last ?? ScorePair()
            return "Set, \(name(p)), \(last.me) \(last.opponent). Sets: \(lead(ScorePair(me: setsWon(.me), opponent: setsWon(.opponent))))."
        case .game(let p):
            return "Game, \(name(p)). \(lead(games))."
        case .point:
            if rules.simpleCount {
                return points.me == points.opponent ? "\(points.me) all." : "\(points.me) \(points.opponent)."
            }
            if isTiebreak { return "\(isMatchTiebreak ? "Match tiebreak" : "Tiebreak"), \(lead(points))." }
            let a = points.me, b = points.opponent
            if a >= 3 && b >= 3 {
                if a == b { return rules.noAd ? "Deuce, deciding point." : "Deuce." }
                return a > b ? "Advantage you." : "Advantage opponent."
            }
            if a == b { return "\(Self.spokenCalls[a]) all." }
            return "\(Self.spokenCalls[min(a, 3)]) \(Self.spokenCalls[min(b, 3)])."
        }
    }
}

/// A match in progress with an undo history: every point can be taken back.
public struct ScoreTracker: Codable, Sendable, Equatable {
    public private(set) var score: MatchScore
    /// Who won each point, oldest first.
    public private(set) var log: [Player] = []
    private var history: [MatchScore] = []
    public var startDate = Date()

    public init(rules: MatchRules = MatchRules()) { score = MatchScore(rules: rules) }

    public var canUndo: Bool { !history.isEmpty }
    public var pointsWon: Int { log.filter { $0 == .me }.count }
    public var pointsLost: Int { log.filter { $0 == .opponent }.count }

    @discardableResult
    public mutating func award(_ p: Player) -> ScoreEvent {
        if let w = score.winner { return .match(w) }
        history.append(score)
        log.append(p)
        return score.award(p)
    }

    /// Takes back the last point. Returns who had won it, or nil when there is nothing to undo.
    @discardableResult
    public mutating func undo() -> Player? {
        guard let previous = history.popLast() else { return nil }
        score = previous
        return log.popLast()
    }

    /// Finished sets plus the set in progress, e.g. "6–4 3–2". Empty for a simple point count, which has no sets.
    public var setsText: String {
        if score.rules.simpleCount { return "" }
        var parts = score.sets.map { "\($0.me)–\($0.opponent)" }
        if score.winner == nil { parts.append("\(score.games.me)–\(score.games.opponent)") }
        return parts.joined(separator: "  ")
    }
}
