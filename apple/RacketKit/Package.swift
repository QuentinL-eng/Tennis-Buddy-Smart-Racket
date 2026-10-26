// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RacketKit",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)],
    products: [
        .library(name: "RacketKit", targets: ["RacketKit"]),
    ],
    targets: [
        .target(name: "RacketKit"),
        .testTarget(name: "RacketKitTests", dependencies: ["RacketKit"]),
    ],
    swiftLanguageModes: [.v5]
)
