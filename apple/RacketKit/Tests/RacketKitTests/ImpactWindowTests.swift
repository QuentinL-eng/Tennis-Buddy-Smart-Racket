import XCTest
import simd
@testable import RacketKit

/// Impact mode (firmware 1.5+): decoding the racket's hit, window and pose messages, assembling windows, and checking
/// a window gives the same shot as the full stream it was cut from.
final class ImpactWindowTests: XCTestCase {
    private func le16(_ v: Int) -> [UInt8] {
        let u = UInt16(truncatingIfNeeded: v)
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    }

    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

    private func quatBytes(_ q: simd_quatf) -> [UInt8] {
        [q.real, q.imag.x, q.imag.y, q.imag.z].flatMap { le16(Int(($0 * 16384).rounded())) }
    }

    private func sampleBytes(_ s: RacketProtocol.RawSample) -> [UInt8] {
        [s.ax, s.ay, s.az, s.gx, s.gy, s.gz, s.hx, s.hy, s.hz].flatMap { le16(Int($0)) }
    }

    private func chunk(seq: UInt16, index: Int, total: Int = 56, q0: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                       t0: UInt32, samples: [RacketProtocol.RawSample]) -> RacketProtocol.WindowChunk {
        var b = le16(Int(seq)) + [UInt8(index), UInt8(total)] + le16(384) + quatBytes(q0) + le32(t0)
        b += [UInt8(samples.count), RacketProtocol.flagGyro4000]
        b += samples.flatMap(sampleBytes)
        XCTAssertEqual(b.count, 20 + samples.count * 18)
        return RacketProtocol.decodeWindowChunk(Data(b))!
    }

    private func raw(_ k: Int) -> RacketProtocol.RawSample {
        RacketProtocol.RawSample(ax: Int16(k), ay: 0, az: 2048, gx: 82, gy: 0, gz: 0, hx: 0, hy: 0, hz: 160)
    }

    func testDecodesHit() throws {
        let q = simd_quatf(angle: 0.5, axis: simd_normalize(SIMD3(1, 2, 3)))
        let bytes = le16(7) + le32(123_456_789) + [2, 25] + le16(1800) + quatBytes(q)
        let hit = try XCTUnwrap(RacketProtocol.decodeHit(Data(bytes)))
        XCTAssertEqual(hit.seq, 7)
        XCTAssertEqual(hit.tMicros, 123_456_789)
        XCTAssertEqual(hit.source, .mic)
        XCTAssertEqual(hit.jumpG, 25)
        XCTAssertEqual(hit.swingDps, 1800)
        XCTAssertEqual(simd_dot(hit.orientation.vector, q.vector), 1, accuracy: 1e-3)
    }

    func testDecodesPose() throws {
        let q = simd_quatf(angle: -1.2, axis: SIMD3(0, 1, 0))
        let bytes = quatBytes(q) + le16(950) + [42, RacketProtocol.flagMotionOK | RacketProtocol.flagGyro4000]
        let pose = try XCTUnwrap(RacketProtocol.decodePose(Data(bytes)))
        XCTAssertEqual(simd_dot(pose.orientation.vector, q.vector), 1, accuracy: 1e-3)
        XCTAssertEqual(pose.gyroDps, 950)
        XCTAssertEqual(pose.highG, 42)
        XCTAssertNotEqual(pose.flags & RacketProtocol.flagGyro4000, 0)
    }

    func testStatusReportsImpactMode() throws {
        let status = try XCTUnwrap(RacketProtocol.decodeStatus(Data([0, 0, 1, 5, 0x17, 1, 0, 0])))
        XCTAssertTrue(status.impactMode)
        XCTAssertEqual(status.firmwareVersion, "1.5")
    }

    func testAssemblesChunksIntoOneWindow() throws {
        var assembler = ImpactWindowAssembler()
        var window: ImpactWindow?
        for i in 0..<56 {
            let c = chunk(seq: 3, index: i, t0: 1_000_000 + UInt32(i) * 8000, samples: (0..<8).map { raw(i * 8 + $0) })
            let w = assembler.add(c, h3lisRange: 1) { Double($0) / 1e6 }
            if i < 55 { XCTAssertNil(w) } else { window = w }
        }
        let w = try XCTUnwrap(window)
        XCTAssertEqual(w.seq, 3)
        XCTAssertEqual(w.impactIndex, RacketProtocol.windowPre)
        XCTAssertEqual(w.samples.count, RacketProtocol.windowSamples)
        XCTAssertEqual(w.samples[447].accel.x * 2048, 447, accuracy: 1e-3)
        XCTAssertEqual(w.samples[447].time - w.samples[0].time, 0.447, accuracy: 1e-9)
        // Window gyro is at 8.2 LSB/dps: 82 counts = 10 dps.
        XCTAssertEqual(w.samples[0].gyro.x, 10 * .pi / 180, accuracy: 1e-5)
        XCTAssertEqual(assembler.incomplete, 0)
    }

