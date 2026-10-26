import XCTest
import simd
@testable import RacketKit

/// Runs simulated swings through the engine and checks the analyzer recovers sensible shots.
final class SimulatorRoundTripTests: XCTestCase {
    func testSimulatedShotsAreDetectedAndPlausible() throws {
        let sim = SimulatedRacket()
        sim.shotInterval = 2.5
        let engine = RacketEngine()
        var shots: [ShotMetrics] = []
        let done = expectation(description: "shots")
        engine.onShot = { shot in
            shots.append(shot)
            if shots.count == 12 { done.fulfill() }
        }
        engine.attach(sim)
        sim.start()
        wait(for: [done], timeout: 60)
        sim.stop()
        for s in shots {
            print(String(format: "%@ swing %.0f ball %.0f km/h spin %.0f %@ face %.0f path %.0f hit (%.1f, %.1f) ring %.3f jolt %.3f imp %.1f",
                         s.type.label, s.swingSpeedKmh, s.ballSpeedKmh, s.spinRPM, s.spin.label, s.faceAngleDeg,
                         s.swingPathDeg, s.impactXcm, s.impactYcm, s.features.ringNorm, s.features.jolt, s.features.impulse))
        }
        XCTAssertGreaterThanOrEqual(shots.count, 12)
        XCTAssertTrue(shots.allSatisfy { $0.swingSpeedKmh > 5 && $0.swingSpeedKmh < 200 })
    }
}

final class DrillParsingTests: XCTestCase {
    func testParsesCoachDrill() {
        let d = Drill.parse("TITLE: Center the backhand\nGOAL: 10 backhands in the sweet spot\nWHY: Only 40% hit it.")
        XCTAssertEqual(d.title, "Center the backhand")
        XCTAssertEqual(d.target, 10)
        XCTAssertEqual(d.stroke, .backhand)
        XCTAssertEqual(d.criterion, .sweetSpot)
    }

    func testParsesSpinAndSpeedThresholds() {
        XCTAssertEqual(Drill.parse("GOAL: 8 forehands over 1800 rpm").criterion, .minSpinRPM(1800))
        let mph = Drill.parse("**GOAL:** 5 serves above 90 mph")
        XCTAssertEqual(mph.target, 5)
        XCTAssertEqual(mph.stroke, .serve)
        if case .minBallKmh(let k) = mph.criterion { XCTAssertEqual(k, 144.84, accuracy: 0.1) } else { XCTFail() }
    }
}
