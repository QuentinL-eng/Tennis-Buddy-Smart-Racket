// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RacketKit",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)],
    products: [
        .library(name: "RacketKit", targets: ["RacketKit"]),
    ],
    targets: [
        .target(name: "RacketKit", exclude: [
            "Protocol.sync-conflict-20261027-201221-GC6FYOE.swift",
            "Protocol.sync-conflict-20261027-204342-GC6FYOE.swift",
            "RacketBLE.sync-conflict-20261027-201221-GC6FYOE.swift",
            "RacketBLE.sync-conflict-20261027-204346-GC6FYOE.swift",
        ]),
        .testTarget(name: "RacketKitTests", dependencies: ["RacketKit"]),
    ],
    swiftLanguageModes: [.v5]
)
