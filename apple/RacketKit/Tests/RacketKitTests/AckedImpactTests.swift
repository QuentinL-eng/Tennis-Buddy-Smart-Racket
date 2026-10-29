import XCTest
import simd
@testable import RacketKit

/// Acked impact mode (firmware 1.6+): the racket's shot summaries, windows with boot numbers that are acked and
/// resent, and the engine taking each shot once, from the summary when it can.
final class AckedImpactTests: XCTestCase {
    private func le16(_ v: Int) -> [UInt8] {
        let u = UInt16(truncatingIfNeeded: v)
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    }

    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    private func f32(_ v: Float) -> [UInt8] { le32(v.bitPattern) }

    /// A TBWindowChunkAcked as firmware/src/main.cpp sends it.
    private func chunk(boot: UInt16, seq: UInt16, index: Int, backlog: Bool = false) -> RacketProtocol.WindowChunk {
        var b = le16(Int(seq)) + [UInt8(index), 56] + le16(384) + le16(16384) + le16(0) + le16(0) + le16(0)
        b += le32(UInt32(1_000_000 + index * 8000))
        b += [8, RacketProtocol.flagGyro4000 | (backlog ? RacketProtocol.flagBacklog : 0)] + le16(Int(boot))
        for k in 0..<8 { b += le16(index * 8 + k) + le16(0) + le16(2048) + [UInt8](repeating: 0, count: 12) }
        XCTAssertEqual(b.count, 166)
        return RacketProtocol.decodeWindowChunk(Data(b))!
    }

    private func summaryBytes(boot: UInt16, seq: UInt16, gen: UInt8, type: UInt8 = 1, age: UInt32 = 250,
                              unixMs: UInt64 = 0) -> Data {
        var b = le16(Int(seq)) + le16(Int(boot)) + [gen, type, 2, 1 | 2] + le32(age)
        b += (0..<8).map { UInt8((unixMs >> (8 * UInt64($0))) & 0xFF) }
        b += (0..<15).flatMap { f32(Float($0) + 0.5) }
        XCTAssertEqual(b.count, 80)
        return Data(b)
    }

    func testDecodesSummary() throws {
        let s = try XCTUnwrap(RacketProtocol.decodeShotSummary(summaryBytes(boot: 9, seq: 4, gen: 3)))
        XCTAssertEqual(s.boot, 9)
        XCTAssertEqual(s.seq, 4)
        XCTAssertEqual(s.gen, 3)
        XCTAssertEqual(s.type, .backhand)
        XCTAssertEqual(s.spin, .slice)
        XCTAssertTrue(s.gyroSaturated)
        XCTAssertTrue(s.backlog)
        XCTAssertEqual(s.swingKmh, 0.5)
        XCTAssertEqual(s.swingDeg, 14.5)
        XCTAssertNil(s.unixMs)
        let now = Date()
        XCTAssertEqual(s.hitDate(receivedAt: now).timeIntervalSince(now), -0.25, accuracy: 1e-6)
        let m = s.metrics(receivedAt: now)
        XCTAssertEqual(m.type, .backhand)
        XCTAssertEqual(m.features.verticalSpin, 13.5)
        // Hit before a reboot, but the racket knew the time.
        let earlier = try XCTUnwrap(RacketProtocol.decodeShotSummary(summaryBytes(boot: 9, seq: 4, gen: 3,
                                                                                 age: .max, unixMs: 1_700_000_000_000)))
        XCTAssertNil(earlier.ageMs)
        XCTAssertEqual(earlier.hitDate(receivedAt: now).timeIntervalSince1970, 1_700_000_000, accuracy: 1e-3)
        XCTAssertNil(RacketProtocol.decodeShotSummary(summaryBytes(boot: 1, seq: 1, gen: 1, type: 9)))
    }

    func testAckedChunkCarriesBoot() {
        let c = chunk(boot: 0x1234, seq: 7, index: 3, backlog: true)
        XCTAssertEqual(c.boot, 0x1234)
        XCTAssertEqual(c.samples.count, 8)
        XCTAssertEqual(c.samples[1].ax, 25)   // samples start after the boot number
        XCTAssertNotEqual(c.flags & RacketProtocol.flagBacklog, 0)
    }

    func testCommandPayloads() {
        XCTAssertEqual([UInt8](RacketProtocol.windowAckPayload(boot: 0x0102, seq: 0x0304)), [0x14, 2, 1, 4, 3])
        XCTAssertEqual([UInt8](RacketProtocol.windowResendPayload(boot: 1, seq: 2, chunks: [5, 9])),
                       [0x15, 1, 0, 2, 0, 2, 5, 9])
        XCTAssertEqual(RacketProtocol.windowResendPayload(boot: 1, seq: 2, chunks: Array(0..<30)).last, 0)   // all
        XCTAssertEqual(RacketProtocol.setTimePayload(Date(timeIntervalSince1970: 1)).count, 9)
    }

