import XCTest
import simd
@testable import TennisCamera

/// The 3D tracker is checked against synthetic flights whose truth is known
/// exactly, so the tolerances below are statements about the estimator rather
/// than about a particular afternoon in the lab.
final class FlightTrackerTests: XCTestCase {
    private let gravity = SIMD3<Double>(0, 9.80665, 0) // phone level, y down
    private let ballRadius = 0.0335

    // MARK: - Camera model

    func testIntrinsicsFollowTheReportedFieldOfView() {
        // A 26 mm-equivalent wide camera is about 67 degrees horizontal, which is
        // ~1450 px at 1920 wide. The real number comes from the format; a wrong
        // derivation would land outside this window.
        let camera = CameraModel(width: 1920, height: 1080, horizontalFOVDeg: 67)
        XCTAssertEqual(camera.fx, 1450.4, accuracy: 1.0)
        XCTAssertEqual(camera.fy, camera.fx)
        XCTAssertEqual(camera.cx, 960, accuracy: 0.001)
        XCTAssertEqual(camera.cy, 540, accuracy: 0.001)

        let narrow = CameraModel(width: 1920, height: 1080, horizontalFOVDeg: 50)
        XCTAssertGreaterThan(narrow.fx, camera.fx, "a narrower field of view is a longer lens")

        // A format that reports nothing usable falls back rather than producing a
        // zero focal length.
        let broken = CameraModel(width: 1920, height: 1080, horizontalFOVDeg: 0)
        XCTAssertEqual(broken.horizontalFOVDeg, CameraModel.fallbackFOVDeg)
        XCTAssertGreaterThan(broken.fx, 100)
    }

    func testDepthAndProjectionRoundTrip() throws {
        let camera = CameraModel(width: 1920, height: 1080, horizontalFOVDeg: 67)
        let point = SIMD3<Double>(0.2, -0.15, 2.4)
        let projected = try XCTUnwrap(camera.project(point, ballRadiusM: ballRadius))
        let depth = try XCTUnwrap(camera.depth(radiusPx: projected.r, ballRadiusM: ballRadius))
        XCTAssertEqual(depth, point.z, accuracy: 0.01)
        let back = camera.backProject(u: projected.u, v: projected.v, depthM: depth)
        XCTAssertEqual(simd_length(back - point), 0, accuracy: 0.02)
    }

    func testGravityIsExpressedInTheDeliveredImageFrame() {
        // Device axes: +x right, +y up the screen, +z out of the screen. The back
        // camera looks along -z and its image y points down.
        let device = SIMD3<Double>(0, -1, 0) // upright: gravity points down the screen
        let upright = CameraGravity.inCameraFrame(deviceGravity: device, rotationAngleDegrees: 0)
        XCTAssertEqual(upright.x, 0, accuracy: 1e-12)
        XCTAssertEqual(upright.y, 1, accuracy: 1e-12, "image y is down, so gravity is +y")
        XCTAssertEqual(upright.z, 0, accuracy: 1e-12)

        // Rotating the delivered image by 180 degrees rotates gravity with it.
        let flipped = CameraGravity.inCameraFrame(deviceGravity: device, rotationAngleDegrees: 180)
        XCTAssertEqual(flipped.x, 0, accuracy: 1e-12)
        XCTAssertEqual(flipped.y, -1, accuracy: 1e-12)
    }

    // MARK: - Flight model

    func testFreeFallMatchesGravity() {
        var model = FlightModel(gravity: gravity)
        model.ball.dragCoefficient = 0 // gravity on its own
        var position = SIMD3<Double>.zero
        var velocity = SIMD3<Double>.zero
        for _ in 0..<1000 { // 1 s in 1 ms steps
            let next = model.step(position: position, velocity: velocity, dt: 0.001)
            position = next.position
            velocity = next.velocity
        }
        XCTAssertEqual(position.y, 0.5 * 9.80665, accuracy: 0.01)
        XCTAssertEqual(velocity.y, 9.80665, accuracy: 0.01)
        XCTAssertEqual(position.x, 0, accuracy: 1e-12)
    }

