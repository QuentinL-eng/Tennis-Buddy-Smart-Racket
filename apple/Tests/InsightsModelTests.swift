import RacketKit
import XCTest

final class InsightsModelTests: XCTestCase {
    private let now = Date()
    private func shot(_ type: ShotType, ball: Double, sweet: Bool = true, motion: Bool = true) -> ShotMetrics {
        var s = ShotMetrics(date: now, type: type, swingSpeedKmh: ball * 0.8, ballSpeedKmh: ball, spinRPM: 1000, spin: .flat,
                            faceAngleDeg: 0, swingPathDeg: 0, impactXcm: 0, impactYcm: sweet ? 1 : 9, peakG: 0,
                            gyroSaturated: false, features: ImpactFeatures(rollRatio: 0, ringNorm: 0, jolt: 0, impulse: 0))
        if !motion { s.micOnly = true }
        return s
    }
    private func session(daysAgo: Double, _ shots: [ShotMetrics]) -> InsightSession {
        InsightSession(id: UUID(), date: now.addingTimeInterval(-daysAgo * 86_400), duration: 600, averageHeartRate: 0, shots: shots)
    }
    private func model(_ s: [InsightSession], stroke: ShotType? = nil, metric: InsightMetric = .ballSpeed) -> InsightsModel {
        InsightsModel(sessions: s, period: .week, stroke: stroke, metric: metric, units: UnitSystem(metric: true), now: now)
    }

    func testRangeAndCalibrationAndMicOnlyAreFiltered() {
        let m = model([session(daysAgo: 1, [shot(.forehand, ball: 100), shot(.forehand, ball: 60),
                                           shot(.calibration, ball: 300), shot(.forehand, ball: 0, motion: false)])])
        XCTAssertEqual(m.points.first?.low, 60)
        XCTAssertEqual(m.points.first?.high, 100)
        XCTAssertEqual(m.periodAverage, 80)
    }

    func testDeltaUsesPreviousPeriodAndStrokeFilter() {
        let m = model([session(daysAgo: 10, [shot(.forehand, ball: 70)]),
                       session(daysAgo: 2, [shot(.forehand, ball: 90), shot(.backhand, ball: 10)])], stroke: .forehand)
        XCTAssertEqual(m.delta, 20)
    }

    func testSweetSpotPercentAndStrokeMinimum() {
        let shots = (0..<5).map { _ in shot(.serve, ball: 100) } + [shot(.volley, ball: 50)]
        let m = model([session(daysAgo: 1, shots)], metric: .sweetSpot)
        XCTAssertEqual(m.points.first?.avg, 100)
        XCTAssertEqual(m.byStroke.map(\.type), [.serve])
    }
}
