import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    metrics
                    flightPanel
                    if !camera.detail.isEmpty {
                        Text(camera.detail)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 14) {
                    captureControls
                    detectorControls
                    snapshotPanel
                    Spacer(minLength: 0)
                }
                .frame(width: 300, alignment: .leading)
            }
            .padding(22)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            camera.updateRotation()
            // Lets a cable/Wi-Fi test run start capture without a tap:
            //   DEVICECTL_CHILD_TENNISCAMERA_AUTOSTART=1 \
            //     devicectl device process launch ... com.tennisrobot.camera
            // (-TennisCameraAutoStart YES also works from an Xcode scheme.)
            let environment = ProcessInfo.processInfo.environment["TENNISCAMERA_AUTOSTART"] == "1"
            if environment || UserDefaults.standard.bool(forKey: "TennisCameraAutoStart") {
                camera.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { camera.stop() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("TennisCamera")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Text(camera.format.summary)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            connectionBadge
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(camera.connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(camera.connected ? "client" : "listening")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Metrics

    private var metrics: some View {
        let snapshot = camera.stats
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                MetricTile(label: "capture", value: String(format: "%.1f", snapshot.captureFPS), unit: "fps")
                MetricTile(label: "detector", value: String(format: "%.2f", snapshot.detectorMedianMs), unit: "ms med")
                MetricTile(label: "detector", value: String(format: "%.2f", snapshot.detectorP95Ms), unit: "ms p95")
            }
            GridRow {
                MetricTile(label: "packets", value: String(format: "%.1f", snapshot.packetRate), unit: "/s")
                MetricTile(label: "dropped", value: "\(snapshot.droppedFrames)", unit: "frames")
                MetricTile(label: "thermal", value: camera.thermalText, unit: "")
            }
            GridRow {
                MetricTile(label: "sequence", value: "\(snapshot.sequence)", unit: "")
                MetricTile(label: "detections", value: "\(snapshot.detections)", unit: "")
                MetricTile(label: "latest u,v", value: snapshot.lastUV, unit: "")
            }
        }
    }

    // MARK: 3D flight

    private var flightPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("3D flight")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(camera.flight == nil ? "no fit" : "tracking")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(camera.flight == nil ? Color.secondary : Color.green)
            }
            if let flight = camera.flight {
                row("position", String(
                    format: "%.2f  %.2f  %.2f m",
                    flight.state.position.x, flight.state.position.y, flight.state.position.z
                ))
                row("speed", String(format: "%.1f m/s", flight.state.speed))
                if let point = flight.intercept, let seconds = flight.interceptTimeS {
                    row("intercept", String(
                        format: "%.2f  %.2f m  in %.0f ms", point.x, point.y, seconds * 1000
                    ))
                } else {
                    row("intercept", "none — not closing on the plane")
                }
                row("fit", String(format: "rms %.1f px   %d obs", flight.rmsPx, flight.observations))
            } else {
                row("state", camera.isRunning ? "waiting for a flight" : "idle")
            }
            row("gravity", camera.gravityText)
            Text("Camera frame: x right, y down, z forward. Intercept is the crossing of z = 1.00 m; the PC rotates it into court coordinates.")
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.system(.caption, design: .monospaced))
    }

    // MARK: Controls

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if camera.isRunning { camera.stop() } else { camera.start() }
            } label: {
                Text(camera.isRunning ? "Stop" : "Start capture")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(camera.isRunning ? .red : .green)

            if let error = camera.serverError {
                Text("port 5000: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detectorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Ball detector", isOn: $camera.detectorEnabled)
            Toggle("Strike-zone ROI", isOn: $camera.strikeZoneROI)
            Text("u/v increase right and down in the delivered frame; the ROI only limits the scan, coordinates stay full-frame.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .tint(.green)
    }

    private var snapshotPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("Snapshot") { camera.takeSnapshot() }
                    .buttonStyle(.bordered)
                    .disabled(!camera.isRunning)
                Button("Save to Photos") { camera.saveSnapshotToPhotos() }
                    .buttonStyle(.bordered)
                    .disabled(camera.lastSnapshot == nil)
            }
            .font(.footnote)

            if let image = camera.lastSnapshot {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(camera.snapshotNote.isEmpty
                 ? "Save a frame at the runtime format for checkerboard calibration."
                 : camera.snapshotNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MetricTile: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 118, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    ContentView()
}
