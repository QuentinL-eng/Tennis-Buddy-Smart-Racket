import Foundation
import SwiftData
#if os(macOS)
import Security
#endif

/// SwiftData store synced through the user's private iCloud database, so sessions recorded on the
/// iPhone show up on the Mac (and the other way round). Falls back to a local-only store when iCloud
/// isn't available (signed out, unsigned dev build), so the app always launches.
enum SyncedStore {
    static let containerID = "iCloud.com.quentinlynch.tennisbuddy"
    private(set) static var isSyncing = false

    static func makeContainer() -> ModelContainer {
        let schema = Schema([SessionRecord.self, ShotRecord.self])
        if canUseCloudKit, FileManager.default.ubiquityIdentityToken != nil,
           let container = try? ModelContainer(
               for: schema,
               configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .private(containerID))) {
            isSyncing = true
            return container
        }
        isSyncing = false
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
    }

    /// CloudKit can trap asynchronously in an unsigned Mac build, beyond Swift's error handling.
    private static var canUseCloudKit: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task,
                  "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              let services = SecTaskCopyValueForEntitlement(task,
                  "com.apple.developer.icloud-services" as CFString, nil) as? [String] else { return false }
        return containers.contains(containerID) && services.contains("CloudKit")
        #else
        return true
        #endif
    }

    static var statusText: String {
        if isSyncing { return "On: sessions sync between your iPhone and Mac" }
        if FileManager.default.ubiquityIdentityToken == nil { return "Off: sign in to iCloud to sync" }
        return "Off: iCloud isn't available for this build"
    }
}
