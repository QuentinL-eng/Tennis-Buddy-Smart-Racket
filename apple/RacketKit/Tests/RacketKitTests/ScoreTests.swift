import XCTest
import simd
@testable import RacketKit

final class TennisScoreTests: XCTestCase {
    private func play(_ s: inout MatchScore, _ p: Player, _ n: Int) {
        for _ in 0..<n { s.award(p) }
    }

    func testGameWithDeuceAndAdvantage() {
        var s = MatchScore()
        play(&s, .me, 2)
        XCTAssertEqual(s.pointText, "30–0")
        play(&s, .opponent, 3)
        XCTAssertEqual(s.pointText, "30–40")
        s.award(.me)
        XCTAssertEqual(s.pointText, "Deuce")
        s.award(.me)
        XCTAssertEqual(s.pointText, "Ad you")
        XCTAssertEqual(s.announcement(for: .point), "Advantage you.")
        s.award(.opponent)
        XCTAssertEqual(s.pointText, "Deuce")
        s.award(.opponent)
        XCTAssertEqual(s.award(.opponent), .game(.opponent))
        XCTAssertEqual(s.games, ScorePair(me: 0, opponent: 1))
        XCTAssertEqual(s.pointText, "0–0")
    }

    func testNoAdDecidesAtDeuce() {
        var rules = MatchRules()
        rules.noAd = true
        var s = MatchScore(rules: rules)
        play(&s, .me, 3)
        play(&s, .opponent, 3)
        XCTAssertEqual(s.pointText, "Deciding point")
        XCTAssertEqual(s.award(.opponent), .game(.opponent))
    }

    func testSetNeedsTwoGameLeadThenTiebreak() {
        var s = MatchScore()
        for _ in 0..<5 { play(&s, .me, 4); play(&s, .opponent, 4) }   // 5–5
        play(&s, .me, 4)
        XCTAssertEqual(s.games, ScorePair(me: 6, opponent: 5))
        play(&s, .opponent, 4)
        XCTAssertTrue(s.isTiebreak)
        play(&s, .me, 6)
        play(&s, .opponent, 6)
        XCTAssertEqual(s.pointText, "6–6")
        s.award(.me)
        XCTAssertEqual(s.award(.me), .set(.me))
        XCTAssertEqual(s.sets, [ScorePair(me: 7, opponent: 6)])
        XCTAssertFalse(s.isTiebreak)
    }

    func testStraightSetsWinsMatch() {
        var s = MatchScore()
        play(&s, .me, 4 * 6)
        XCTAssertEqual(s.sets, [ScorePair(me: 6, opponent: 0)])
        play(&s, .me, 4 * 5)
        XCTAssertEqual(s.award(.me), .point)
        play(&s, .me, 2)
        XCTAssertEqual(s.award(.me), .match(.me))
        XCTAssertEqual(s.winner, .me)
        XCTAssertEqual(s.award(.opponent), .match(.me), "points after the match are ignored")
    }

    func testMatchTiebreakReplacesDecidingSet() {
        var rules = MatchRules()
        rules.matchTiebreak = true
        var s = MatchScore(rules: rules)
        play(&s, .me, 24)
        play(&s, .opponent, 24)
        XCTAssertTrue(s.isMatchTiebreak)
        play(&s, .me, 9)
        play(&s, .opponent, 9)
        XCTAssertEqual(s.announcement(for: .point), "Match tiebreak, 9 all.")
        s.award(.me)
        XCTAssertEqual(s.award(.me), .match(.me))
        XCTAssertEqual(s.sets.last, ScorePair(me: 11, opponent: 9))
    }

    func testTrackerUndoRestoresEverything() {
        var t = ScoreTracker()
        for _ in 0..<4 { t.award(.me) }   // 1–0 in games
        t.award(.opponent)
        XCTAssertEqual(t.score.games, ScorePair(me: 1, opponent: 0))
        XCTAssertEqual(t.undo(), .opponent)
        XCTAssertEqual(t.undo(), .me)
        XCTAssertEqual(t.score.games, ScorePair(me: 0, opponent: 0))
        XCTAssertEqual(t.score.pointText, "40–0")
        XCTAssertEqual(t.pointsWon, 3)
        XCTAssertEqual(t.pointsLost, 0)
        while t.canUndo { t.undo() }
        XCTAssertNil(t.undo())
        XCTAssertEqual(t.score, MatchScore())
    }

