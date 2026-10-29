import XCTest
import simd
@testable import RacketKit

/// Runs ShotAnalyzer on a labeled recording: a folder with the app's session-...-racket.csv and labels.txt (one
/// stroke per visible impact: FH, BH, SV, VO). tools/shot_type_check.py is the same check in Python.
/// Runs only with LABELED_SESSION=<folder> (e.g. data/room-2026-10-29); LABELED_FOREHAND_SIGN=-1 or 1 sets a
/// taught forehand.
final class LabeledSessionTests: XCTestCase {
    func testShotTypesMatchLabels() throws {
        guard let dir = ProcessInfo.processInfo.environment["LABELED_SESSION"] else {
            throw XCTSkip("LABELED_SESSION not set")
        }
        let folder = URL(fileURLWithPath: dir)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let csv = try XCTUnwrap(files.first { $0.pathExtension == "csv" })
        let labels = try String(contentsOf: folder.appendingPathComponent("labels.txt"), encoding: .utf8)
            .split { $0.isWhitespace || $0 == "," }.map(String.init)
        let cal = Calibration.default
        let samples: [IMUSample] = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n").dropFirst()
            .compactMap { line in
                let v = line.split(separator: ",").compactMap { Float($0) }
                guard v.count == 10, let time = Double(line.split(separator: ",")[0]) else { return nil }
                return cal.apply(IMUSample(time: time, accel: SIMD3(v[1], v[2], v[3]), gyro: SIMD3(v[4], v[5], v[6]),
                                           highG: SIMD3(v[7], v[8], v[9])))
            }

        // Orientation the way RacketEngine tracks it.
        var filter = MahonyFilter()
        var orientations: [simd_quatf] = []
        orientations.reserveCapacity(samples.count)
        for (k, s) in samples.enumerated() {
            let dt = Float(k == 0 ? 0.001 : min(max(s.time - samples[k - 1].time, 0.0002), 0.02))
            filter.update(gyro: s.gyro, accel: s.accel, dt: dt)
            orientations.append(filter.q)
        }

        // Impacts from high-g peaks, so hits the phone's detector missed still line up with their labels.
        var peaks: [Int] = []
        for (k, s) in samples.enumerated() where simd_length(s.highG) > 4 {
            if let last = peaks.last, s.time - samples[last].time < 0.6 {
                if simd_length(s.highG) > simd_length(samples[last].highG) { peaks[peaks.count - 1] = k }
            } else {
                peaks.append(k)
            }
        }
        XCTAssertEqual(peaks.count, labels.count, "impacts vs labels")

        var profile = RacketProfile()
        profile.forehandBodySign = ProcessInfo.processInfo.environment["LABELED_FOREHAND_SIGN"].flatMap(Float.init) ?? 0
        let analyzer = ShotAnalyzer(profile: profile, model: ImpactModel())
        let names: [String: ShotType] = ["FH": .forehand, "BH": .backhand, "SV": .serve, "VO": .volley]
        var right = 0
        for (label, p) in zip(labels, peaks) {
            // RacketEngine.analyzeImpact: largest 3-sample jump within ±6, impact on its first sample.
            let best = (max(3, p - 6)...min(samples.count - 1, p + 6))
                .max { simd_length(samples[$0].highG - samples[$0 - 3].highG) < simd_length(samples[$1].highG - samples[$1 - 3].highG) }!
            let i0 = best - 2, lo = max(0, i0 - 700), hi = min(samples.count, i0 + 150)
            let shot = analyzer.analyze(window: Array(samples[lo..<hi]), impact: i0 - lo,
                                        orientation: orientations[max(i0 - 3, 0)], date: Date(), calibrationMode: false)
            let ok = shot.type == names[label]
            right += ok ? 1 : 0
            print(String(format: "%@ -> %@%@ swing %.0f° vertical %+.2f ball %.0f km/h", label, shot.type.label,
                         ok ? "" : " ✗", shot.features.swingDeg ?? 0, shot.features.verticalSpin ?? 0, shot.ballSpeedKmh))
        }
        print("\(right)/\(labels.count) correct")
        // Serves need the forehand face, which a session without a taught forehand learns only partway through.
        let needed = profile.forehandBodySign != 0 ? labels.count : labels.filter { $0 != "SV" }.count
        XCTAssertGreaterThanOrEqual(right, needed)
    }
}