    func testDragSlowsTheFall() {
        // A tennis ball is not in vacuum: after a second of fall the drag term
        // has taken off about 0.15 m and 0.55 m/s. If this ever matched the
        // vacuum answer, the drag coefficient would have stopped being applied.
        var model = FlightModel(gravity: gravity)
        var position = SIMD3<Double>.zero
        var velocity = SIMD3<Double>.zero
        for _ in 0..<1000 {
            let next = model.step(position: position, velocity: velocity, dt: 0.001)
            position = next.position
            velocity = next.velocity
        }
        XCTAssertLessThan(position.y, 0.5 * 9.80665 - 0.1)
        XCTAssertLessThan(velocity.y, 9.80665 - 0.3)
        XCTAssertGreaterThan(position.y, 4.5, "drag must not swamp gravity either")
        model.ball.dragCoefficient = 0
    }

    // MARK: - Tracking

    func testCleanFlightIsRecovered() throws {
        let flight = try Track(start: SIMD3(0.7, -0.45, 5.2), velocity: SIMD3(-2.1, 1.6, -9.5))
        let state = try XCTUnwrap(flight.predictions.last, "no fit on a clean flight")
        let truth = flight.truth(tNs: state.tNs)

        XCTAssertLessThan(simd_length(state.state.position - truth.position), 0.005)
        XCTAssertLessThan(simd_length(state.state.velocity - truth.velocity), 0.02)
        XCTAssertLessThan(state.rmsPx, 0.01, "noiseless data should fit almost exactly")
    }

    func testCleanFlightCrossesThePlaneWhereTruthSays() throws {
        let flight = try Track(start: SIMD3(0.7, -0.45, 5.2), velocity: SIMD3(-2.1, 1.6, -9.5))
        let crossing = try XCTUnwrap(flight.planeCrossing, "truth never crossed the plane")
        let predicted = try XCTUnwrap(flight.predictions.compactMap { prediction -> (SIMD3<Double>, Double, UInt64)? in
            guard let point = prediction.intercept, let time = prediction.interceptTimeS else { return nil }
            return (point, time, prediction.tNs)
        }.last, "no predicted crossing")

        let lateral = simd_length(SIMD3(predicted.0.x, predicted.0.y, 0) - SIMD3(crossing.point.x, crossing.point.y, 0))
        XCTAssertLessThan(lateral, 0.005)
        XCTAssertEqual(predicted.1, flight.timeToCrossing(from: predicted.2), accuracy: 0.005)
    }

    func testHalfPixelNoiseStillLandsOnThePlane() throws {
        let flight = try Track(
            start: SIMD3(0.7, -0.45, 5.2),
            velocity: SIMD3(-2.1, 1.6, -9.5),
            centreNoisePx: 0.5,
            radiusNoisePx: 0.6
        )
        let crossing = try XCTUnwrap(flight.planeCrossing)
        let predicted = try XCTUnwrap(flight.predictions.compactMap { prediction -> (SIMD3<Double>, Double, UInt64, Double)? in
            guard let point = prediction.intercept, let time = prediction.interceptTimeS else { return nil }
            return (point, time, prediction.tNs, prediction.state.speed)
        }.last, "no predicted crossing with realistic noise")

        let lateral = simd_length(SIMD3(predicted.0.x, predicted.0.y, 0) - SIMD3(crossing.point.x, crossing.point.y, 0))
        let timeError = abs(predicted.1 - flight.timeToCrossing(from: predicted.2))

        // Measured on this flight: 3-30 mm and a few milliseconds. These bounds
        // leave room for a different noise seed but would still catch the
        // metres-off prediction a 42 ms baseline produced.
        XCTAssertLessThan(lateral, 0.06, "intercept point drifted \(Int(lateral * 1000)) mm")
        XCTAssertLessThan(timeError, 0.02, "intercept time drifted \(Int(timeError * 1000)) ms")
        XCTAssertGreaterThan(predicted.3, 8, "speed should still be about 10 m/s")
    }

    func testStaticDecoyDoesNotStealTheTrack() throws {
        // The decoy is brighter and never moves; the ball is dimmer and flies.
        // Without candidate association the track hops between them every frame
        // and no fit ever survives.
        let flight = try Track(
            start: SIMD3(0.7, -0.45, 5.2),
            velocity: SIMD3(-2.1, 1.6, -9.5),
            centreNoisePx: 0.5,
            radiusNoisePx: 0.6,
            decoy: true
        )
        XCTAssertGreaterThan(flight.fitCount, 0, "no fit at all with a decoy present")
        let crossing = try XCTUnwrap(flight.planeCrossing)
        let predicted = try XCTUnwrap(flight.predictions.compactMap { prediction -> (SIMD3<Double>, Double, UInt64)? in
            guard let point = prediction.intercept, let time = prediction.interceptTimeS else { return nil }
            return (point, time, prediction.tNs)
        }.last, "no predicted crossing with a decoy present")
        let lateral = simd_length(SIMD3(predicted.0.x, predicted.0.y, 0) - SIMD3(crossing.point.x, crossing.point.y, 0))
        XCTAssertLessThan(lateral, 0.06, "intercept drifted to the decoy: \(Int(lateral * 1000)) mm")
    }

