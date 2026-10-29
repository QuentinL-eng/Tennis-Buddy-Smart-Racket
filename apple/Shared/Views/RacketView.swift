import RacketKit
import SwiftUI

struct RacketView: View {
    @Environment(AppModel.self) private var model
    @State private var showCalibration = false
    @AppStorage(UnitSystem.storageKey) private var useMetric = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Your racket") {
                NavigationLink { RacketSkinView() } label: { Label("Racket skins", systemImage: "paintpalette") }
                #if os(iOS)
                NavigationLink { GlassesView() } label: { Label("Glasses", systemImage: "eyeglasses") }
                #endif
                NavigationLink { AccountView() } label: { Label("Account", systemImage: "person.crop.circle") }
            }

            Section("Connection") {
                Picker("Data source", selection: Binding(get: { model.sourceKind == .replay ? .simulator : model.sourceKind },
                                                         set: { model.select($0) })) {
                    Text("Racket").tag(SourceKind.racket)
                    Text("Simulator").tag(SourceKind.simulator)
                }
                .pickerStyle(.segmented)
                LabeledContent("Status", value: model.connectionLabel)
                if model.sourceKind == .racket {
                    Button("Forget this racket", systemImage: "link.badge.minus", role: .destructive) { model.ble.forgetRacket() }
                }
                LabeledContent("Sample rate", value: "\(Int(model.live.samplesPerSecond)) Hz")
                if let s = model.racketStatus {
                    LabeledContent("Battery", value: s.batteryMillivolts > 2500 ? String(format: "%.2f V", Double(s.batteryMillivolts) / 1000) : "Not wired")
                    LabeledContent("Firmware", value: s.firmwareVersion)
                    LabeledContent("IMU (LSM6DSV320X)", value: s.mpuOK && s.h3lisOK ? "OK" : "Not found")
                    LabeledContent("Dropped packets", value: "\(s.droppedPackets)")
                    Picker("High-g range", selection: Binding(get: { s.h3lisRange }, set: { model.ble.setHighGRange($0) })) {
                        Text("±100 g").tag(UInt8(0))
                        Text("±200 g").tag(UInt8(1))
                        Text("±400 g").tag(UInt8(3))
                    }
                }
            }

            if model.sourceKind == .racket, let s = model.racketStatus {
                FirmwareUpdateSection(installed: s.firmwareVersion)
            }

            Section {
                LabeledContent("Status", value: model.calibration.isCalibrated ? "Calibrated" : "Using CAD defaults")
                Button("Calibrate racket…", systemImage: "scope") { showCalibration = true }
                Button("Recenter 3D view", systemImage: "arrow.counterclockwise") { model.recenter() }
            } header: {
                Text("Calibration")
            } footer: {
                Text("Takes about 2 minutes: hold still, tip up, lay flat. Then optionally drop balls on a taped grid to score the racket's sweet-spot AI.")
            }

            Section {
                Toggle("Use metric units", isOn: $useMetric)
                LabeledContent("iCloud sync", value: SyncedStore.isSyncing ? "On" : "Off")
            } header: {
                Text("Settings")
            } footer: {
                Text("\(useMetric ? "km/h and cm" : "mph and inches"). iCloud sync: \(SyncedStore.statusText).")
            }

            Section {
                Picker("Active player", selection: $model.activePlayerID) {
                    ForEach(model.players) { Text($0.name).tag($0.id) }
                }
                .disabled(model.isSessionActive)
                if let index = model.players.firstIndex(where: { $0.id == model.activePlayerID }) {
                    TextField("Name", text: $model.players[index].name)
                    Picker("Plays", selection: $model.players[index].rightHanded) {
                        Text("Right-handed").tag(true)
                        Text("Left-handed").tag(false)
                    }
                    LabeledContent("Forehand") {
                        Text(model.players[index].forehandBodySign == nil ? "Not taught" : "Taught")
                            .foregroundStyle(.secondary)
                    }
                    if model.teachingForehand {
                        Text(model.teachMessage).font(.footnote).foregroundStyle(.secondary)
                        Button("Cancel teaching", role: .cancel) { model.cancelTeachingForehand() }
                    } else {
                        Button(model.players[index].forehandBodySign == nil ? "Teach forehand" : "Re-teach forehand",
                               systemImage: "figure.tennis") { model.beginTeachingForehand() }
                            .disabled(model.isSessionActive)
                        if model.players[index].forehandBodySign != nil {
                            Button("Forget forehand", role: .destructive) { model.clearTaughtForehand() }
                        }
                        if !model.teachMessage.isEmpty {
                            Text(model.teachMessage).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Height") {
                        HStack {
                            TextField("Height", text: heightText(for: model.players[index].id))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .frame(maxWidth: 90)
                            Text(useMetric ? "cm" : "in").foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Add player", systemImage: "person.badge.plus") { model.addPlayer() }
                    .disabled(model.isSessionActive)
                if model.players.count > 1 {
                    Button("Delete player", systemImage: "trash", role: .destructive) {
                        model.deletePlayer(model.activePlayerID)
                    }
                    .disabled(model.isSessionActive)
                }
            } header: {
                Text("Players")
            } footer: {
                Text("One racket, many players. Each session is tagged with the player who was active when it started.")
            }

            Section {
                Toggle("Record raw data", isOn: Binding(get: { model.isRecording }, set: { _ in model.toggleRecording() }))
                ForEach(model.recordings, id: \.self) { url in
                    HStack {
                        Text(url.deletingPathExtension().lastPathComponent).font(.callout.monospaced())
                        Spacer()
                        Button("Replay", systemImage: "play.circle") { model.select(.replay, replay: url) }
                            .labelStyle(.iconOnly)
                        if let csv = model.csvExport(for: url) {
                            ShareLink(item: csv) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
                .onDelete { idx in
                    idx.map { model.recordings[$0] }.forEach { try? FileManager.default.removeItem(at: $0) }
                    model.refreshRecordings()
                }
            } header: {
                Text("Recorder")
            } footer: {
                Text("Recordings replay as if the racket were live, so you can tune stats at a desk.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Racket")
        .sheet(isPresented: $showCalibration) {
            CalibrationView()
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 640)
                #endif
        }
    }

    /// Height shown in cm or inches, stored in meters. Empty until the player enters one.
    private func heightText(for id: UUID) -> Binding<String> {
        let scale = useMetric ? 100.0 : 39.3701
        return Binding(
            get: {
                guard let height = model.players.first(where: { $0.id == id })?.heightM else { return "" }
                return String(format: useMetric ? "%.0f" : "%.1f", Double(height) * scale)
            },
            set: { text in
                guard let index = model.players.firstIndex(where: { $0.id == id }) else { return }
                model.players[index].heightM = Double(text).map { Float($0 / scale) }
            }
        )
    }
}
