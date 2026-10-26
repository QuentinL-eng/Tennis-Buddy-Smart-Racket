import RacketKit
import SwiftUI

/// Guided calibration: two still poses to align axes, then labeled ball drops on a taped 3×3 grid
/// to fit the hit-location model. Drops are saved so they can be committed to data/calibration.
struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitSystem.storageKey) private var useMetric = false
    private var units: UnitSystem { UnitSystem(metric: useMetric) }

    enum Step: Int { case intro, tipUp, faceUp, grid, done }
    @State private var step: Step = .intro
    @State private var capturing = false
    @State private var tipUp: Calibration.PoseReading?
    @State private var selectedCell: GridCell?
    @State private var drops: [LabeledDrop] = []
    @State private var fitMessage = ""

    struct GridCell: Hashable, Codable {
        var col: Int   // -1 left, 0 center, 1 right
        var row: Int   // 1 tip, 0 center, -1 throat
        var xCm: Double { Double(col) * 5 }
        var yCm: Double { Double(row) * 6 }
    }

    struct LabeledDrop: Codable {
        var cell: GridCell
        var features: ImpactFeatures
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch step {
                case .intro: intro
                case .tipUp: pose(title: "Tip up", symbol: "arrow.up",
                                  text: "Hold the racket with the tip pointing straight up and keep it still.")
                case .faceUp: pose(title: "Lay it flat", symbol: "rectangle.portrait.on.rectangle.portrait",
                                   text: "Lay the racket flat on a table, strings facing up. Pick the face you'd call \"front\".")
                case .grid: grid
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
        .onDisappear { model.calibrationMode = false; model.onCalibrationImpact = nil }
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: "scope").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Calibrate your racket").font(.title2.bold())
            Text("Two quick poses teach the app how the sensors sit in the handle. Then, optionally, drop a ball on a taped 3×3 grid to tune hit-location accuracy.")
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
                step = .grid
                model.calibrationMode = true
                model.onCalibrationImpact = { shot in
                    guard let cell = selectedCell else { return }
                    drops.append(LabeledDrop(cell: cell, features: shot.features))
                }
            }
        }
    }

    private var grid: some View {
        VStack(spacing: 14) {
            Text("Ball drops (optional)").font(.title2.bold())
            Text("Tape a 3×3 grid on the strings (squares about \(units.lengthText(5)) apart across, \(units.lengthText(6)) along). Hold the racket face-up with a relaxed grip, tap a square, then drop a ball on it from about \(useMetric ? "1.5 m" : "5 ft"). Five drops per square is plenty.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("Tip ↑").font(.caption).foregroundStyle(.secondary)
                ForEach([1, 0, -1], id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach([-1, 0, 1], id: \.self) { col in
                            let cell = GridCell(col: col, row: row)
                            let count = drops.filter { $0.cell == cell }.count
                            Button {
                                selectedCell = cell
                            } label: {
                                Text("\(count)")
                                    .font(.title3.monospacedDigit().bold())
                                    .frame(width: 70, height: 70)
                                    .background(selectedCell == cell ? Color.accentColor : Color.secondary.opacity(0.15),
                                                in: .rect(cornerRadius: 12))
                                    .foregroundStyle(selectedCell == cell ? .black : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Throat ↓").font(.caption).foregroundStyle(.secondary)
            }
            if !fitMessage.isEmpty { Text(fitMessage).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Skip") { step = .done; model.calibrationMode = false }
                Button("Fit & save") { fit() }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
                    .disabled(drops.count < 6)
            }
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("Calibrated").font(.title2.bold())
            Text(fitMessage.isEmpty ? "Sensor axes are aligned to the racket." : fitMessage)
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Done") { finish() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
        }
    }

    /// Least-squares fit of the two location gains, then save the labeled drops.
    private func fit() {
        var model = model.impactModel
        let lat = drops.filter { $0.cell.col != 0 }
        let sxx = lat.reduce(0.0) { $0 + Double($1.features.rollRatio * $1.features.rollRatio) }
        let sxy = lat.reduce(0.0) { $0 + Double($1.features.rollRatio) * -$1.cell.xCm }
        if sxx > 1e-6 { model.lateralGain = Float(max(0.2, min(10, sxy / sxx))) }
        let lon = drops.filter { $0.cell.row != 0 }
        let rr = lon.reduce(0.0) { $0 + Double($1.features.ringNorm * $1.features.ringNorm) }
        let ry = lon.reduce(0.0) { $0 + Double($1.features.ringNorm) * abs($1.cell.yCm) }
        if rr > 1e-6 { model.longitudinalGain = Float(max(0.5, min(80, ry / rr))) }
        self.model.impactModel = model

        let dir = AppModel.recordingsDirectory.deletingLastPathComponent().appendingPathComponent("Calibration")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("drops-\(Int(Date().timeIntervalSince1970)).json")
        try? JSONEncoder().encode(drops).write(to: file)

        fitMessage = String(format: "Fitted from %d drops: side gain %.2f, tip/throat gain %.1f.",
                            drops.count, model.lateralGain, model.longitudinalGain)
        self.model.calibrationMode = false
        step = .done
    }

    private func finish() {
        model.calibrationMode = false
        model.onCalibrationImpact = nil
        dismiss()
    }
}
