import RacketKit
import SwiftData
import SwiftUI

/// Change one thing about your average stroke and see what the racket model estimates, then ask the coach to
/// find the best change. Same baseline and physics as Muse's `simulate_change` tool (`WhatIf`, `ShotSimulator`).
struct WhatIfView: View {
    @Query(sort: \SessionRecord.startDate) private var sessions: [SessionRecord]
    @Environment(CoachModel.self) private var coach
    @Environment(AppModel.self) private var model
    @AppStorage(UnitSystem.storageKey) private var useMetric = false
    @State private var stroke = ShotType.forehand
    @State private var deltas = WhatIf.Deltas()
    @State private var asked = ""
    @State private var answer = ""
    private var units: UnitSystem { UnitSystem(metric: useMetric) }

    private static let good = Color(red: 0.37, green: 0.86, blue: 0.54)
    private static let bad = Color(red: 1, green: 0.6, blue: 0.55)

    /// The latest session with at least one swing the model can start from.
    private var session: SessionRecord? { sessions.last { WhatIf.baseline($0.shots) != nil } }

    private func strokes(_ s: SessionRecord) -> [ShotType] {
        [.forehand, .backhand, .serve, .volley].filter { WhatIf.baseline(s.shots, type: $0) != nil }
    }

    var body: some View {
        ScrollView {
            if let session {
                content(session).padding()
            } else {
                ContentUnavailableView("No swings to test yet", systemImage: "slider.horizontal.3",
                    description: Text("Play a session with the racket's motion sensors on, then try changes here."))
            }
        }
        .navigationTitle("What if")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reset", systemImage: "arrow.counterclockwise") { withAnimation { deltas = WhatIf.Deltas() } }
                    .disabled(deltas.isZero)
            }
        }
    }

    @ViewBuilder private func content(_ session: SessionRecord) -> some View {
        let available = strokes(session)
        VStack(alignment: .leading, spacing: 20) {
            if available.count > 1 {
                Picker("Stroke", selection: $stroke) {
                    ForEach(available) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if let base = WhatIf.baseline(session.shots, type: available.contains(stroke) ? stroke : available.first) {
                let type = available.contains(stroke) ? stroke : available.first!
                baselineCard(base, type: type, session: session)
                resultCard(base)
                controls
                askCard(session, type: type)
            }
        }
        .onAppear { if !available.contains(stroke), let first = available.first { stroke = first } }
        .sensoryFeedback(.selection, trigger: deltas)
    }

    // MARK: Cards

    private func baselineCard(_ base: WhatIf.Baseline, type: ShotType, session: SessionRecord) -> some View {
        let p = base.parameters
        let face = p.faceAngleDeg >= 0 ? "\(Int(p.faceAngleDeg.rounded()))° open" : "\(Int(-p.faceAngleDeg.rounded()))° closed"
        return VStack(alignment: .leading, spacing: 8) {
            Text("Your average \(type.label.lowercased())").font(.headline)
            Text("\(base.sampleCount) swings from \(session.startDate.formatted(.dateTime.weekday().day().month()))")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { stat("Swing", units.speedText(p.swingSpeedKmh)); stat("Path", "\(Int(p.pathAngleDeg.rounded()))° up") }
                GridRow { stat("Face", face); stat("Contact", contactText(x: p.contactXcm, y: p.contactYcm)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    private func contactText(x: Double, y: Double) -> String {
        let d = (x * x + y * y).squareRoot()
        guard d >= 0.5 else { return "centered" }
        let dir = abs(y) >= abs(x) ? (y > 0 ? "toward tip" : "toward throat") : (x > 0 ? "right" : "left")
        return "\(units.lengthText(d)) \(dir)"
    }

    private func resultCard(_ base: WhatIf.Baseline) -> some View {
        let impact = model.impactModel
        let before = ShotSimulator.simulate(base.parameters, model: impact)
        let after = ShotSimulator.simulate(WhatIf.apply(deltas, to: base.parameters), model: impact)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(deltas.isZero ? "Move a slider to test a change" : WhatIf.describe(deltas, units: units).capitalizedFirst)
                    .font(.headline)
                Spacer()
                Text("Estimated").font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.fill.tertiary, in: .capsule)
            }
            HStack(alignment: .top, spacing: 12) {
                outcome("Ball speed", before: units.speedValue(before.ballSpeedKmh), after: units.speedValue(after.ballSpeedKmh),
                        unit: units.speedUnit, change: units.speed(after.ballSpeedKmh) - units.speed(before.ballSpeedKmh), note: nil)
                outcome("Spin", before: "\(Int(before.spinRPM.rounded()))", after: "\(Int(after.spinRPM.rounded()))",
                        unit: "rpm", change: after.spinRPM - before.spinRPM,
                        note: after.spin == before.spin ? after.spin.label : "\(before.spin.label) → \(after.spin.label)")
            }
            Text("Physics estimate on your average swing, with an assumed incoming ball. Ball flight, depth and net clearance aren't modeled.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
        .animation(.snappy, value: deltas)
    }

    private func outcome(_ title: String, before: String, after: String, unit: String, change: Double, note: String?) -> some View {
        let color = abs(change) < 0.5 ? Color.secondary : (change > 0 ? Self.good : Self.bad)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(after).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(abs(change) < 0.5 ? "was \(before)" : "\(change > 0 ? "▲" : "▼") \(Int(abs(change).rounded())) from \(before)")
                .font(.subheadline.weight(.semibold)).foregroundStyle(color)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            slider("Swing speed", value: $deltas.swingPercent, limit: WhatIf.Deltas.swingLimit, step: 1) {
                $0 == 0 ? "same" : "\($0 > 0 ? "+" : "−")\(Int(abs($0)))%"
            }
            slider("Racket face", value: $deltas.faceDeg, limit: WhatIf.Deltas.angleLimit, step: 1) {
                $0 == 0 ? "same" : "\(Int(abs($0)))° \($0 > 0 ? "more open" : "more closed")"
            }
            slider("Swing path", value: $deltas.pathDeg, limit: WhatIf.Deltas.angleLimit, step: 1) {
                $0 == 0 ? "same" : "\(Int(abs($0)))° \($0 > 0 ? "more low-to-high" : "flatter")"
            }
            slider("Contact, tip ↔ throat", value: $deltas.contactYcm, limit: WhatIf.Deltas.contactLimit, step: 0.5) {
                $0 == 0 ? "same" : "\(units.lengthText(abs($0))) toward \($0 > 0 ? "tip" : "throat")"
            }
            slider("Contact, left ↔ right", value: $deltas.contactXcm, limit: WhatIf.Deltas.contactLimit, step: 0.5) {
                $0 == 0 ? "same" : "\(units.lengthText(abs($0))) \($0 > 0 ? "right" : "left")"
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
    }

    private func slider(_ title: String, value: Binding<Double>, limit: Double, step: Double,
                        text: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(text(value.wrappedValue)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: -limit...limit, step: step)
                .accessibilityValue(text(value.wrappedValue))
        }
    }

    // MARK: Coach

    private func askCard(_ session: SessionRecord, type: ShotType) -> some View {
        let s = type.label.lowercased()
        let goals = [("Find more spin", "flame", "How can I get more topspin on my \(s) without losing pace?"),
                     ("Find more pace", "speedometer", "What's the quickest way to add speed to my \(s)?"),
                     ("Cleaner contact", "scope", "How do I find the sweet spot more on my \(s)?")]
        return VStack(alignment: .leading, spacing: 12) {
            Label("Ask the coach", systemImage: "sparkles").font(.headline)
            Button {
                ask("What if I \(WhatIf.describe(deltas, units: units)) on my \(s)?", session)
            } label: {
                Label("Ask about this change", systemImage: "questionmark.bubble").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(.black)
            .disabled(deltas.isZero || coach.isWorking)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(goals, id: \.0) { goal in
                        Button(goal.0, systemImage: goal.1) { ask(goal.2, session) }
                            .buttonStyle(.bordered).disabled(coach.isWorking)
                    }
                }
            }
            if coach.isWorking {
                HStack { ProgressView().controlSize(.small); Text("The coach is testing changes…").foregroundStyle(.secondary) }
            }
            if !answer.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(asked).font(.subheadline.weight(.semibold))
                    Text(answer).textSelection(.enabled)
                    RememberedNotes()
                    Text(coach.engineName).font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
    }

    private func ask(_ question: String, _ session: SessionRecord) {
        guard !coach.isWorking else { return }
        asked = question
        answer = ""
        Task { answer = await coach.answer(question, session: session) }
    }
}

/// "Coach remembered: …" under an answer, linking to the notes.
struct RememberedNotes: View {
    @Environment(CoachModel.self) private var coach

    var body: some View {
        if !coach.lastRemembered.isEmpty {
            NavigationLink { MemoryView() } label: {
                Label {
                    Text("Coach remembered: " + coach.lastRemembered.joined(separator: " · ")).font(.caption)
                } icon: { Image(systemName: "brain") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
