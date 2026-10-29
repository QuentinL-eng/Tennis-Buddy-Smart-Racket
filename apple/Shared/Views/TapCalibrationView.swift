import RacketKit
import SwiftUI
import simd

/// Records a few taps on each kind of handle side so tap scoring knows which push direction is which.
/// Afterwards every tap shows the side it was read as, to check before a match.
struct TapCalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step { case wide, narrow, review, test }
    @State private var step: Step = .wide
    @State private var wide: [SIMD3<Float>] = []
    @State private var narrow: [SIMD3<Float>] = []
    @State private var fitted: TapCalibration?
    @State private var lastReading = ""
    @State private var tapPulse = 0

    private let tapsPerSide = 5

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch step {
                case .wide:
                    collect(title: "Wide sides", count: wide.count,
                            text: "Tap one of the two wide sides of the handle, the ones parallel to the strings. One firm tap at a time, about a second apart. Use both wide sides.")
                case .narrow:
                    collect(title: "Narrow sides", count: narrow.count,
                            text: "Now tap the two narrow sides, the edges in line with the frame. Same again: one tap at a time, both sides.")
                case .review: review
                case .test: test
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .navigationTitle("Calibrate taps")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .onAppear { model.onCalibrationTap = { tap in record(tap) } }
        .onDisappear { model.onCalibrationTap = nil }
    }

    private func collect(title: String, count: Int, text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.bounce, value: tapPulse)
            Text(title).font(.title2.bold())
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(0..<tapsPerSide, id: \.self) { i in
                    Circle().fill(i < count ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 18, height: 18)
                }
            }
            if !model.isConnected || model.sourceKind != .racket {
                Text("Connect the racket first (Racket tab).").font(.callout).foregroundStyle(.orange)
            }
            if step == .narrow {
                Button("Start over") { restart() }.font(.callout)
            }
        }
    }

    private var review: some View {
        VStack(spacing: 16) {
            if let cal = fitted {
                let good = cal.separationDegrees >= 45
                Image(systemName: good ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(good ? .green : .orange)
                Text(good ? "Sides told apart" : "The sides look alike").font(.title2.bold())
                Text(good
                     ? "The wide and narrow sides push the handle \(Int(cal.separationDegrees))° apart. Save, then try a few taps."
                     : "The two kinds of side are only \(Int(cal.separationDegrees))° apart, so taps would be misread. Try again with firmer taps on the middle of each side.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack {
                    Button("Redo") { restart() }
                    Button("Save") {
                        model.tapCalibration = cal
                        step = .test
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
                }
            } else {
                Text("Couldn't fit the taps").font(.title2.bold())
                Button("Redo") { restart() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
            }
        }
    }

    private var test: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.bounce, value: tapPulse)
            Text("Try it").font(.title2.bold())
            Text("Tap any side: the app shows how it read the tap. Score taps are ignored while this screen is open.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(lastReading.isEmpty ? "Waiting for a tap…" : lastReading)
                .font(.title3.weight(.semibold))
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.fill.quaternary, in: .rect(cornerRadius: 12))
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).foregroundStyle(.black)
        }
    }

    private func record(_ tap: RacketProtocol.TapGesture) {
        tapPulse += 1
        switch step {
        case .wide:
            wide.append(tap.direction)
            if wide.count >= tapsPerSide { step = .narrow }
        case .narrow:
            narrow.append(tap.direction)
            if narrow.count >= tapsPerSide {
                fitted = TapCalibration.fit(wide: wide, narrow: narrow)
                step = .review
            }
        case .review:
            break
        case .test:
            let side = model.effectiveTapCalibration.classify(tap.direction)
            let what = tap.count == 1 ? "Single tap" : tap.count == 2 ? "Double tap" : "Triple tap"
            let command: String
            switch ScoreCommand.from(count: tap.count, side: side?.side) {
            case .won: command = "point to you"
            case .lost: command = "point to your opponent"
            case .undo: command = "undo"
            case nil: command = "not a score tap"
            }
            lastReading = "\(what), \(side?.side.label.lowercased() ?? "unclear side"): \(command)"
        }
    }

    private func restart() {
        wide = []
        narrow = []
        fitted = nil
        step = .wide
    }
}
