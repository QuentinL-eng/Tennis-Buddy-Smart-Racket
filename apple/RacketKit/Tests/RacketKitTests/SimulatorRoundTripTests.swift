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
