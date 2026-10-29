import RacketKit
import SwiftUI

/// Guided calibration: two still poses to align axes, then an optional sweet-spot check: ball drops on known
/// squares of a taped 3×3 grid, scored against the racket's on-device verdict and saved as a CSV for data/ and ml/.
struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitSystem.storageKey) private var useMetric = false
    private var units: UnitSystem { UnitSystem(metric: useMetric) }

    enum Step: Int { case intro, tipUp, faceUp, check, done }
    @State private var step: Step = .intro
    @State private var capturing = false
    @State private var tipUp: Calibration.PoseReading?
    @State private var selectedCell: SweetSpotCheck.Cell?
    @State private var check = SweetSpotCheck()
    @State private var savedCSV: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch step {
                case .intro: intro
                case .tipUp: pose(title: "Tip up", symbol: "arrow.up",
                                  text: "Hold the racket with the tip pointing straight up and keep it still.")
                case .faceUp: pose(title: "Lay it flat", symbol: "rectangle.portrait.on.rectangle.portrait",
                                   text: "Lay the racket flat on a table, strings facing up. Pick the face you'd call \"front\".")
                case .check: checkStep
                case .done: done
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .navigationTitle("Calibrate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { finish() } }
            }
        }
        .onDisappear { stopListening() }
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: "scope").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Calibrate your racket").font(.title2.bold())
            Text("Two quick poses teach the app how the sensors sit in the handle. Then, optionally, drop balls on a taped grid to check how often the racket's sweet-spot AI gets it right.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Start") { step = .tipUp }.buttonStyle(.borderedProminent).foregroundStyle(.black)
        }
    }

    private func pose(title: String, symbol: String, text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text(title).font(.title2.bold())
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button {
                capture()
            } label: {
                if capturing { ProgressView() } else { Text("Hold still — capture") }
            }
            .buttonStyle(.borderedProminent).foregroundStyle(.black)
            .disabled(capturing)
        }
    }

    private func capture() {
        capturing = true
        model.engine.captureStill(seconds: 2) { reading in
            capturing = false
            if step == .tipUp {
                tipUp = reading
                step = .faceUp
            } else if let tip = tipUp {
                model.calibration = Calibration.from(tipUp: tip, faceUp: reading)
                model.recenter()
                step = .check
                model.calibrationMode = true
                model.onCalibrationImpact = { shot in
                    guard let cell = selectedCell else { return }
                    check.add(shot: shot, cell: cell)
                }
                model.onCalibrationVerdict = { verdict in
                    guard let cell = selectedCell else { return }
                    check.add(verdict: verdict, cell: cell)
                }
            }
        }
    }

    private var checkStep: some View {
        VStack(spacing: 14) {
            Text("Sweet-spot check (optional)").font(.title2.bold())
            Text("Tape a 3×3 grid on the strings (squares about \(units.lengthText(5)) apart across, \(units.lengthText(6)) along). Hold the racket face-up with a relaxed grip, tap a square, then drop a ball on it from about \(useMetric ? "1.5 m" : "5 ft"). The center square is the sweet spot. Five drops per square is plenty.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if model.sourceKind != .racket {
                Label("Connect the racket: verdicts come from its on-device model.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            VStack(spacing: 8) {
                Text("Tip ↑").font(.caption).foregroundStyle(.secondary)
                ForEach([1, 0, -1], id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach([-1, 0, 1], id: \.self) { col in
                            cellButton(SweetSpotCheck.Cell(col: col, row: row))
                        }
                    }
                }
                Text("Throat ↓").font(.caption).foregroundStyle(.secondary)
            }
            Text(scoreText).font(.callout.monospacedDigit()).multilineTextAlignment(.center)
            if let last = check.drops.last { Text(lastDropText(last)).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Undo") { check.undo() }.disabled(check.drops.isEmpty)
                Button("Skip") { stopListening(); step = .done }
                Button("Finish & save") { save() }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
                    .disabled(check.drops.isEmpty)
            }
        }
    }

    private func cellButton(_ cell: SweetSpotCheck.Cell) -> some View {
        let drops = check.drops(in: cell)
        let scored = drops.filter { $0.racketSweet != nil }
        let right = scored.filter { $0.racketCorrect == true }.count
        let selected = selectedCell == cell
        return Button {
            selectedCell = cell
        } label: {
            VStack(spacing: 2) {
                Text("\(drops.count)").font(.title3.monospacedDigit().bold())
                Text(scored.isEmpty ? (cell.isSweet ? "sweet" : " ") : "\(right)/\(scored.count) ✓")
                    .font(.caption2.monospacedDigit())
            }
            .frame(width: 70, height: 70)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 12))
            .overlay {
                if cell.isSweet { RoundedRectangle(cornerRadius: 12).strokeBorder(.green, lineWidth: 2) }
            }
            .foregroundStyle(selected ? .black : .primary)
        }
        .buttonStyle(.plain)
    }

    private var scoreText: String {
        guard let accuracy = check.accuracy else {
            return check.drops.isEmpty ? "Pick a square, then drop." : "No verdicts from the racket yet."
        }
        let s = check.sweetHits, o = check.offHits
        return "Racket AI right on \(check.correct) of \(check.scored) (\(Int((accuracy * 100).rounded()))%)\n"
            + "Sweet spot \(s.correct)/\(s.of) · off-center \(o.correct)/\(o.of)"
    }

    private func lastDropText(_ d: SweetSpotCheck.Drop) -> String {
        guard let sweet = d.racketSweet else { return "Last: \(d.cell.name) → no verdict from the racket" }
        let said = sweet ? "Sweet spot" : "\(d.offCenterPercent ?? 0)% off"
        return "Last: \(d.cell.name) → racket said \(said) (\(d.confidencePercent ?? 0)% sure)"
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("Calibrated").font(.title2.bold())
            Text(check.drops.isEmpty ? "Sensor axes are aligned to the racket." : "Sensor axes are aligned.\n\(scoreText)")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let savedCSV {
                ShareLink(item: savedCSV) { Label("Share drop data (CSV)", systemImage: "square.and.arrow.up") }
                #if os(iOS)
                Text("Also in Files → Tennis Buddee → Calibration. Copy it to data/ to track the model's accuracy.")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                #endif
            }
            Button("Done") { finish() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
        }
    }

    /// Saves the drops, one CSV row each, next to the recordings.
    private func save() {
        stopListening()
        let dir = AppModel.recordingsDirectory.deletingLastPathComponent().appendingPathComponent("Calibration")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("sweetspot-check-\(Int(Date().timeIntervalSince1970)).csv")
        if (try? check.csv().write(to: file, atomically: true, encoding: .utf8)) != nil { savedCSV = file }
        step = .done
    }

    private func stopListening() {
        model.calibrationMode = false
        model.onCalibrationImpact = nil
        model.onCalibrationVerdict = nil
    }

    private func finish() {
        stopListening()
        dismiss()
    }
}
