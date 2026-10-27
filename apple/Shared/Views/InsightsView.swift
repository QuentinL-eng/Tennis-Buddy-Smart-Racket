import Charts
import RacketKit
import SwiftData
import SwiftUI

/// Llama's take on one session, shown in the session detail.
struct CoachCard: View {
    @Bindable var session: SessionRecord
    @Environment(CoachModel.self) private var coach

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if session.coachSummary.isEmpty {
                    Text("Get a plain-language report on this session, generated on this device.")
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
                llamaStatus
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
                    ForEach(["What's my weakest stroke?", "Am I getting tired?", "How's my serve?"], id: \.self) { s in
                        Button(s) { question = s; ask(session) }.buttonStyle(.bordered).font(.caption)
                    }
                }
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
        guard !q.isEmpty else { return }
        question = ""
        Task { chat.append((q, await coach.answer(q, session: session))) }
    }

    private var llamaStatus: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On-device AI: Meta Llama 3.2 3B").font(.headline)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if coach.state == .notLoaded || { if case .failed = coach.state { return true } else { return false } }() {
                    Button("Load Llama") { Task { await coach.loadLlama() } }
                }
                if case .downloading(let p) = coach.state { ProgressView(value: p).frame(width: 120) }
            }
        }
    }

    private var statusText: String {
        switch coach.state {
        case .notLoaded: "Runs fully offline on this device. Until it's loaded, the built-in coach answers."
        case .downloading(let p): "Downloading model… \(Int(p * 100))%"
        case .loading: "Loading model…"
        case .ready: "Ready. Answers are generated on this device."
        case .failed(let msg): "Couldn't load: \(msg)"
        }
    }
}
