import SwiftUI

/// Opaque sRGB colours stored independently of the scene and restored on every launch.
enum RacketSkin {
    static let defaultMain = "154C3B"
    static let defaultSecondary = "D6F240"

    static func color(_ hex: String) -> Color {
        let value = UInt32(hex, radix: 16) ?? 0x154C3B
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    static func hex(_ color: Color) -> String {
        #if os(macOS)
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        #endif
    }
}

struct RacketSkinView: View {
    @AppStorage("skin.enabled") private var enabled = false
    @AppStorage("skin.main") private var main = RacketSkin.defaultMain
    @AppStorage("skin.secondary") private var secondary = RacketSkin.defaultSecondary

    var body: some View {
        Form {
            Section {
                RacketSceneView().frame(height: 280)
                    .accessibilityLabel("Preview of your racket colours")
            }
            Section {
                Toggle("Custom colours", isOn: $enabled)
                ColorPicker("Main colour", selection: colour($main), supportsOpacity: false).disabled(!enabled)
                ColorPicker("Secondary colour", selection: colour($secondary), supportsOpacity: false).disabled(!enabled)
            } footer: {
                Text("Main colours the frame; secondary colours the dark trim. Your colours also appear on the Live screen.")
            }
            Section("Skins") {
                preset("Court green", "154C3B", "D6F240")
                preset("Midnight", "243047", "E8EDF5")
                preset("Clay", "C65B3D", "F4D4A4")
                preset("Electric", "6655E8", "5CF5D4")
                Button("Original racket") { enabled = false }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Racket skins")
    }

    private func colour(_ value: Binding<String>) -> Binding<Color> {
        Binding(get: { RacketSkin.color(value.wrappedValue) }, set: { value.wrappedValue = RacketSkin.hex($0) })
    }

    private func preset(_ name: String, _ primary: String, _ accent: String) -> some View {
        Button { main = primary; secondary = accent; enabled = true } label: {
            HStack {
                Circle().fill(RacketSkin.color(primary)).frame(width: 20, height: 20)
                Circle().fill(RacketSkin.color(accent)).frame(width: 20, height: 20)
                Text(name)
                Spacer()
                if enabled && main == primary && secondary == accent { Image(systemName: "checkmark") }
            }
        }
        .buttonStyle(.plain)
    }
}
