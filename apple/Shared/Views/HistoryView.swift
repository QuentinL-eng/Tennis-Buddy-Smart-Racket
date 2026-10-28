import Charts
import RacketKit
import SwiftData
import SwiftUI

struct HistoryView: View {
    @Query(sort: \SessionRecord.startDate, order: .reverse) private var sessions: [SessionRecord]
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { s in
                    NavigationLink { SessionDetailView(session: s) } label: { SessionRow(session: s) }
                }
                .onDelete { idx in idx.map { sessions[$0] }.forEach(context.delete) }
            }
            .navigationTitle("History")
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView("No sessions yet", systemImage: "clock",
                                           description: Text("Start a session on the Live tab."))
                }
            }
        }
    }
}

struct SessionRow: View {
    var session: SessionRecord

    var body: some View {
        let summary = session.summary
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.headline)
            HStack(spacing: 12) {
                if !session.playerName.isEmpty { Label(session.playerName, systemImage: "person") }
                Label("\(summary.count)", systemImage: "tennisball")
                Label("\(Int(summary.sweetSpotPercent))%", systemImage: "scope")
                Label(session.duration.clock, systemImage: "timer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct SessionDetailView: View {
    @Bindable var session: SessionRecord
    @AppStorage(UnitSystem.storageKey) private var useMetric = false
    private var units: UnitSystem { UnitSystem(metric: useMetric) }
    @Environment(CoachModel.self) private var coach
    @State private var strokeFilter: ShotType?
    @State private var heatMap = true

    var body: some View {
        let all = session.shots.filter { $0.type != .calibration }
        let shots = strokeFilter.map { f in all.filter { $0.type == f } } ?? all
        let summary = ShotSummary(shots)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    StatTile(label: "Shots", value: "\(summary.count)", symbol: "tennisball")
                    StatTile(label: "Sweet spot", value: "\(Int(summary.sweetSpotPercent))", unit: "%", symbol: "scope")
                    StatTile(label: "Avg ball", value: units.speedValue(summary.avgBallKmh), unit: units.speedUnit, symbol: "speedometer")
                    StatTile(label: "Top ball", value: units.speedValue(summary.maxBallKmh), unit: units.speedUnit, symbol: "flame")
                    StatTile(label: "Avg swing", value: units.speedValue(summary.avgSwingKmh), unit: units.speedUnit, symbol: "wind")
                    StatTile(label: "Avg spin", value: "\(Int(summary.avgSpinRPM))", unit: "rpm", symbol: "arrow.clockwise")
                    if session.averageHeartRate > 0 {
                        StatTile(label: "Avg heart rate", value: "\(Int(session.averageHeartRate))", unit: "bpm", symbol: "heart")
                        StatTile(label: "Calories", value: "\(Int(session.activeCalories))", unit: "kcal", symbol: "flame")
                    }
                    if session.pointsWon + session.pointsLost > 0 {
                        StatTile(label: "Points", value: "\(session.pointsWon)–\(session.pointsLost)", symbol: "trophy")
                    }
                }

                CoachCard(session: session)

                GroupBox("Shot mix") {
                    Chart(ShotType.allCases.filter { $0 != .calibration }) { t in
                        BarMark(x: .value("Shots", all.filter { $0.type == t }.count), y: .value("Type", t.label))
                            .foregroundStyle(Color.accentColor.gradient)
                            .annotation(position: .trailing) {
                                Text("\(all.filter { $0.type == t }.count)").font(.caption).foregroundStyle(.secondary)
                            }
                    }
                    .frame(height: 150)
                }

                GroupBox {
                    VStack(spacing: 12) {
                        Picker("Stroke", selection: $strokeFilter) {
                            Text("All").tag(ShotType?.none)
                            ForEach(ShotType.allCases.filter { $0 != .calibration }) { Text($0.label).tag(ShotType?.some($0)) }
                        }
                        .pickerStyle(.segmented)
                        StringBedView(shots: shots, heatMap: heatMap).frame(maxHeight: 360)
                        Toggle("Heat map", isOn: $heatMap)
                        if summary.count > 1 {
                            Text("Average contact \(units.lengthText(abs(summary.avgImpactY))) \(summary.avgImpactY >= 0 ? "toward the tip" : "toward the throat") and \(units.lengthText(abs(summary.avgImpactX))) \(summary.avgImpactX >= 0 ? "right of" : "left of") the sweet spot · spread \(units.lengthText(summary.impactSpreadCm))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } label: { Text("Where you hit") }

                if shots.count > 2 {
                    GroupBox("Speed through the session") {
                        Chart(Array(shots.enumerated()), id: \.offset) { i, s in
                            PointMark(x: .value("Shot", i + 1), y: .value("Ball speed", units.speed(s.ballSpeedKmh)))
                                .foregroundStyle(s.isSweetSpot ? Color.green : Color.red)
                            LineMark(x: .value("Shot", i + 1), y: .value("Ball speed", units.speed(s.ballSpeedKmh)))
                                .foregroundStyle(.secondary.opacity(0.3))
                        }
                        .chartYAxisLabel(units.speedUnit)
                        .frame(height: 180)
                    }
                }

                GroupBox("Shots") {
                    ForEach(Array(shots.reversed())) { s in
                        NavigationLink { ShotDetailView(shot: s, average: summary) } label: {
                            HStack {
                                Image(systemName: s.type.symbol).frame(width: 22)
                                VStack(alignment: .leading) {
                                    Text(s.type.label)
                                    Text(s.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(units.speedText(s.ballSpeedKmh)) · \(Int(s.spinRPM)) rpm").monospacedDigit().font(.subheadline)
                                Circle().fill(s.isSweetSpot ? .green : .red).frame(width: 8, height: 8)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .padding()
        }
        .navigationTitle(session.title)
    }
}

struct ShotDetailView: View {
    var shot: ShotMetrics
    var average: ShotSummary
    @AppStorage(UnitSystem.storageKey) private var useMetric = false
    private var units: UnitSystem { UnitSystem(metric: useMetric) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ShotCardView(shot: shot, flashID: shot.id)
                GroupBox("Compared with this session's average") {
                    Grid(alignment: .leading, verticalSpacing: 8) {
                        row("Ball speed", units.speed(shot.ballSpeedKmh), units.speed(average.avgBallKmh), units.speedUnit)
                        row("Swing speed", units.speed(shot.swingSpeedKmh), units.speed(average.avgSwingKmh), units.speedUnit)
                        row("Spin", shot.spinRPM, average.avgSpinRPM, "rpm")
                        row("Swing path", shot.swingPathDeg, average.avgPathAngle, "°")
                        row("Face angle", shot.faceAngleDeg, average.avgFaceAngle, "°")
                    }
                }
                GroupBox("Contact") {
                    StringBedView(shots: [shot], highlight: shot).frame(height: 260)
                    Text("\(units.lengthText(shot.impactDistanceCm)) from the sweet spot · peak \(Int(shot.peakG)) g at the handle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(shot.type.label)
    }

    private func row(_ label: String, _ v: Double, _ avg: Double, _ unit: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text("\(Int(v.rounded())) \(unit)").monospacedDigit()
            let d = v - avg
            Text("\(d >= 0 ? "+" : "")\(Int(d.rounded()))").monospacedDigit()
                .foregroundStyle(abs(d) < 1 ? Color.secondary : (d > 0 ? Color.green : Color.orange))
        }
    }
}
