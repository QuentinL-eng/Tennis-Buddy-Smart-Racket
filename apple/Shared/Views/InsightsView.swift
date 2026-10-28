import Charts
import RacketKit
import SwiftData
import SwiftUI

/// The coach report for one session.
struct CoachCard: View {
    @Bindable var session: SessionRecord
    @Environment(CoachModel.self) private var coach

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if session.coachSummary.isEmpty {
                    Text("Get a plain-language report on this session.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(session.coachSummary).textSelection(.enabled)
                }
                HStack {
                    Button {
                        Task { session.coachSummary = await coach.summarize(session) }
                    } label: {
                        Label(session.coachSummary.isEmpty ? "Coach me" : "Regenerate", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                    .disabled(coach.isWorking)
                    if coach.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(coach.engineName).font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Coach", systemImage: "sparkles")
        }
    }
}

struct InsightsView: View {
    @Query(sort: \SessionRecord.startDate) private var sessions: [SessionRecord]
    @AppStorage(UnitSystem.storageKey) private var useMetric = false
    private var units: UnitSystem { UnitSystem(metric: useMetric) }
    @Environment(CoachModel.self) private var coach
    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var chat: [(q: String, a: String)] = []
    @State private var drill = ""
    @State private var apiKey = ""
    @State private var keyError: String?

    private var realSessions: [SessionRecord] { sessions.filter { $0.summary.count > 0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if realSessions.isEmpty {
                    ContentUnavailableView("No data yet", systemImage: "chart.xyaxis.line",
                                           description: Text("Play a session and your trends show up here."))
                } else {
                    trends
                    if let latest = realSessions.last { coachChat(latest) }
                }
                museSettings
            }
            .padding()
        }
        .navigationTitle("Insights")
    }

    private var trends: some View {
        GroupBox("Trends") {
            VStack(alignment: .leading, spacing: 16) {
                Chart(realSessions) { s in
                    LineMark(x: .value("Date", s.startDate), y: .value("Avg ball speed", units.speed(s.summary.avgBallKmh)))
                        .symbol(.circle)
                        .foregroundStyle(by: .value("Metric", "Ball speed"))
                    LineMark(x: .value("Date", s.startDate), y: .value("Avg swing speed", units.speed(s.summary.avgSwingKmh)))
                        .symbol(.square)
                        .foregroundStyle(by: .value("Metric", "Swing speed"))
                }
                .chartYAxisLabel(units.speedUnit)
                .frame(height: 180)
                Chart(realSessions) { s in
                    AreaMark(x: .value("Date", s.startDate), y: .value("Sweet spot %", s.summary.sweetSpotPercent))
                        .foregroundStyle(Color.green.opacity(0.15).gradient)
                    LineMark(x: .value("Date", s.startDate), y: .value("Sweet spot %", s.summary.sweetSpotPercent))
                        .symbol(.circle)
                        .foregroundStyle(Color.green)
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("Sweet spot %")
                .frame(height: 140)
            }
        }
    }

    private func coachChat(_ session: SessionRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ask about your latest session").font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(chat.enumerated()), id: \.offset) { _, item in
                    Text(item.q).font(.subheadline.weight(.semibold))
                    Text(item.a).textSelection(.enabled)
                    Divider()
                }
                HStack {
                    TextField("How was my backhand?", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { ask(session) }
                    Button("Ask", systemImage: "paperplane.fill") { ask(session) }
                        .disabled(question.isEmpty || coach.isWorking)
                }
                HStack {
                    ForEach(["What's my weakest stroke?", "Am I getting tired?", "What if I swing 5% slower?"], id: \.self) { s in
                        Button(s) { question = s; ask(session) }.buttonStyle(.bordered).font(.caption)
                    }
                }
                Text("What-if results estimate speed and spin using assumed incoming ball speeds. Ball flight and landing are not modeled.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button("Plan my next drill", systemImage: "figure.tennis") {
                        Task { drill = await coach.drill(session) }
                    }
                    .disabled(coach.isWorking)
                    if coach.isWorking { ProgressView().controlSize(.small) }
                }
                if !drill.isEmpty {
                    let parsed = Drill.parse(drill)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(parsed.title).font(.headline)
                        Text(parsed.goal)
                        if !parsed.why.isEmpty { Text(parsed.why).font(.caption).foregroundStyle(.secondary) }
                        Button {
                            model.startDrill(parsed)
                        } label: {
                            Label(model.activeDrill?.title == parsed.title ? "Drill running" : "Start drill (sends to Watch)",
                                  systemImage: "applewatch")
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.black)
                        .disabled(model.activeDrill?.title == parsed.title)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 10))
                }
            }
        } label: { Label("Coach", systemImage: "sparkles") }
    }

    private func ask(_ session: SessionRecord) {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !coach.isWorking else { return }
        question = ""
        Task { chat.append((q, await coach.answer(q, session: session))) }
    }

    private var museSettings: some View {
        @Bindable var coach = coach
        return GroupBox("Muse coach") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use your own Meta Model API key. Enabling Muse sends your question, session shot statistics and requested live shot data to Meta. Health data and session notes are excluded. API usage may incur charges.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Meta Model API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(coach.hasMuseKey ? "Replace key and enable Muse" : "Save key and enable Muse") {
                        do { try coach.saveMuseKey(apiKey); apiKey = ""; keyError = nil }
                        catch { keyError = error.localizedDescription }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coach.isWorking)
                    if coach.hasMuseKey {
                        Button("Remove key", role: .destructive) {
                            do { try coach.removeMuseKey(); keyError = nil }
                            catch { keyError = error.localizedDescription }
                        }.disabled(coach.isWorking)
                    }
                }
                Toggle("Use Muse online", isOn: $coach.museEnabled)
                    .disabled(!coach.hasMuseKey || coach.isWorking)
                Text("Your key stays in this device’s Keychain. With Muse off or unavailable, the built-in coach answers offline.")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = coach.lastFallbackReason {
                    Text("Using the built-in coach: \(reason)").font(.caption).foregroundStyle(.secondary)
                }
                if let keyError { Text(keyError).font(.caption).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