    func testAssemblerInterleavesWindowsAndFillsGapsFromResends() {
        var a = ImpactWindowAssembler()
        let time: (UInt32) -> Double = { Double($0) / 1e6 }
        // Window 1 loses chunk 10; window 2 arrives whole meanwhile.
        for i in 0..<56 where i != 10 { XCTAssertNil(a.add(chunk(boot: 5, seq: 1, index: i), h3lisRange: 3, now: 0, time: time)) }
        var done: ImpactWindow?
        for i in 0..<56 { done = a.add(chunk(boot: 5, seq: 2, index: i), h3lisRange: 3, now: 0.5, time: time) }
        XCTAssertEqual(done?.seq, 2)
        XCTAssertEqual(done?.boot, 5)
        XCTAssertEqual(a.incomplete, 0)   // window 1 is still waiting, not abandoned
        XCTAssertTrue(a.missing(now: 1.0, quietFor: 1.5).isEmpty)
        let gaps = a.missing(now: 2.0, quietFor: 1.5)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.key, WindowKey(boot: 5, seq: 1))
        XCTAssertEqual(gaps.first?.chunks, [10])
        XCTAssertTrue(a.missing(now: 2.5, quietFor: 1.5).isEmpty)   // just asked
        let filled = a.add(chunk(boot: 5, seq: 1, index: 10, backlog: true), h3lisRange: 3, now: 3, time: time)
        XCTAssertEqual(filled?.seq, 1)
        XCTAssertEqual(filled?.samples.count, 448)
        XCTAssertEqual(filled?.backlog, true)
        // Same seq after a reboot is a different window.
        XCTAssertNil(a.add(chunk(boot: 6, seq: 1, index: 0), h3lisRange: 3, now: 4, time: time))
        XCTAssertEqual(a.missing(now: 9, quietFor: 1.5).first?.key, WindowKey(boot: 6, seq: 1))
    }

    // MARK: Engine

    private final class FakeRacket: SampleSource, ImpactSource, ShotSummarySource {
        var onSamples: (([IMUSample]) -> Void)?
        var nativeCalibration: Calibration? { nil }
        var onImpactWindow: ((ImpactWindow) -> Void)?
        var onPose: ((RacketProtocol.Pose) -> Void)?
        var onShotSummary: ((RacketProtocol.ShotSummary) -> Void)?
        let lock = NSLock()
        var configs: [Data] = []
        func setShotConfig(_ payload: Data) { lock.withLock { configs.append(payload) } }
        func start() {}
        func stop() {}
    }

    private func window(boot: UInt16, seq: UInt16) -> ImpactWindow {
        let samples = (0..<448).map { k in
            IMUSample(time: Double(k) * 0.001, accel: SIMD3(0, 0, 1), gyro: SIMD3(0, k < 384 ? 15 : 3, 0),
                      highG: SIMD3(0, 0, k >= 384 && k < 390 ? 40 : 1))
        }
        return ImpactWindow(seq: seq, impactIndex: 384, startOrientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                            samples: samples, boot: boot)
    }

    private func settle(_ engine: RacketEngine) {
        // The engine works on its own queue and reports on the main queue.
        let e = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { DispatchQueue.main.async { e.fulfill() } }
        wait(for: [e], timeout: 2)
    }

    func testEngineTakesEachShotOnceFromTheSummary() throws {
        let racket = FakeRacket()
        let engine = RacketEngine()
        var shots: [ShotMetrics] = []
        engine.onShot = { shots.append($0) }
        engine.attach(racket)
        settle(engine)
        let gen = try XCTUnwrap(racket.lock.withLock { racket.configs.last?.first })
        XCTAssertEqual(racket.lock.withLock { racket.configs.last?.count }, 1 + 36 * 4 + 1)

        // Current config: the summary is the shot; its window only feeds the recorder.
        var raw = 0
        engine.onRaw = { _ in raw += 1 }
        racket.onShotSummary?(RacketProtocol.decodeShotSummary(summaryBytes(boot: 3, seq: 1, gen: gen))!)
        racket.onImpactWindow?(window(boot: 3, seq: 1))
        settle(engine)
        XCTAssertEqual(shots.count, 1)
        XCTAssertEqual(shots.first?.swingSpeedKmh, 0.5)
        XCTAssertEqual(raw, 1)

        // A summary from an older config (the profile changed since) is ignored and the window is analysed here.
        engine.profile.rightHanded.toggle()
        settle(engine)
        racket.onShotSummary?(RacketProtocol.decodeShotSummary(summaryBytes(boot: 3, seq: 2, gen: gen))!)
        racket.onImpactWindow?(window(boot: 3, seq: 2))
        settle(engine)
        XCTAssertEqual(shots.count, 2)
        XCTAssertNotEqual(shots.last?.swingSpeedKmh, 0.5)
        XCTAssertNotEqual(racket.lock.withLock { racket.configs.last?.first }, gen)
    }
}
