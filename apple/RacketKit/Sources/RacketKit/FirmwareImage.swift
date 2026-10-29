import Foundation

/// Racket firmware the apps can install over BLE. firmware/tools/bundle_for_app.sh puts the current build
/// in the app as RacketFirmware.bin plus RacketFirmware.json ({ "version": "1.2" }).
public struct FirmwareImage: Sendable {
    public let data: Data
    /// Major.minor as the racket reports it; nil for a file picked by hand.
    public let version: String?

    public init(data: Data, version: String?) {
        self.data = Data(data)   // zero-based indices for chunking
        self.version = version
    }

    /// The image bundled with the app, if any.
    public static func bundled(in bundle: Bundle = .main) -> FirmwareImage? {
        guard let bin = bundle.url(forResource: "RacketFirmware", withExtension: "bin"),
              let json = bundle.url(forResource: "RacketFirmware", withExtension: "json"),
              let data = try? Data(contentsOf: bin),
              let meta = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: json)),
              let version = meta["version"] else { return nil }
        return FirmwareImage(data: data, version: version)
    }

    /// ESP32 app images start with magic byte 0xE9; catches picking the wrong file.
    public var looksValid: Bool { data.count > 1024 && data.first == 0xE9 }

    /// True if this image is newer than the racket's reported version ("1.10" is newer than "1.9").
    public func isNewer(than installed: String) -> Bool {
        guard let version else { return false }
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Standard CRC-32 (as zlib); the racket checks the received image against it.
    public var crc32: UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) }
        }
        return ~c
    }
}
