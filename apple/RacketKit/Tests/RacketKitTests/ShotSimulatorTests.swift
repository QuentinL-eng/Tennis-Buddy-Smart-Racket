import XCTest
@testable import RacketKit

final class ShotSimulatorTests: XCTestCase {
    private var baseline: ShotSimulator.Parameters {
        .init(swingSpeedKmh: 90, pathAngleDeg: 20, faceAngleDeg: 0, contactXcm: 0, contactYcm: 0)
    }

    func testMatchesAnalyzerSpeedAndSpinEquations() {
        let result = ShotSimulator.simulate(baseline)
        XCTAssertEqual(result.ballSpeedKmh, 0.42 * 43.2 + 1.42 * 90, accuracy: 0.001)
        let expectedSpin = 0.7 * 25 * sin(20 * Double.pi / 180) / 0.0335 * 60 / (2 * Double.pi)
        XCTAssertEqual(result.spinRPM, expectedSpin, accuracy: 0.001)
        XCTAssertEqual(result.spin, .topspin)
    }

    func testSlowerSwingAndOffCenterContactReduceBallSpeed() {
        let before = ShotSimulator.simulate(baseline)
        var slower = baseline; slower.swingSpeedKmh *= 0.95
        let after = ShotSimulator.simulate(slower)
        XCTAssertLessThan(after.ballSpeedKmh, before.ballSpeedKmh)
        XCTAssertEqual(after.spinRPM / before.spinRPM, 0.95, accuracy: 0.0001)
        var offset = baseline; offset.contactXcm = 10
        XCTAssertLessThan(ShotSimulator.simulate(offset).ballSpeedKmh, before.ballSpeedKmh)
    }

    func testFacePathAlignmentProducesNoBrushAndDirectionSetsSpin() {
        var p = baseline; p.faceAngleDeg = p.pathAngleDeg
        XCTAssertEqual(ShotSimulator.simulate(p).spinRPM, 0, accuracy: 0.0001)
        p.faceAngleDeg = 0; p.pathAngleDeg = -20
        XCTAssertEqual(ShotSimulator.simulate(p).spin, .slice)
    }

    func testClampsExtremeAndNonFiniteInputs() throws {
        let p = ShotSimulator.Parameters(swingSpeedKmh: 300, pathAngleDeg: .infinity,
            faceAngleDeg: -999, contactXcm: .nan, contactYcm: 999, incomingSpeedKmh: -10)
        let r = ShotSimulator.simulate(p)
        XCTAssertEqual(r.parameters.swingSpeedKmh, 200)
        XCTAssertEqual(r.parameters.pathAngleDeg, 0)
        XCTAssertEqual(r.parameters.faceAngleDeg, -60)
        XCTAssertEqual(r.parameters.contactXcm, 0)
        XCTAssertEqual(r.parameters.contactYcm, 14)
        XCTAssertEqual(r.parameters.incomingSpeedKmh, 0)
        XCTAssertTrue(r.ballSpeedKmh.isFinite && r.spinRPM.isFinite)
        XCTAssertNoThrow(try JSONEncoder().encode(r))
    }

    func testServeWithoutIncomingBallAndZeroSwing() {
        var p = baseline; p.incomingSpeedKmh = 0
        XCTAssertEqual(ShotSimulator.simulate(p).ballSpeedKmh, 1.42 * 90, accuracy: 0.001)
        p.swingSpeedKmh = 0
        XCTAssertEqual(ShotSimulator.simulate(p).ballSpeedKmh, 0)
        XCTAssertEqual(ShotSimulator.simulate(p).spinRPM, 0)
    }
}
