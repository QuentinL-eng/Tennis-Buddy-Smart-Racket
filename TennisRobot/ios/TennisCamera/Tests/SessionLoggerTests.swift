import XCTest
@testable import TennisCamera

/// The session files are a contract with `tools/phone_session.py`: little-endian, nanoseconds on the host clock.
final class SessionLoggerTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    private func finish(_ logger: SessionLogger, extra: [String: Any] = [:]) -> String {
        let done = expectation(description: "finish")
        var summary = ""
        logger.finish(extra: extra) { summary = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return summary
    }

    private func read(_ logger: SessionLogger, _ name: String) throws -> Data {
        try Data(contentsOf: logger.directory.appendingPathComponent(name))
    }

    private func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    private func u64(_ d: Data, _ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[o + $1]) << (8 * UInt64($1)) }
    }
    private func f32(_ d: Data, _ o: Int) -> Float {
        Float(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[o + $1]) << (8 * UInt32($1)) })
    }

    /// One IMU packet as the racket sends it: u16 seq, u32 t0_us, u8 count, u8 flags, 8 samples of 9 x i16.
    private func imuPacket(seq: UInt16, t0us: UInt32, accelX: Int16) -> Data {
        var p = Data()
        p.appendLE(seq)
        p.appendLE(t0us)
        p.append(8)
        p.append(0)
        for i in 0..<8 {
            p.appendLE(accelX &+ Int16(i))
            for _ in 0..<8 { p.appendLE(Int16(0)) }
        }
        return p
    }

    func testWritesAllFilesInTheDocumentedLayout() throws {
        let logger = try XCTUnwrap(SessionLogger(info: ["device": "test", "fps": 240], recordVideo: false))
        directories.append(logger.directory.deletingLastPathComponent())

        logger.logFrame(1_000_000_000)
        logger.logFrame(1_004_166_667)
        logger.logDetections(1_000_000_000, [
            BallDetection(u: 640.5, v: 360.25, radius: 12.5, confidence: 0.875, area: 300),
            BallDetection(u: 1.25, v: 1079.5, radius: 0.5, confidence: 0.125, area: 3),
        ])
        let imu = imuPacket(seq: 7, t0us: 123_456, accelX: 100)
        logger.logRacket(tNs: 2_000_000_000, kind: .imu, payload: imu)
        logger.logRacket(tNs: 2_100_000_000, kind: .status, payload: Data([1, 2, 3]))
        logger.mark("knock, one")

        let summary = finish(logger, extra: ["note": "hello"])
        XCTAssertTrue(summary.contains("2 frames, 2 detections, 2 racket records"), summary)

        let frames = try read(logger, "frames.bin")
        XCTAssertEqual(frames.count, 16)
        XCTAssertEqual(u64(frames, 0), 1_000_000_000)
        XCTAssertEqual(u64(frames, 8), 1_004_166_667)

        let det = try read(logger, "detections.bin")
        XCTAssertEqual(det.count, 48, "24 bytes per record")
        XCTAssertEqual(u64(det, 0), 1_000_000_000)
        XCTAssertEqual(f32(det, 8), 640.5)
        XCTAssertEqual(f32(det, 12), 360.25)
        XCTAssertEqual(f32(det, 16), 12.5)
        XCTAssertEqual(f32(det, 20), 0.875)
        XCTAssertEqual(u64(det, 24), 1_000_000_000)
        XCTAssertEqual(f32(det, 32), 1.25)
        XCTAssertEqual(f32(det, 44), 0.125)

        let rk = try read(logger, "racket.bin")
        XCTAssertEqual(rk.count, (11 + imu.count) + (11 + 3))
        XCTAssertEqual(u64(rk, 0), 2_000_000_000)
        XCTAssertEqual(rk[8], SessionLogger.RacketKind.imu.rawValue)
        XCTAssertEqual(Int(u16(rk, 9)), imu.count)
        XCTAssertEqual(rk.subdata(in: 11..<(11 + imu.count)), imu)
        let second = 11 + imu.count
        XCTAssertEqual(u64(rk, second), 2_100_000_000)
        XCTAssertEqual(rk[second + 8], SessionLogger.RacketKind.status.rawValue)
        XCTAssertEqual(Int(u16(rk, second + 9)), 3)
        XCTAssertEqual(Array(rk.suffix(3)), [1, 2, 3])

        let csv = try XCTUnwrap(String(data: try read(logger, "events.csv"), encoding: .utf8))
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "t_ns,label")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix(",knock; one"), "commas in labels become semicolons: \(lines[1])")
        XCTAssertNotNil(UInt64(lines[1].split(separator: ",")[0]))

        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: try read(logger, "meta.json")) as? [String: Any])
        XCTAssertEqual(meta["format_version"] as? Int, 1)
        XCTAssertEqual(meta["device"] as? String, "test")
        XCTAssertEqual(meta["note"] as? String, "hello")
        XCTAssertEqual(meta["frames"] as? Int, 2)
        XCTAssertEqual(meta["detections"] as? Int, 2)
        XCTAssertEqual(meta["racket_records"] as? Int, 2)
        XCTAssertEqual(meta["first_frame_ns"] as? UInt64, 1_000_000_000)
        XCTAssertEqual(meta["video"] as? Bool, false)
        XCTAssertEqual(meta["video_frames"] as? Int, 0)
        XCTAssertNotNil(meta["started_host_ns"])
        XCTAssertNotNil(meta["stopped_host_ns"])
    }

    func testFinishWithoutVideoStartedDoesNotCrash() throws {
        for wantsVideo in [false, true] {
            let logger = try XCTUnwrap(SessionLogger(info: [:], recordVideo: wantsVideo))
            directories.append(logger.directory.deletingLastPathComponent())
            _ = finish(logger)
            let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: try read(logger, "meta.json")) as? [String: Any])
            XCTAssertEqual(meta["video_frames"] as? Int, 0)
            XCTAssertNil(meta["video_error"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: logger.directory.appendingPathComponent("video.mov").path))
        }
    }

    /// With TEST_RUNNER_SESSION_EXPORT=<dir> set, also copies a short two-second session there so
    /// `tools/phone_session.py` can be run on a file set the app code really wrote.
    func testExportsFakeSessionForPython() throws {
        guard let export = ProcessInfo.processInfo.environment["SESSION_EXPORT"] else { throw XCTSkip("SESSION_EXPORT not set") }
        let logger = try XCTUnwrap(SessionLogger(info: ["device": "fake"], recordVideo: false))
        directories.append(logger.directory.deletingLastPathComponent())
        let base: UInt64 = 10_000_000_000
        for i in 0..<480 {
            logger.logFrame(base + UInt64(i) * 4_166_667)
            logger.logDetections(base + UInt64(i) * 4_166_667,
                                 [BallDetection(u: 100 + Float(i), v: 500, radius: 8, confidence: 0.9, area: 200)])
        }
        for k in 0..<250 {
            let tRacket = UInt32(k * 8000)
            let arrival = base + UInt64(tRacket) * 1000 + 5_000_000 + UInt64(k % 4) * 1_000_000
            logger.logRacket(tNs: arrival, kind: .imu, payload: imuPacket(seq: UInt16(k), t0us: tRacket, accelX: 2048))
        }
        _ = finish(logger)
        try? FileManager.default.removeItem(atPath: export)
        try FileManager.default.copyItem(at: logger.directory, to: URL(fileURLWithPath: export))
    }
}
