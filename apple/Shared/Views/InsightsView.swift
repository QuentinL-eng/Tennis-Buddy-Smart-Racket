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

// MARK: - Views

struct InsightsView: View {
    @Query(sort: \SessionRecord.startDate) private var records: [SessionRecord]
    @AppStorage(UnitSystem.storageKey) private var useMetric = false
    @State private var period = InsightPeriod.month
    @State private var stroke: ShotType?
    @State private var metric = InsightMetric.ballSpeed
    private var units: UnitSystem { UnitSystem(metric: useMetric) }

    private var sessions: [InsightSession] {
        records.filter { $0.summary.count > 0 }.map {
            InsightSession(id: $0.id, date: $0.startDate, duration: $0.duration,
                           averageHeartRate: $0.averageHeartRate, shots: $0.shots)
        }
    }

    private var model: InsightsModel {
        InsightsModel(sessions: sessions, period: period, stroke: stroke, metric: metric, units: units)
    }

    private let strokes: [ShotType?] = [nil, .forehand, .backhand, .serve, .volley]

    var body: some View {
        ScrollView {
            if sessions.isEmpty {
                ContentUnavailableView("No data yet", systemImage: "chart.xyaxis.line",
                                       description: Text("Play a session and your trends show up here."))
            } else {
                let m = model
                VStack(alignment: .leading, spacing: 20) {
                    strokeChips
                    metricTabs(m)
                    summary(m)
                    chart(m)
                    byStroke(m)
                    recent(m)
                    coachRow
                }
                .padding()
            }
        }
        .navigationTitle("Insights")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Period", selection: $period) {
                        ForEach(InsightPeriod.allCases) { Text($0.label).tag($0) }
                    }
                } label: { Label(period.label, systemImage: "chevron.down").labelStyle(.titleAndIcon) }
            }
        }
        .onChange(of: records.count) { _, _ in if !model.hasHeartRate && metric == .heartRate { metric = .ballSpeed } }
    }

    private var strokeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(strokes, id: \.self) { s in
                    let on = stroke == s
                    Button { stroke = s } label: {
                        Text(s?.label ?? "All")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).frame(minHeight: 44)
                            .foregroundStyle(on ? Color.black : Color.primary)
                            .background(on ? Color.accentColor : .clear, in: .capsule)
                            .overlay(Capsule().stroke(on ? .clear : Color.secondary.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private func metricTabs(_ m: InsightsModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(InsightMetric.allCases.filter { $0 != .heartRate || m.hasHeartRate }) { t in
                    Button { metric = t } label: {
                        VStack(spacing: 6) {
                            Text(t.label).font(.headline)
                                .foregroundStyle(metric == t ? Color.primary : Color.secondary)
                            Rectangle().fill(metric == t ? Color.accentColor : .clear).frame(height: 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(metric == t ? .isSelected : [])
                }
            }
        }
    }

    private func format(_ v: Double) -> String {
        switch metric {
        case .ballSpeed, .swingSpeed, .spin, .shots, .heartRate, .sweetSpot: String(format: "%.0f", v)
        case .face, .path, .contact: String(format: "%.1f", v)
        }
    }

    private func summary(_ m: InsightsModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let avg = m.periodAverage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(format(avg)).font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(metric.unit(units)).font(.title3).foregroundStyle(.secondary)
                }
                if m.points.count > 1, let d = m.delta { deltaPill(d) }
                if let top = m.top, let low = m.low {
                    Text("Top \(format(top)) · Low \(format(low)) · vs previous period")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("No data").font(.title2.bold()).foregroundStyle(.secondary)
            }
        }
    }

    private func deltaPill(_ d: Double) -> some View {
        let better: Bool? = {
            guard abs(d) >= 0.05, let dir = metric.betterDirection else { return nil }
            if dir == 0 { return nil }
            return (d > 0) == (dir > 0)
        }()
        let arrow = d > 0 ? "▲" : (d < 0 ? "▼" : "–")
        let word = better == true ? "better" : (better == false ? "worse" : "change")
        let color: Color = better == true ? Color(red: 0.37, green: 0.86, blue: 0.54)
            : (better == false ? Color(red: 1, green: 0.6, blue: 0.55) : .secondary)
        return Text("\(arrow) \(format(abs(d))) \(word)")
            .font(.subheadline.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.18), in: .capsule)
    }

    @ViewBuilder private func chart(_ m: InsightsModel) -> some View {
        let pts = m.points
        card {
            if pts.isEmpty {
                Text(stroke.map { "No \($0.label.lowercased()) shots in this period" } ?? "No shots in this period")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else if metric == .shots {
                Chart(pts) { p in
                    BarMark(x: .value("Session", p.date, unit: .day), y: .value("Shots", p.avg))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(height: 210)
            } else {
                Chart(pts) { p in
                    if metric.isPerShot {
                        RuleMark(x: .value("Session", p.date, unit: .day),
                                 yStart: .value("Low", p.low), yEnd: .value("High", p.high))
                            .lineStyle(StrokeStyle(lineWidth: 16, lineCap: .round))
                            .foregroundStyle(Color.accentColor.opacity(0.28))
                    }
                    PointMark(x: .value("Session", p.date, unit: .day), y: .value("Average", p.avg))
                        .symbolSize(90).foregroundStyle(Color.accentColor)
                }
                .chartYAxisLabel(metric.unit(units))
                .frame(height: 210)
            }
        }
    }

    @ViewBuilder private func byStroke(_ m: InsightsModel) -> some View {
        let rows = m.byStroke
        if stroke == nil, !rows.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("By stroke").font(.headline)
                    Chart(rows, id: \.type) { r in
                        BarMark(x: .value("Average", r.avg), y: .value("Stroke", r.type.label))
                            .foregroundStyle(Color.accentColor)
                            .annotation(position: .trailing) { Text(format(r.avg)).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(height: CGFloat(rows.count) * 40 + 20)
                }
            }
        }
    }

    private func recent(_ m: InsightsModel) -> some View {
        let last = Array(records.filter { $0.summary.count > 0 }.suffix(3).reversed())
        return VStack(alignment: .leading, spacing: 10) {
            Text("Sessions").font(.headline)
            ForEach(last) { s in
                NavigationLink { SessionDetailView(session: s) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.startDate.formatted(.dateTime.weekday().day().month())).font(.subheadline.weight(.semibold))
                            Text("\(s.summary.count) shots · \(Duration.seconds(s.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Avg \(units.speedText(s.summary.avgBallKmh))").font(.subheadline)
                            Text("Top \(units.speedText(s.summary.maxBallKmh))").font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(.background.secondary, in: .rect(cornerRadius: 18))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var coachRow: some View {
        NavigationLink { CoachScreen() } label: {
            HStack {
                Label("Coach", systemImage: "sparkles").font(.headline)
                Spacer()
                Text("Ask, test what-ifs, plan drills").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().padding(16).background(.background.secondary, in: .rect(cornerRadius: 22))
    }
}

/// Coach chat, drill planner and coach engine settings, pushed from the Insights page.
struct CoachScreen: View {
    @Query(sort: \SessionRecord.startDate) private var sessions: [SessionRecord]
    @Environment(CoachModel.self) private var coach
    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var chat: [(q: String, a: String)] = []
    @State private var drill = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                toolRow("What if", "slider.horizontal.3", "Test a technique change on your swing") { WhatIfView() }
                toolRow("Memory", "brain", "What the coach remembers about you") { MemoryView() }
                if let latest = sessions.last(where: { $0.summary.count > 0 }) { coachChat(latest) }
                museSettings
            }
            .padding()
        }
        .navigationTitle("Coach")
    }

    private func toolRow<D: View>(_ title: String, _ symbol: String, _ detail: String,
                                  @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func coachChat(_ session: SessionRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ask about your latest session").font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(chat.enumerated()), id: \.offset) { index, item in
                    Text(item.q).font(.subheadline.weight(.semibold))
                    Text(item.a).textSelection(.enabled)
                    if index == chat.count - 1 { RememberedNotes() }
                    Divider()
                }
                HStack {
                    TextField("How was my backhand?", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { ask(session) }
                    Button("Ask", systemImage: "paperplane.fill") { ask(session) }
                        .disabled(question.isEmpty || coach.isWorking)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(["What's my weakest stroke?", "Am I getting tired?", "Show my last 5 off-center hits",
                                 "Is the racket working right?", "What if I swing 5% slower?"], id: \.self) { s in
                            Button(s) { question = s; ask(session) }.buttonStyle(.bordered).font(.caption)
                        }
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
        return GroupBox("Coach engine") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Use Muse online", isOn: $coach.museEnabled)
                    .disabled(!coach.museAvailable || coach.isWorking)
                Text(coach.museAvailable
                     ? "Muse sends your question and the shot data, racket readings and coach notes it asks for to Meta. Health data and session notes are excluded; turn off coach notes under Memory."
                     : "Sign in under Account to use the online coach. Until then the built-in coach answers offline.")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = coach.lastFallbackReason {
                    Text("Using the built-in coach: \(reason)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
