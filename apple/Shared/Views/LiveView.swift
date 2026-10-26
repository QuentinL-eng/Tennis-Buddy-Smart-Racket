import RacketKit
import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var presenter = false
    @AppStorage(UnitSystem.storageKey) private var useMetric = false
    private var units: UnitSystem { UnitSystem(metric: useMetric) }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 820
            ScrollView {
                if wide {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 16) { racketPanel(height: geo.size.height * 0.62); drillBanner; sessionControls }
                            .frame(maxWidth: .infinity)
                        VStack(spacing: 16) { shotPanel; recentShots }
                            .frame(width: min(440, geo.size.width * 0.4))
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 16) {
                        racketPanel(height: 300)
                        drillBanner
                        sessionControls
                        shotPanel
                        recentShots
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Live")
        .toolbar {
            ToolbarItem { ConnectionPill() }
            ToolbarItem {
                Button("Recenter", systemImage: "scope") { model.recenter() }
                    .help("Point the 3D racket to the right")
            }
            #if os(macOS)
            ToolbarItem {
                Button("Presenter", systemImage: "rectangle.inset.filled.and.person.filled") { presenter = true }
            }
            #endif
        }
        #if os(macOS)
        .sheet(isPresented: $presenter) { PresenterView().frame(minWidth: 1100, minHeight: 750) }
        #endif
    }

    private func racketPanel(height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            RacketSceneView()
                .frame(height: max(260, height))
                .background(
                    LinearGradient(colors: [Color.accentColor.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom),
                    in: .rect(cornerRadius: 20))
            HStack(spacing: 14) {
                Label("\(Int(model.live.gyroDps)) °/s", systemImage: "gyroscope")
                Label(String(format: "%.1f g", model.live.highG), systemImage: "waveform.path.ecg")
                Label("\(Int(model.live.samplesPerSecond)) Hz", systemImage: "dot.radiowaves.left.and.right")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(12)
        }
    }

    @ViewBuilder private var drillBanner: some View {
        if let drill = model.activeDrill {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 6)
                    Circle().trim(from: 0, to: drill.progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.snappy, value: drill.completed)
                    if drill.isDone {
                        Image(systemName: "checkmark").font(.headline).foregroundStyle(.green)
                    } else {
                        Text("\(drill.remaining)").font(.headline.monospacedDigit())
                    }
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drill.isDone ? "Drill complete!" : drill.title).font(.headline)
                    Text(drill.goal).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(drill.isDone ? "Close" : "Stop", systemImage: "xmark.circle.fill") { model.cancelDrill() }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
            .padding(12)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
        }
    }

    private var sessionControls: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { model.isSessionActive ? model.stopSession() : model.startSession() }
            } label: {
                Label(model.isSessionActive ? "End Session" : "Start Session",
                      systemImage: model.isSessionActive ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isSessionActive ? .red : .accentColor)
            .foregroundStyle(model.isSessionActive ? .white : .black)
            .controlSize(.large)

            if model.isSessionActive {
                let summary = ShotSummary(model.sessionShots)
                HStack(spacing: 10) {
                    StatTile(label: "Shots", value: "\(summary.count)")
                    StatTile(label: "Sweet spot", value: "\(Int(summary.sweetSpotPercent))", unit: "%")
                    StatTile(label: "Avg ball", value: units.speedValue(summary.avgBallKmh), unit: units.speedUnit)
                    StatTile(label: "Best", value: units.speedValue(summary.maxBallKmh), unit: units.speedUnit)
                }
                if let start = model.activeSession?.startDate {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("Session time \(ctx.date.timeIntervalSince(start).clock)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var shotPanel: some View {
        if let shot = model.lastShot {
            ShotCardView(shot: shot, flashID: model.shotFlashID)
                .id(shot.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            ContentUnavailableView(
                "Swing away",
                systemImage: "tennis.racket",
                description: Text(model.isSessionActive
                                  ? "Every hit shows up here."
                                  : "Start a session to save shots. Hits still show up here."))
                .frame(maxWidth: .infinity, minHeight: 220)
                .background(.background.secondary, in: .rect(cornerRadius: 18))
        }
    }

    @ViewBuilder private var recentShots: some View {
        if model.sessionShots.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("This session").font(.headline)
                StringBedView(shots: model.sessionShots, highlight: model.lastShot)
                    .frame(maxHeight: 260)
                ForEach(model.sessionShots.suffix(6).reversed()) { s in
                    HStack {
                        Image(systemName: s.type.symbol).frame(width: 22)
                        Text(s.type.label)
                        Spacer()
                        Text(units.speedText(s.ballSpeedKmh)).monospacedDigit()
                        Circle().fill(s.isSweetSpot ? .green : .red).frame(width: 8, height: 8)
                    }
                    .font(.subheadline)
                }
            }
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 18))
        }
    }
}

struct ConnectionPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(SourceKind.allCases.filter { $0 != .replay }) { kind in
                Button(kind.label) { model.select(kind) }
            }
            if !model.recordings.isEmpty {
                Menu("Replay recording") {
                    ForEach(model.recordings, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.select(.replay, replay: url) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(model.isConnected ? .green : .orange).frame(width: 8, height: 8)
                Text(model.connectionLabel).lineLimit(1)
                if let mv = model.racketStatus?.batteryMillivolts, mv > 2500 {
                    Image(systemName: batterySymbol(mv))
                }
            }
            .font(.caption.weight(.medium))
        }
    }

    private func batterySymbol(_ mv: UInt16) -> String {
        switch mv {
        case 4000...: "battery.100"
        case 3800..<4000: "battery.75"
        case 3650..<3800: "battery.50"
        case 3500..<3650: "battery.25"
        default: "battery.0"
        }
    }
}

#if os(macOS)
/// Full-window view for showing judges on a projector.
struct PresenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 30) {
                RacketSceneView().frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 24) {
                    if let shot = model.lastShot {
                        ShotCardView(shot: shot, flashID: model.shotFlashID).scaleEffect(1.25).padding(40)
                    }
                    if model.sessionShots.count > 0 {
                        StringBedView(shots: model.sessionShots, highlight: model.lastShot).frame(height: 300)
                    }
                }
                .frame(width: 520)
            }
            .padding(30)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).padding()
        }
    }
}
#endif