    func testSpokenScores() {
        var s = MatchScore()
        var e = s.award(.me)
        XCTAssertEqual(s.announcement(for: e), "fifteen love.")
        e = s.award(.opponent)
        XCTAssertEqual(s.announcement(for: e), "fifteen all.")
        play(&s, .me, 2)
        e = s.award(.me)
        XCTAssertEqual(e, .game(.me))
        XCTAssertEqual(s.announcement(for: e), "Game, you. you lead 1 0.")
        play(&s, .opponent, 4)
        XCTAssertEqual(s.announcement(for: .game(.opponent)), "Game, opponent. 1 all.")
    }
}

final class TapSideTests: XCTestCase {
    func testGestureMapping() {
        XCTAssertEqual(ScoreCommand.from(count: 2, side: .wide), .won)
        XCTAssertEqual(ScoreCommand.from(count: 1, side: .narrow), .lost)
        XCTAssertEqual(ScoreCommand.from(count: 3, side: nil), .undo)
        XCTAssertEqual(ScoreCommand.from(count: 4, side: .wide), .undo)
        XCTAssertNil(ScoreCommand.from(count: 1, side: .wide))
        XCTAssertNil(ScoreCommand.from(count: 2, side: .narrow))
        XCTAssertEqual(ScoreCommand.from(count: 2, side: nil), .won)
        XCTAssertEqual(ScoreCommand.from(count: 1, side: nil), .lost)
    }

    func testFitIgnoresSignAndNoise() throws {
        let wide: [SIMD3<Float>] = [SIMD3(0.1, 0.05, 0.99), SIMD3(-0.05, 0.1, -0.98), SIMD3(0.15, -0.1, 0.97)]
        let narrow: [SIMD3<Float>] = [SIMD3(0.1, 0.99, 0.05), SIMD3(0.05, -0.97, -0.1), SIMD3(-0.2, 0.95, 0.1)]
        let cal = try XCTUnwrap(TapCalibration.fit(wide: wide, narrow: narrow))
        XCTAssertGreaterThan(abs(cal.wideAxis.z), 0.95)
        XCTAssertGreaterThan(abs(cal.narrowAxis.y), 0.95)
        XCTAssertGreaterThan(cal.separationDegrees, 75)
        XCTAssertEqual(cal.classify(SIMD3(0, 0, -1))?.side, .wide)
        XCTAssertEqual(cal.classify(SIMD3(0, 0.9, 0.2))?.side, .narrow)
        XCTAssertNil(cal.classify(simd_normalize(SIMD3(0, 1, 1))), "halfway between the sides is unknown")
        XCTAssertNil(TapCalibration.fit(wide: [SIMD3(0, 0, 1)], narrow: narrow), "one tap is not enough")
    }

    func testDefaultUsesRacketAxes() {
        let cal = TapCalibration.fromRacket(.default)
        // Default racket calibration: racket z = -sensor z, racket y = sensor x.
        XCTAssertEqual(cal.classify(SIMD3(0, 0, 1))?.side, .wide)
        XCTAssertEqual(cal.classify(SIMD3(1, 0, 0))?.side, .narrow)
        XCTAssertFalse(cal.isCalibrated)
    }

    func testDecodeTap() {
        let data = Data([0x05, 0x00, 2, 200, 0, 0, 0x81, 0, 127])   // dir (-1, 0, 1) before normalising
        let t = RacketProtocol.decodeTap(data)
        XCTAssertEqual(t?.seq, 5)
        XCTAssertEqual(t?.count, 2)
        XCTAssertEqual(t?.strength, 200)
        XCTAssertEqual(t?.direction.x ?? 0, -1, accuracy: 0.01)
        XCTAssertEqual(t?.direction.z ?? 0, 1, accuracy: 0.01)
    }
}
