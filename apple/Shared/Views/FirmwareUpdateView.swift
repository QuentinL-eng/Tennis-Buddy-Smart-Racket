import RacketKit
import SwiftUI
import UniformTypeIdentifiers

/// Installs racket firmware over Bluetooth: the build bundled with the app, or a .bin picked from Files.
struct FirmwareUpdateSection: View {
    @Environment(AppModel.self) private var model
    let installed: String
    @State private var pickingFile = false
    @State private var pending: FirmwareImage?
    @State private var fileError: String?

    var body: some View {
        Section {
            status
            if !model.firmwareUpdate.isInProgress {
                if !model.racketSupportsFirmwareUpdate {
                    Text("This racket's firmware predates wireless updates. Flash it once over USB (firmware/README.md); after that, updates install from here.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    if let image = model.bundledFirmware, image.isNewer(than: installed), let version = image.version {
                        Button("Update to \(version)", systemImage: "arrow.down.circle") { pending = image }
                    } else if model.firmwareUpdate == .idle {
                        Text("Firmware \(installed) is the latest").foregroundStyle(.secondary)
                    }
                    Button("Install from file…", systemImage: "doc") { pickingFile = true }
                }
            }
        } header: {
            Text("Firmware update")
        } footer: {
            Text("Keep the racket close and charged, and this screen open; it takes about a minute. If the new firmware doesn't start, the racket goes back to the old one.")
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.data]) { result in
            fileError = nil
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { fileError = "Couldn't read that file"; return }
            let image = FirmwareImage(data: data, version: nil)
            if image.looksValid { pending = image } else { fileError = "That isn't an ESP32 firmware image (.bin)" }
        }
        .confirmationDialog("Install firmware?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { image in
            Button("Install") { model.ble.updateFirmware(image) }
        } message: { image in
            Text("Installs \(image.version.map { "firmware \($0)" } ?? "the selected file") (\(image.data.count / 1024) KB). The racket restarts when it's done.")
        }
    }

    @ViewBuilder private var status: some View {
        if let fileError {
            Label(fileError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        switch model.firmwareUpdate {
        case .idle:
            EmptyView()
        case .sending(let fraction):
            ProgressView(value: fraction) {
                Text("Sending firmware…")
            } currentValueLabel: {
                Text("\(Int(fraction * 100))%")
            }
            Button("Cancel", role: .destructive) { model.ble.cancelFirmwareUpdate() }
        case .verifying:
            ProgressView("Racket is checking the new firmware…")
        case .restarting:
            ProgressView("Racket is restarting…")
        case .finished:
            Label("Updated to \(installed)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
