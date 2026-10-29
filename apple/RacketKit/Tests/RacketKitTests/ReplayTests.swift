import XCTest
import simd
@testable import RacketKit

/// Replays a TennisCamera session's racket.bin (u64 arrival ns, u8 kind, u16 length, payload) through the real
/// engine, the way RacketBLE feeds it. Runs only with REPLAY_DIRS=<session folder>[,<folder>...].
final class ReplayTests: XCTestCase {
    func testReplayRecordedSessions() throws {
        guard let dirs = ProcessInfo.processInfo.environment["REPLAY_DIRS"] else { throw XCTSkip("REPLAY_DIRS not set") }
        for dir in dirs.split(separator: ",").map(String.init) {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("racket.bin"))
            let engine = RacketEngine()
            if let sign = ProcessInfo.processInfo.environment["REPLAY_SIGN"].flatMap(Float.init) {
                var profile = RacketProfile(); profile.forehandBodySign = sign; engine.profile = profile
            }
            var shots: [(ShotMetrics, Double, Int)] = []   // shot, approximate impact time, packets lost in the 1 s before
            var lossTimes: [Double] = []
            var curT = 0.0
            let fill = ProcessInfo.processInfo.environment["REPLAY_FILL"] == "1"
            var prev: IMUSample?
            engine.onShot = { m in
                let t = curT - 0.15
                shots.append((m, t, lossTimes.filter { $0 > t - 1.0 && $0 <= t }.count))
            }
            var h3Range: UInt8 = 1
            var wraps = 0.0, lastMicros: UInt32 = 0
            var lastSeq: UInt16?, lost = 0, packets = 0
            var allSamples: [IMUSample] = []
            var pos = 0
            while pos + 11 <= data.count {
                let n = Int(data[pos + 9]) | Int(data[pos + 10]) << 8
                let kind = data[pos + 8]
                pos += 11
                guard pos + n <= data.count else { break }
                let payload = data.subdata(in: pos..<(pos + n))
                pos += n
                if kind == 2, payload.count >= 6 { h3Range = payload[5] }
                guard kind == 1, let packet = RacketProtocol.decodePacket(payload) else { continue }
                packets += 1
                if let last = lastSeq {
                    let gap = Int(packet.seq &- last) - 1
                    if gap > 0 && gap < 1000 { lost += gap }
                }
                var missing = 0
                if let last = lastSeq { let gap = Int(packet.seq &- last) - 1; if gap > 0 && gap < 1000 { missing = gap } }
                lastSeq = packet.seq
                if packet.t0Micros < lastMicros, lastMicros - packet.t0Micros > 1_000_000_000 { wraps += 4294.967296 }
                lastMicros = packet.t0Micros
                let t0 = Double(packet.t0Micros) / 1e6 + wraps
                let wide = packet.flags & RacketProtocol.flagGyro4000 != 0
                IMUSample.gyroSaturation = (wide ? 3990 : 1990) * .pi / 180
                let scale = wide ? RacketProtocol.mpuGyroLSBPerDps / 2 : RacketProtocol.mpuGyroLSBPerDps
                let samples = packet.samples.enumerated().map { k, raw in
                    RacketProtocol.convert(raw, time: t0 + Double(k) * 0.001, h3lisRange: h3Range, gyroLSBPerDps: scale)
                }
                if missing > 0 { lossTimes.append(t0) }
                if fill, missing > 0, let p = prev, let first = samples.first {
                    // Linear interpolation across the gap so the engine sees a continuous 1 kHz stream.
                    let n = Int((first.time - p.time) * 1000.0) - 1
                    if n > 0 && n < 400 {
                        var gapFill: [IMUSample] = []
                        for k in 1...n {
                            let f = Float(k) / Float(n + 1)
                            gapFill.append(IMUSample(time: p.time + Double(k) * 0.001,
                                                     accel: p.accel + (first.accel - p.accel) * f,
                                                     gyro: p.gyro + (first.gyro - p.gyro) * f,
                                                     highG: p.highG + (first.highG - p.highG) * f))
                        }
                        engine.ingest(gapFill)
                        allSamples += gapFill
                    }
                }
                allSamples += samples
                engine.ingest(samples)
                prev = samples.last
                curT = samples.last?.time ?? curT
                RunLoop.main.run(until: Date().addingTimeInterval(0.0005))
            }
            engine.ingest([])
            Thread.sleep(forTimeInterval: 2)
            RunLoop.main.run(until: Date().addingTimeInterval(1))

            // Independent swing count: gyro-magnitude peaks above 15 rad/s at least 0.6 s apart.
            var swings: [Double] = []
            for s in allSamples where simd_length(s.gyro) > 15 {
                if let l = swings.last, s.time - l < 0.6 { continue }
                swings.append(s.time)
            }
            let t0 = allSamples.first?.time ?? 0
            var report = "\n=== \(dir)\npackets \(packets), lost \(lost), samples \(allSamples.count)\n"
            report += "gyro swings (>15 rad/s): \(swings.count); engine shots: \(shots.count)\n"
            let clean = shots.filter { $0.2 == 0 }, dirty = shots.filter { $0.2 > 0 }
            func fh(_ a: [(ShotMetrics, Double, Int)]) -> String { "\(a.filter { $0.0.type == .forehand }.count)/\(a.count) forehand" }
            report += "fill=\(fill): shots with no packet loss in the prior 1 s: \(fh(clean)); with loss: \(fh(dirty))\n"
            for (s, _, lossN) in shots {
                report += String(format: "  [lost %d] %@ swing %.0f km/h ball %.0f km/h peakG %.0f impact (%.1f, %.1f) cm sat %@ spin %@\n",
                                 lossN, s.type.rawValue, s.swingSpeedKmh, s.ballSpeedKmh, s.peakG, s.impactXcm, s.impactYcm,
                                 s.gyroSaturated ? "Y" : "n", s.spin.rawValue)
            }
            report += "swing times (s from start): " + swings.map { String(format: "%.1f", $0 - t0) }.joined(separator: " ") + "\n"
            print(report)
        }
    }
}

