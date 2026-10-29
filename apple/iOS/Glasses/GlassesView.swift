import SwiftUI

/// Settings for the Meta Ray-Ban Display link (Racket tab → Glasses).
struct GlassesView: View {
    @Environment(GlassesController.self) private var glasses

    var body: some View {
        @Bindable var glasses = glasses
        Form {
            Section {
                LabeledContent("Meta AI app", value: registrationText)
                if let name = glasses.deviceName {
                    LabeledContent("Glasses", value: deviceText(name))
                }
                switch glasses.registration {
                case .registered:
                    Button("Disconnect from Meta AI", role: .destructive) { glasses.unregister() }
                case .available:
                    Button("Connect to Meta AI", systemImage: "eyeglasses") { glasses.register() }
                case .registering:
                    ProgressView()
                case .unavailable:
                    EmptyView()
                }
            } footer: {
                Text(glasses.configured
                     ? "Needs the Meta AI app with Developer Mode on for your glasses (Settings → Your glasses)."
                     : "The Meta glasses toolkit could not start.")
            }

            Section {
                Toggle("Show session on lens", isOn: $glasses.hudEnabled)
                LabeledContent("Lens", value: hudText)
                Button("Test on lens", systemImage: "eyeglasses") { glasses.reconnect() }
            } header: {
                Text("Live HUD")
            } footer: {
                Text("While a session runs, your lens shows the last shot, sweet-spot rate, score and drill progress. Tap End on the lens to finish the session.")
            }

            if glasses.needsFirmwareUpdate || glasses.needsGlassesAppUpdate {
                Section("Updates") {
                    if glasses.needsFirmwareUpdate {
                        Button("Update glasses software") { glasses.openFirmwareUpdate() }
                    }
                    if glasses.needsGlassesAppUpdate {
                        Button("Update Meta glasses app") { glasses.openGlassesAppUpdate() }
                    }
                }
            }

            if let error = glasses.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Glasses")
    }

    private var registrationText: String {
        switch glasses.registration {
        case .registered: "Connected"
        case .registering: "Connecting…"
        case .available: "Not connected"
        case .unavailable: "Unavailable"
        }
    }

    private func deviceText(_ name: String) -> String {
        glasses.deviceReady ? "\(name) · Ready" : "\(name) · Not connected"
    }

    private var hudText: String {
        switch glasses.hud {
        case .off: glasses.displayDevicePresent ? "Idle" : "No display glasses"
        case .connecting: "Connecting…"
        case .live: "Showing"
        }
    }
}