    func testStationaryBallIsNeverPredicted() {
        let tracker = FlightTracker()
        let camera = CameraModel(width: 1920, height: 1080, horizontalFOVDeg: 67)
        let model = FlightModel(gravity: gravity)
        var prediction: FlightPrediction?
        for index in 0..<240 {
            let sample = FlightSample(
                tNs: 1_000_000_000 + UInt64(index) * 4_166_666,
                u: 980, v: 520, radius: 18, confidence: 0.9
            )
            if let result = tracker.add(sample, camera: camera, model: model) {
                prediction = result
            }
        }
        XCTAssertNil(prediction, "a ball on a string is not a flight")
        XCTAssertEqual(tracker.fitCount, 0)
        XCTAssertGreaterThan(tracker.rejectedFitCount, 0)
    }

    func testShortBaselineRefusesToPredict() {
        // 33 ms of flight: velocity is not observable at that baseline, so the
        // tracker must stay silent rather than extrapolate confidently.
        let tracker = FlightTracker()
        let camera = CameraModel(width: 1920, height: 1080, horizontalFOVDeg: 67)
        let model = FlightModel(gravity: gravity)
        var predictions: [FlightPrediction] = []
        for index in 0..<8 {
            let depth = 4.0 - Double(index) * 0.03
            let sample = FlightSample(
                tNs: 9_000_000_000 + UInt64(index) * 4_166_666,
                u: 960 + Double(index) * 2, v: 540, radius: camera.fx * ballRadius / depth,
                confidence: 0.9
            )
            if let prediction = tracker.add(sample, camera: camera, model: model) {
                predictions.append(prediction)
            }
        }
        XCTAssertTrue(predictions.isEmpty)
        XCTAssertEqual(tracker.fitCount, 0)
    }

    func testGapEndsTheTrack() {
        let tracker = FlightTracker()
        let camera = CameraModel(width: 1920, height: 1080, horizontalFOVDeg: 67)
        let model = FlightModel(gravity: gravity)
        _ = tracker.add(FlightSample(tNs: 1_000_000_000, u: 900, v: 500, radius: 20, confidence: 0.9),
                        camera: camera, model: model)
        XCTAssertEqual(tracker.sampleCount, 1)
        _ = tracker.add(FlightSample(tNs: 1_500_000_000, u: 900, v: 500, radius: 20, confidence: 0.9),
                        camera: camera, model: model)
        XCTAssertEqual(tracker.sampleCount, 1, "a 0.5 s gap starts a new track")
    }

    // MARK: - Packets

    func testFlightStatePacketKeepsTheFixedLayout() throws {
        let packet = ObservationPacket.flightState(
            sequence: 7, tCaptureNs: 123_456_789,
            x: 0.25, y: -0.5, z: 3.75, rmsPx: 0.8,
            width: 1920, height: 1080
        )
        XCTAssertEqual(packet.encode().count, 40)
        let decoded = try XCTUnwrap(ObservationPacket(decoding: packet.encode()))
        XCTAssertEqual(decoded.kind, .state)
        XCTAssertEqual(decoded.sequence, 7)
        XCTAssertEqual(decoded.tCaptureNs, 123_456_789)
        XCTAssertEqual(Double(decoded.u), 0.25, accuracy: 1e-6)
        XCTAssertEqual(Double(decoded.v), -0.5, accuracy: 1e-6)
        XCTAssertEqual(Double(decoded.radius), 3.75, accuracy: 1e-6)
        XCTAssertEqual(Double(decoded.confidence), 0.8, accuracy: 1e-6)
        XCTAssertEqual(decoded.width, 1920)
    }

    func testInterceptPacketCarriesTimeToPlane() throws {
        let packet = ObservationPacket.intercept(
            sequence: 8, tCaptureNs: 42,
            x: 0.1, y: 0.2, z: 1.0, timeToPlaneS: 0.185,
            width: 1920, height: 1080
        )
        let decoded = try XCTUnwrap(ObservationPacket(decoding: packet.encode()))
        XCTAssertEqual(decoded.kind, .intercept)
        XCTAssertEqual(Double(decoded.radius), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Double(decoded.confidence), 0.185, accuracy: 1e-6)
    }