/// Tries all 24 proper axis mappings as the sensor-to-racket calibration and counts the shot types each produces.
/// Every shot in the club sessions was a right-handed forehand, so the right mapping should call them all forehands.
final class CalibrationSweepTests: XCTestCase {
    private func shots(in dir: String, calibration: Calibration) throws -> [ShotMetrics] {
        let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("racket.bin"))
        let engine = RacketEngine()
        engine.calibration = calibration
        var out: [ShotMetrics] = []
        engine.onShot = { out.append($0) }
        var h3Range: UInt8 = 1, wraps = 0.0, lastMicros: UInt32 = 0, pos = 0
        var batches: [[IMUSample]] = []
        while pos + 11 <= data.count {
            let n = Int(data[pos + 9]) | Int(data[pos + 10]) << 8
            let kind = data[pos + 8]
            pos += 11
            guard pos + n <= data.count else { break }
            let payload = data.subdata(in: pos..<(pos + n))
            pos += n
            if kind == 2, payload.count >= 6 { h3Range = payload[5] }
            guard kind == 1, let packet = RacketProtocol.decodePacket(payload) else { continue }
            if packet.t0Micros < lastMicros, lastMicros - packet.t0Micros > 1_000_000_000 { wraps += 4294.967296 }
            lastMicros = packet.t0Micros
            let t0 = Double(packet.t0Micros) / 1e6 + wraps
            let wide = packet.flags & RacketProtocol.flagGyro4000 != 0
            IMUSample.gyroSaturation = (wide ? 3990 : 1990) * .pi / 180
            let scale = wide ? RacketProtocol.mpuGyroLSBPerDps / 2 : RacketProtocol.mpuGyroLSBPerDps
            batches.append(packet.samples.enumerated().map { k, raw in
                RacketProtocol.convert(raw, time: t0 + Double(k) * 0.001, h3lisRange: h3Range, gyroLSBPerDps: scale)
            })
        }
        for b in batches { engine.ingest(b) }
        engine.ingest([])
        Thread.sleep(forTimeInterval: 1.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return out
    }

    func testSweep() throws {
        guard let dirs = ProcessInfo.processInfo.environment["REPLAY_DIRS"] else { throw XCTSkip("REPLAY_DIRS not set") }
        let dirList = dirs.split(separator: ",").map(String.init)
        var mappings: [simd_float3x3] = []
        let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for p in perms {
            for signs in 0..<8 {
                var rows: [SIMD3<Float>] = []
                for r in 0..<3 {
                    var v = SIMD3<Float>(0, 0, 0)
                    v[p[r]] = (signs >> r) & 1 == 1 ? -1 : 1
                    rows.append(v)
                }
                let m = simd_float3x3(rows: rows)
                if m.determinant > 0 { mappings.append(m) }
            }
        }
        var report = "\nmapping rows (racket x,y,z in sensor axes) -> forehand/backhand/serve/volley (pooled, \(dirList.count) sessions)\n"
        for m in mappings {
            var cal = Calibration.default
            cal.mpuToRacket = m
            cal.h3lisToRacket = m
            var counts: [ShotType: Int] = [:]
            for d in dirList { for s in try shots(in: d, calibration: cal) { counts[s.type, default: 0] += 1 } }
            let r = (0..<3).map { i in "(" + (0..<3).map { j in String(Int(m.transpose[i][j])) }.joined(separator: ",") + ")" }.joined()
            report += "\(r): F \(counts[.forehand] ?? 0) B \(counts[.backhand] ?? 0) S \(counts[.serve] ?? 0) V \(counts[.volley] ?? 0)\n"
        }
        print(report)
    }
}

