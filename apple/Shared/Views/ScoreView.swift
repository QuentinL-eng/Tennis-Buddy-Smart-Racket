import RacketKit
import SwiftUI

/// Match score keeping. Points come from handle taps (double tap a wide side = won, single tap a narrow
/// side = lost, triple tap = undo), the buttons here, or the Watch.
struct ScoreView: View {
    @Environment(AppModel.self) private var model
    @State private var rules = MatchRules()
    @State private var showTapCalibration = false
    @State private var confirmEnd = false
    @AppStorage(ScoreAnnouncer.enabledKey) private var announce = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let match = model.match {
                    scoreboard(match)
                    pointButtons(match)
                    tapFeedback
                } else {
                    newMatch
                }
                tapGuide
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Score")
        .toolbar {
            if model.match != nil {
                ToolbarItem { Button("End match", systemImage: "flag.checkered") { confirmEnd = true } }
            }
        }
        .confirmationDialog("End this match?", isPresented: $confirmEnd) {
            Button("End match", role: .destructive) { model.endMatch() }
        }
        .sheet(isPresented: $showTapCalibration) {
            TapCalibrationView()
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
                #endif
        }
    }

    // MARK: Scoreboard

    private func scoreboard(_ match: ScoreTracker) -> some View {
        let s = match.score
        return VStack(spacing: 12) {
            Grid(horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(s.sets.indices, id: \.self) { i in Text("Set \(i + 1)") }
                    if s.winner == nil {
                        Text(s.isMatchTiebreak ? "" : "Games")
                        Text(s.isTiebreak ? "Tiebreak" : "Points")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(Player.allCases, id: \.self) { p in
                    GridRow {
                        HStack(spacing: 6) {
                            if s.winner == p { Image(systemName: "trophy.fill").foregroundStyle(.yellow) }
                            Text(p == .me ? "You" : "Opponent").font(.headline)
                        }
                        ForEach(s.sets.indices, id: \.self) { i in
                            let set = s.sets[i]
                            Text("\(set[p])")
                                .font(.title3.monospacedDigit())
                                .fontWeight(set[p] > set[p.other] ? .bold : .regular)
                                .foregroundStyle(set[p] > set[p.other] ? .primary : .secondary)
                        }
                        if s.winner == nil {
                            Text(s.isMatchTiebreak ? "" : "\(s.games[p])").font(.title2.monospacedDigit().bold())
                            Text(s.pointCall(p))
                                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
            .animation(.snappy, value: s)
            Text(s.winner == nil ? s.pointText : (s.winner == .me ? "You won the match" : "Your opponent won the match"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
    }

    private func pointButtons(_ match: ScoreTracker) -> some View {
        HStack(spacing: 10) {
            Button { model.award(.me) } label: {
                Label("I won", systemImage: "checkmark").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(.green)
            Button { model.award(.opponent) } label: {
                Label("They won", systemImage: "xmark").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            Button { model.undoPoint() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly).padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(!match.canUndo)
        }
        .controlSize(.large)
        .disabled(match.score.winner != nil && !match.canUndo)
    }

    @ViewBuilder private var tapFeedback: some View {
        if let f = model.lastTapFeedback {
            HStack(spacing: 10) {
                Image(systemName: f.recognized ? "hand.tap.fill" : "questionmark.circle")
                    .foregroundStyle(f.recognized ? Color.accentColor : .orange)
                Text(f.text).font(.callout)
                Spacer()
                Text(f.date, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.fill.quaternary, in: .rect(cornerRadius: 12))
            .id(f.id)
            .transition(.opacity)
        }
    }

    // MARK: New match

    private var newMatch: some View {
        VStack(spacing: 14) {
            Image(systemName: "trophy").font(.system(size: 48)).foregroundStyle(Color.accentColor)
            Text("Keep score with the racket").font(.title2.bold())
            Picker("Format", selection: $rules.setsToWin) {
                Text("Best of 3 sets").tag(2)
                Text("One set").tag(1)
            }
            .pickerStyle(.segmented)
            Toggle("No-ad scoring", isOn: $rules.noAd)
            if rules.setsToWin > 1 {
                Toggle("Match tiebreak instead of a third set", isOn: $rules.matchTiebreak)
            }
            Button {
                withAnimation(.snappy) { model.startMatch(rules: rules) }
            } label: {
                Label("Start match", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
        }
        .padding(18)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
    }

    // MARK: Tap guide

    private var tapGuide: some View {
        let cal = model.effectiveTapCalibration
        return VStack(alignment: .leading, spacing: 12) {
            Text("Score by tapping the handle").font(.headline)
            guideRow("2.circle.fill", "Double tap a wide side", "You won the point")
            guideRow("1.circle.fill", "Single tap a narrow side", "Your opponent won it")
            guideRow("3.circle.fill", "Triple tap anywhere", "Undo the last point")
            Divider()
            HStack {
                Image(systemName: cal.isCalibrated ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(cal.isCalibrated ? .green : .orange)
                Text(cal.isCalibrated
                     ? "Taps calibrated (sides \(Int(cal.separationDegrees))° apart)"
                     : "Taps not calibrated yet: the sides are guessed from the racket calibration")
                    .font(.callout)
            }
            Button("Calibrate taps…", systemImage: "hand.tap") { showTapCalibration = true }
            Toggle("Read the score out loud", isOn: $announce)
            if let note = connectionNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
    }

    private func guideRow(_ symbol: String, _ gesture: String, _ meaning: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text(gesture).font(.subheadline.weight(.semibold))
                Text(meaning).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Why taps might not arrive: no racket, or firmware from before tap support.
    private var connectionNote: String? {
        guard model.sourceKind == .racket, model.isConnected else {
            return "Taps need the racket connected (Racket tab). The buttons work any time."
        }
        if let fw = model.racketStatus?.firmwareVersion, !RacketFirmware.supportsTaps(fw) {
            return "The racket's firmware (\(fw)) predates tap gestures: update it to 1.2 or later."
        }
        return nil
    }
}

enum RacketFirmware {
    /// Tap gestures arrived in firmware 1.2.
    static func supportsTaps(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 1 || (parts[0] == 1 && parts[1] >= 2)
    }
}
