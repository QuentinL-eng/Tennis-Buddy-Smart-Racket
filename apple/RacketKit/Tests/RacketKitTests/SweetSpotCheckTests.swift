import XCTest
import simd
@testable import RacketKit

final class SweetSpotCheckTests: XCTestCase {
    private let center = SweetSpotCheck.Cell(col: 0, row: 0)
    private let tipLeft = SweetSpotCheck.Cell(col: -1, row: 1)

    private func verdict(sweet: Bool, off: Int = 0) -> RacketProtocol.ShotVerdict {
        RacketProtocol.ShotVerdict(seq: 0, isSweet: sweet, offCenterPercent: off, confidencePercent: 80, level: 200)
    }

    private func shot() -> ShotMetrics {
        ShotMetrics(date: Date(), type: .calibration, swingSpeedKmh: 0, ballSpeedKmh: 0, spinRPM: 0, spin: .flat,
                    faceAngleDeg: 0, swingPathDeg: 0, impactXcm: 1, impactYcm: 2, peakG: 12, gyroSaturated: false,
                    features: ImpactFeatures(rollRatio: 0.1, ringNorm: 0.2, jolt: 0.03, impulse: 0.5))
    }

    func testOnlyCenterSquareIsSweet() {
        XCTAssertTrue(center.isSweet)
        for col in -1...1 { for row in -1...1 where col != 0 || row != 0 {
            XCTAssertFalse(SweetSpotCheck.Cell(col: col, row: row).isSweet, "\(col),\(row)")
        } }
        XCTAssertEqual(tipLeft.name, "tip-left")
        XCTAssertEqual(tipLeft.distanceCm, (25.0 + 36).squareRoot(), accuracy: 1e-9)
    }

    func testVerdictAndImpactOfOneDropArePaired() {
        var check = SweetSpotCheck()
        let t = Date()
        check.add(shot: shot(), cell: center, at: t)
        check.add(verdict: verdict(sweet: true), cell: center, at: t.addingTimeInterval(0.2))
        XCTAssertEqual(check.drops.count, 1)
        XCTAssertEqual(check.drops[0].racketCorrect, true)
        XCTAssertEqual(check.drops[0].peakG, 12)

        // Too late to be the same drop: a new one.
        check.add(verdict: verdict(sweet: true), cell: center, at: t.addingTimeInterval(2))
        XCTAssertEqual(check.drops.count, 2)
        XCTAssertNil(check.drops[1].features)
    }

    func testScoring() {
        var check = SweetSpotCheck()
        var t = Date()
        func next() -> Date { t = t.addingTimeInterval(3); return t }
        check.add(verdict: verdict(sweet: true), cell: center, at: next())
        check.add(verdict: verdict(sweet: false, off: 40), cell: center, at: next())
        check.add(verdict: verdict(sweet: false, off: 70), cell: tipLeft, at: next())
        check.add(shot: shot(), cell: tipLeft, at: next())   // no verdict: not scored
        XCTAssertEqual(check.scored, 3)
        XCTAssertEqual(check.correct, 2)
        XCTAssertEqual(check.sweetHits.correct, 1)
        XCTAssertEqual(check.sweetHits.of, 2)
        XCTAssertEqual(check.offHits.correct, 1)
        XCTAssertEqual(check.offHits.of, 1)
        check.undo()
        XCTAssertEqual(check.drops.count, 3)
    }

    func testCSVHasOneRowPerDrop() {
        var check = SweetSpotCheck()
        check.add(verdict: verdict(sweet: false, off: 55), cell: tipLeft)
        let lines = check.csv().split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false)
        let row = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(header.count, row.count)
        XCTAssertEqual(row[header.firstIndex(of: "cell")!], "tip-left")
        XCTAssertEqual(row[header.firstIndex(of: "racket_correct")!], "1")
        XCTAssertEqual(row[header.firstIndex(of: "off_center_pct")!], "55")
    }

    /// The high-g channel shares the low-g axes, so it gets the same rotation even when its gravity reading is noisy.
    func testPoseCalibrationUsesLowGAxesForHighG() {
        let tip = Calibration.PoseReading(samples: [IMUSample(time: 0, accel: SIMD3(0, 1, 0), gyro: .zero,
                                                              highG: SIMD3(0.4, 0.6, -0.5))])
        let face = Calibration.PoseReading(samples: [IMUSample(time: 0, accel: SIMD3(0, 0, -1), gyro: .zero,
                                                               highG: SIMD3(0.5, 0.3, -0.4))])
        let cal = Calibration.from(tipUp: tip, faceUp: face)
        XCTAssertEqual(cal.h3lisToRacket, cal.mpuToRacket)
        XCTAssertEqual(cal.mpuToRacket, Calibration.default.mpuToRacket)
    }
}