/// Re-runs the engine's detection on the recorded sessions and prints per-shot features, to see which quantity
/// separates forehands from backhands. Mirrors RacketEngine.process/detect/finishShot (default calibration).
final class FeatureDumpTests: XCTestCase {
    func testDump() throws {
        guard let dirs = ProcessInfo.processInfo.environment["REPLAY_DIRS"] else { throw XCTSkip("REPLAY_DIRS not set") }
        for dir in dirs.split(separator: ",").map(String.init) {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("racket.bin"))
            var samples: [IMUSample] = []
            var h3Range: UInt8 = 1, wraps = 0.0, lastMicros: UInt32 = 0, pos = 0
            while pos + 11 <= data.count {
                let n = Int(data[pos + 9]) | Int(data[pos + 10]) << 8
                let kind = data[pos + 8]
                pos += 11
                guard pos + n <= data.count else { break }
                let payload = data.subdata(in: pos..<(pos + n))
                pos += n
                if kind == 2, payload.count >= 6 { h3Range = payload[5] }
                guard kind == 1, let packet = RacketProtocol.decodePacket(payload) else { continue }
                if packet.t0Micros < lastMicros, lastMicros - packet.t0Micros > 1_000_000_000 { wraps += 4294.967296 }
                lastMicros = packet.t0Micros
                let t0 = Double(packet.t0Micros) / 1e6 + wraps
                let wide = packet.flags & RacketProtocol.flagGyro4000 != 0
                let scale = wide ? RacketProtocol.mpuGyroLSBPerDps / 2 : RacketProtocol.mpuGyroLSBPerDps
                for (k, raw) in packet.samples.enumerated() {
                    samples.append(RacketProtocol.convert(raw, time: t0 + Double(k) * 0.001, h3lisRange: h3Range, gyroLSBPerDps: scale))
                }
            }
            let cal = Calibration.default
            var filter = MahonyFilter()
            var ring: [(IMUSample, simd_quatf)] = []
            var lastTime: Double?, lastShot = -10.0
            var report = "\n=== \(dir)\n  t   | wPre body (x,y,z)   | faceLead(-wy) | wz_world 8ms  | wz mean 120ms | wz mean 300ms | tip.up | type(now)\n"
            for raw in samples {
                let s = cal.apply(raw)
                let dt = Float(lastTime.map { min(max(s.time - $0, 0.0002), 0.02) } ?? 0.001)
                lastTime = s.time
                filter.update(gyro: s.gyro, accel: s.accel, dt: dt)
                ring.append((s, filter.q))
                if ring.count > 1500 { ring.removeFirst(ring.count - 1500) }
                let n = ring.count
                guard n > 400, s.time - lastShot > 0.4 else { continue }
                let jump = simd_length(s.highG - ring[n - 4].0.highG)
                guard jump > 10 else { continue }
                guard (ring[(n - 150)..<n].map { simd_length($0.0.gyro) }.max() ?? 0) > 5 else { continue }
                // Impact at this sample (the engine waits 150 ms and refines; ±few ms does not matter here).
                lastShot = s.time
                let i0 = n - 3
                func meanW(_ a: Int, _ b: Int) -> SIMD3<Float> {
                    ring[(i0 - a)..<(i0 - b)].reduce(SIMD3<Float>.zero) { $0 + $1.1.act($1.0.gyro) } / Float(a - b)
                }
                let wPre = ring[(i0 - 10)..<(i0 - 2)].reduce(SIMD3<Float>.zero) { $0 + $1.0.gyro } / 8
                let q = ring[i0 - 3].1
                let tip = q.act(SIMD3(1, 0, 0))
                let omegaW = q.act(wPre)
                let ccw = omegaW.z > 0
                report += String(format: " %5.1f | %6.1f %6.1f %6.1f | %7.1f | %7.1f | %7.1f | %7.1f | %5.2f | %@\n",
                                 s.time - samples[0].time, wPre.x, wPre.y, wPre.z, -wPre.y, omegaW.z,
                                 meanW(120, 5).z, meanW(300, 5).z, tip.z, ccw ? "forehand" : "backhand")
            }
            print(report)
        }
    }
}
