import XCTest
import simd
@testable import RacketKit

/// The racket computes each shot itself (firmware/src/shot.cpp, firmware 1.6+). This builds that C++ on the Mac and
/// checks it against RacketEngine's window path on the same wire bytes: simulated swings, cut into windows the way
/// the racket cuts them, seen through a non-trivial calibration.
final class ShotParityTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func le16(_ v: Int) -> [UInt8] {
        let u = UInt16(truncatingIfNeeded: v)
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    }

    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

    private func i16(_ v: Float) -> Int { Int(max(-32768, min(32767, v.rounded()))) }

    /// A racket-frame sample as the sensor would report it, in wire units (gyro at 8.2 LSB/dps, high-g at ±400 g).
    private func wire(_ s: IMUSample, _ cal: Calibration) -> [UInt8] {
        let toSensor = cal.mpuToRacket.transpose
        let a = toSensor * s.accel / cal.accelScale
        let g = toSensor * s.gyro + cal.gyroBias
        let h = toSensor * s.highG + cal.h3lisBias
        let dps: Float = 180 / .pi
        let hg = [h.x, h.y, h.z].map { Int(max(-2048, min(2047, ($0 / 0.195).rounded()))) * 16 }
        return [a.x, a.y, a.z].flatMap { le16(i16($0 * 2048)) }
            + [g.x, g.y, g.z].flatMap { le16(i16($0 * dps * 8.2)) } + hg.flatMap { le16($0) }
    }

    private func calibration() -> Calibration {
        var cal = Calibration.default
        // Default axes plus a few degrees of mounting tilt, so no axis maps straight onto another.
        let tilt = simd_float3x3(simd_quatf(angle: 0.12, axis: simd_normalize(SIMD3<Float>(1, 2, 0.5))))
        cal.mpuToRacket = cal.mpuToRacket * tilt
        cal.h3lisToRacket = cal.mpuToRacket
        cal.gyroBias = SIMD3(0.01, -0.02, 0.005)
        cal.h3lisBias = SIMD3(0.3, -0.2, 0.1)
        cal.accelScale = 1.02
        cal.isCalibrated = true
        return cal
    }

    /// Windows cut like impact.cpp: the largest 3 ms high-g jump, 384 samples before, 64 after. Each is its 56 chunks.
    private func windows(_ samples: [IMUSample], _ cal: Calibration) -> [[Data]] {
        func jump(_ k: Int) -> Float { simd_length(samples[k].highG - samples[k - 3].highG) }
        var out: [[Data]] = []
        var k = 3, seq = 0
        while k < samples.count - 20 {
            guard jump(k) > 10 else { k += 1; continue }
            let best = (k..<(k + 12)).max { jump($0) < jump($1) }!
            let impact = best - 2, start = impact - RacketProtocol.windowPre
            k = best + 600
            guard start > 0, impact + RacketProtocol.windowPost <= samples.count else { continue }
            // The racket's own orientation filter at the window start, in sensor axes.
            var f = MahonyFilter()
            let sensor = cal.mpuToRacket.transpose
            for j in 0..<start {
                let dt = Float(j == 0 ? 0.001 : samples[j].time - samples[j - 1].time)
                f.update(gyro: sensor * samples[j].gyro, accel: sensor * samples[j].accel, dt: dt)
            }
            let q0 = [f.q.real, f.q.imag.x, f.q.imag.y, f.q.imag.z].flatMap { le16(i16($0 * 16384)) }
            var chunks: [Data] = []
            for c in 0..<RacketProtocol.windowSamples / 8 {
                let first = start + c * 8
                // Racket micros: 1 ms per sample plus a little jitter at each chunk.
                let t0 = UInt32(5_000_000 + first * 1000 + (c % 3) * 7)
                var b = le16(seq) + [UInt8(c), 56] + le16(RacketProtocol.windowPre) + q0 + le32(t0)
                b += [8, RacketProtocol.flagGyro4000]
                for j in first..<(first + 8) { b += wire(samples[j], cal) }
                chunks.append(Data(b))
            }
            out.append(chunks)
            seq += 1
        }
        return out
    }

    private func runCPP(_ input: Data) throws -> [String] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shot_parity-\(UUID().uuidString)")
        let fw = Self.repo.appendingPathComponent("firmware")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.arguments = ["clang++", "-O2", "-std=c++17", "-I", fw.appendingPathComponent("include").path,
                           "-I", fw.appendingPathComponent("src").path, "-o", tmp.path,
                           fw.appendingPathComponent("tools/shot_parity/shot_parity.cpp").path,
                           fw.appendingPathComponent("src/shot.cpp").path]
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else { throw XCTSkip("no host C++ compiler") }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let run = Process()
        run.executableURL = tmp
        let stdin = Pipe(), stdout = Pipe()
        run.standardInput = stdin
        run.standardOutput = stdout
        try run.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()
        XCTAssertEqual(run.terminationStatus, 0)
        return String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func check(profile: RacketProfile) throws {
        let saved = IMUSample.gyroSaturation
        IMUSample.gyroSaturation = 3990 * .pi / 180
        defer { IMUSample.gyroSaturation = saved }
        let cal = calibration()
        let model = ImpactModel()
        let wins = windows(SimulatedRacket().generate(shots: 40), cal)
        XCTAssertGreaterThan(wins.count, 30)

        var input = RacketProtocol.shotConfigPayload(gen: 7, calibration: cal, profile: profile, model: model)
        input.append(1)   // gyro4000
        input.append(contentsOf: le32(UInt32(wins.count)))
        for w in wins { for c in w { input.append(c) } }
        let lines = try runCPP(input)
        XCTAssertEqual(lines.count, wins.count)

        let analyzer = ShotAnalyzer(profile: profile, model: model)
        let types: [ShotType: Int] = [.forehand: 0, .backhand: 1, .serve: 2, .volley: 3]
        let spins: [SpinType: Int] = [.topspin: 0, .flat: 1, .slice: 2]
        var seen = Set<ShotType>()
        for (w, line) in zip(wins, lines) {
            var assembler = ImpactWindowAssembler()
            var window: ImpactWindow?
            for c in w {
                window = assembler.add(RacketProtocol.decodeWindowChunk(c)!, h3lisRange: 3) { Double($0) / 1e6 }
            }
            let shot = try XCTUnwrap(RacketEngine.shot(window: try XCTUnwrap(window), calibration: cal,
                                                       analyzer: analyzer, calibrationMode: false, date: Date()))
            seen.insert(shot.type)
            let f = line.split(separator: " ").map { Double($0)! }
            XCTAssertEqual(f.count, 18, line)
            XCTAssertEqual(Int(f[0]), types[shot.type], "type")
            XCTAssertEqual(Int(f[1]), spins[shot.spin], "spin")
            XCTAssertEqual(Int(f[2]) & 1 != 0, shot.gyroSaturated, "saturated")
            let swift: [Double] = [shot.swingSpeedKmh, shot.ballSpeedKmh, shot.spinRPM, shot.faceAngleDeg,
                                   shot.swingPathDeg, shot.impactXcm, shot.impactYcm, shot.peakG,
                                   Double(shot.features.rollRatio), Double(shot.features.ringNorm),
                                   Double(shot.features.jolt), Double(shot.features.impulse),
                                   Double(shot.features.spinAxisY ?? 0), Double(shot.features.verticalSpin ?? 0),
                                   Double(shot.features.swingDeg ?? 0)]
            let names = ["swing", "ball", "spin", "face", "path", "x", "y", "peakG", "roll", "ring", "jolt", "impulse",
                         "spinAxisY", "verticalSpin", "swingDeg"]
            for (k, v) in swift.enumerated() {
                // Float rounding only: the two run the same steps (simd may fuse multiply-adds).
                XCTAssertEqual(f[3 + k], v, accuracy: 1e-3 * max(1, abs(v)), "\(names[k]) in \(line)")
            }
        }
        XCTAssertGreaterThanOrEqual(seen.count, 3, "the simulator should produce several shot types")
    }

    func testRacketShotMatchesTheAppWithHandedness() throws {
        try check(profile: RacketProfile())
    }

    func testRacketShotMatchesTheAppWithTaughtForehand() throws {
        var profile = RacketProfile()
        profile.forehandBodySign = -1
        profile.rightHanded = false
        try check(profile: profile)
    }

    func testConfigPayloadSize() {
        let d = RacketProtocol.shotConfigPayload(gen: 1, calibration: .default, profile: RacketProfile(),
                                                 model: ImpactModel())
        XCTAssertEqual(d.count, 1 + 36 * 4 + 1)   // TB_SHOT_CONFIG_PAYLOAD
    }
}