    func testWindowWithAMissingChunkIsDropped() {
        var assembler = ImpactWindowAssembler()
        for i in 0..<56 where i != 10 {
            XCTAssertNil(assembler.add(chunk(seq: 1, index: i, t0: UInt32(i) * 8000, samples: (0..<8).map(raw)),
                                       h3lisRange: 1) { Double($0) / 1e6 })
        }
        var completed: ImpactWindow?
        for i in 0..<56 {
            completed = assembler.add(chunk(seq: 2, index: i, t0: UInt32(i) * 8000, samples: (0..<8).map(raw)),
                                      h3lisRange: 1) { Double($0) / 1e6 }
        }
        XCTAssertEqual(assembler.incomplete, 1)
        XCTAssertEqual(completed?.seq, 2)
    }

    /// Cuts a window out of a simulated stream the way the racket does, and checks the engine's shot from that window
    /// matches its shot from the full stream.
    func testWindowGivesTheSameShotAsTheFullStream() throws {
        let sim = SimulatedRacket()
        sim.shotInterval = 2.5
        let streamEngine = RacketEngine()
        let lock = NSLock()
        var recorded: [IMUSample] = []
        streamEngine.onRaw = { batch in lock.withLock { recorded += batch } }
        var streamShot: ShotMetrics?
        let gotStream = expectation(description: "stream shot")
        streamEngine.onShot = { shot in
            guard streamShot == nil else { return }
            streamShot = shot
            gotStream.fulfill()
        }
        streamEngine.attach(sim)
        sim.start()
        wait(for: [gotStream], timeout: 15)
        sim.stop()
        let samples = lock.withLock { recorded }

        // The racket's cut: impact on the first sample of the largest 3 ms high-g jump.
        func jump(_ k: Int) -> Float { simd_length(samples[k].highG - samples[k - 3].highG) }
        let best = (3..<samples.count).max { jump($0) < jump($1) }!
        let impact = best - 2
        let start = impact - RacketProtocol.windowPre
        XCTAssertGreaterThanOrEqual(start, 0)
        XCTAssertLessThanOrEqual(impact + RacketProtocol.windowPost, samples.count)
        // The racket's orientation filter at the window start (the simulator is already in racket axes).
        var filter = MahonyFilter()
        for k in 0..<start {
            let dt = Float(k == 0 ? 0.001 : min(max(samples[k].time - samples[k - 1].time, 0.0002), 0.02))
            filter.update(gyro: samples[k].gyro, accel: samples[k].accel, dt: dt)
        }
        let window = ImpactWindow(seq: 0, impactIndex: RacketProtocol.windowPre, startOrientation: filter.q,
                                  samples: Array(samples[start..<(start + RacketProtocol.windowSamples)]))

        let source = FakeImpactSource()
        let windowEngine = RacketEngine()
        var windowShot: ShotMetrics?
        let gotWindow = expectation(description: "window shot")
        windowEngine.onShot = { shot in
            windowShot = shot
            gotWindow.fulfill()
        }
        windowEngine.attach(source)
        source.onImpactWindow?(window)
        wait(for: [gotWindow], timeout: 5)

        let a = try XCTUnwrap(streamShot), b = try XCTUnwrap(windowShot)
        XCTAssertEqual(b.type, a.type)
        XCTAssertEqual(b.swingSpeedKmh, a.swingSpeedKmh, accuracy: max(1, a.swingSpeedKmh * 0.02))
        XCTAssertEqual(b.ballSpeedKmh, a.ballSpeedKmh, accuracy: max(1, a.ballSpeedKmh * 0.03))
        XCTAssertEqual(b.impactXcm, a.impactXcm, accuracy: 0.5)
        XCTAssertEqual(b.impactYcm, a.impactYcm, accuracy: 0.5)
        XCTAssertEqual(b.faceAngleDeg, a.faceAngleDeg, accuracy: 3)
        XCTAssertEqual(b.swingPathDeg, a.swingPathDeg, accuracy: 3)
    }
}

private final class FakeImpactSource: SampleSource, ImpactSource {
    var onSamples: (([IMUSample]) -> Void)?
    var onImpactWindow: ((ImpactWindow) -> Void)?
    var onPose: ((RacketProtocol.Pose) -> Void)?
    var nativeCalibration: Calibration? { .identity }
    func start() {}
    func stop() {}
}