    // MARK: - A synthetic flight with known truth

    private struct TrackedFlight {
        let predictions: [FlightPrediction]
        let states: [SIMD3<Double>]
        let velocities: [SIMD3<Double>]
        let timesNs: [UInt64]
        let planeCrossing: (point: SIMD3<Double>, timeS: Double)?
        let fitCount: Int
        let rejectedFits: Int

        func truth(tNs: UInt64) -> (position: SIMD3<Double>, velocity: SIMD3<Double>) {
            let index = timesNs.enumerated().min { lhs, rhs in
                abs(Double(lhs.element &- tNs)) < abs(Double(rhs.element &- tNs))
            }?.offset ?? 0
            return (states[index], velocities[index])
        }

        /// Seconds from `tNs` until the truth crosses the plane.
        func timeToCrossing(from tNs: UInt64) -> Double {
            guard let crossing = planeCrossing else { return .nan }
            return crossing.timeS - Double(tNs) / 1e9
        }
    }

    private func Track(
        start: SIMD3<Double>,
        velocity: SIMD3<Double>,
        centreNoisePx: Double = 0,
        radiusNoisePx: Double = 0,
        decoy: Bool = false
    ) throws -> TrackedFlight {
        let camera = CameraModel(width: 1920, height: 1080, horizontalFOVDeg: 67)
        let model = FlightModel(gravity: gravity)

        var states: [SIMD3<Double>] = []
        var velocities: [SIMD3<Double>] = []
        var times: [UInt64] = []
        var position = start
        var speed = velocity
        var crossing: (point: SIMD3<Double>, timeS: Double)?
        let t0: UInt64 = 5_000_000_000
        let framePeriod = 1.0 / 240.0

        for frame in 0..<216 { // 0.9 s of flight
            let frameTimeS = Double(t0) / 1e9 + Double(frame) * framePeriod
            states.append(position)
            velocities.append(speed)
            times.append(t0 + UInt64(Double(frame) * (1e9 * framePeriod)))

            var remaining = framePeriod
            var elapsed = 0.0
            var previous = position
            while remaining > 1e-12 {
                let step = min(0.0005, remaining)
                let next = model.step(position: position, velocity: speed, dt: step)
                if crossing == nil, previous.z > 1.0, next.position.z <= 1.0 {
                    let fraction = (previous.z - 1.0) / (previous.z - next.position.z)
                    crossing = (
                        previous + fraction * (next.position - previous),
                        frameTimeS + elapsed + fraction * step
                    )
                }
                previous = next.position
                position = next.position
                speed = next.velocity
                elapsed += step
                remaining -= step
            }
        }

        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        func gauss(_ sd: Double) -> Double {
            guard sd > 0 else { return 0 }
            var total = 0.0
            for _ in 0..<4 {
                rng ^= rng << 13
                rng ^= rng >> 7
                rng ^= rng << 17
                total += Double(rng & 0xFFFFFF) / Double(0xFFFFFF) - 0.5
            }
            return total * sd * 2.0
        }

        let tracker = FlightTracker()
        var predictions: [FlightPrediction] = []
        for index in 0..<states.count {
            let point = states[index]
            guard let projected = camera.project(point, ballRadiusM: ballRadius),
                  projected.u > 0, projected.u < 1920,
                  projected.v > 0, projected.v < 1080
            else { continue }
            let sample = FlightSample(
                tNs: times[index],
                u: projected.u + gauss(centreNoisePx),
                v: projected.v + gauss(centreNoisePx),
                radius: projected.r + gauss(radiusNoisePx),
                confidence: 0.9
            )
            let candidates: [FlightSample]
            if decoy {
                // A small, static, brighter yellow region elsewhere in the frame:
                // exactly what the real scene had in the corner.
                candidates = [
                    sample,
                    FlightSample(
                        tNs: times[index],
                        u: 152 + Double(index % 3) * 0.4,
                        v: 952, radius: 4.6, confidence: 0.95
                    ),
                ]
            } else {
                candidates = [sample]
            }
            if let prediction = tracker.add(candidates, camera: camera, model: model) {
                predictions.append(prediction)
            }
        }
        return TrackedFlight(
            predictions: predictions,
            states: states,
            velocities: velocities,
            timesNs: times,
            planeCrossing: crossing,
            fitCount: tracker.fitCount,
            rejectedFits: tracker.rejectedFitCount
        )
    }
}
