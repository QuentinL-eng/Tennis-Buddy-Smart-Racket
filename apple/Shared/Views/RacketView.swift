import RacketKit
import SwiftUI

struct RacketView: View {
    @Environment(AppModel.self) private var model
    @State private var showCalibration = false
    @AppStorage(UnitSystem.storageKey) private var useMetric = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Connection") {
                Picker("Data source", selection: Binding(get: { model.sourceKind == .replay ? .simulator : model.sourceKind },
                                                         set: { model.select($0) })) {
                    Text("Racket").tag(SourceKind.racket)
                    Text("Simulator").tag(SourceKind.simulator)
                }
                .pickerStyle(.segmented)
                LabeledContent("Status", value: model.connectionLabel)
                LabeledContent("Sample rate", value: "\(Int(model.live.samplesPerSecond)) Hz")
                if let s = model.racketStatus {
                    LabeledContent("Battery", value: s.batteryMillivolts > 2500 ? String(format: "%.2f V", Double(s.batteryMillivolts) / 1000) : "Not wired")
                    LabeledContent("Firmware", value: s.firmwareVersion)
                    LabeledContent("Gyro (MPU6050)", value: s.mpuOK ? "OK" : "Not found")
                    LabeledContent("High-g (H3LIS331)", value: s.h3lisOK ? "OK" : "Not found")
                    LabeledContent("Dropped packets", value: "\(s.droppedPackets)")
                    Picker("High-g range", selection: Binding(get: { s.h3lisRange }, set: { model.ble.setHighGRange($0) })) {
                        Text("±100 g").tag(UInt8(0))
                        Text("±200 g").tag(UInt8(1))
                        Text("±400 g").tag(UInt8(3))
                    }
                }
            }

            Section {
                LabeledContent("Status", value: model.calibration.isCalibrated ? "Calibrated" : "Using CAD defaults")
                Button("Calibrate racket…", systemImage: "scope") { showCalibration = true }
                Button("Recenter 3D view", systemImage: "arrow.counterclockwise") { model.recenter() }
            } header: {
                Text("Calibration")
            } footer: {
                Text("Takes about 2 minutes: hold still, tip up, lay flat, then optional ball drops on a taped grid.")
            }

            Section {
                Toggle("Use metric units", isOn: $useMetric)
                LabeledContent("iCloud sync", value: SyncedStore.isSyncing ? "On" : "Off")
            } header: {
                Text("Settings")
            } footer: {
                Text("\(useMetric ? "km/h and cm" : "mph and inches"). iCloud sync: \(SyncedStore.statusText).")
            }

            Section("Racket & player") {
                TextField("Racket", text: $model.profile.name)
                Picker("Plays", selection: $model.profile.rightHanded) {
                    Text("Right-handed").tag(true)
                    Text("Left-handed").tag(false)
                }
                if useMetric {
                    measurement("Weight", value: $model.profile.massKg, scale: 1000, unit: "g")
                    measurement("Balance point", value: $model.profile.balancePointM, scale: 1000, unit: "mm")
                    measurement("String center", value: $model.profile.stringCenterM, scale: 1000, unit: "mm")
                    measurement("Swing radius", value: $model.profile.effectiveRadiusM, scale: 100, unit: "cm")
                } else {
                    measurement("Weight", value: $model.profile.massKg, scale: 35.274, unit: "oz", decimals: 1)
                    measurement("Balance point", value: $model.profile.balancePointM, scale: 39.3701, unit: "in", decimals: 2)
                    measurement("String center", value: $model.profile.stringCenterM, scale: 39.3701, unit: "in", decimals: 2)
                    measurement("Swing radius", value: $model.profile.effectiveRadiusM, scale: 39.3701, unit: "in", decimals: 1)
                }
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

    /// Number field showing `value × scale` in the chosen unit.
    private func measurement(_ label: String, value: Binding<Float>, scale: Double, unit: String,
                             decimals: Int = 0) -> some View {
        LabeledContent(label) {
            HStack {
                TextField(label, value: Binding(get: { Double(value.wrappedValue) * scale },
                                                set: { value.wrappedValue = Float($0 / scale) }),
                          format: .number.precision(.fractionLength(0...decimals)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .frame(maxWidth: 90)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
