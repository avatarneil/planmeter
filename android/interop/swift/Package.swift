// swift-tools-version: 6.0
import PackageDescription

// Interop harness for the Kotlin protocol implementation. Depends on the
// repository's own PlanMeterRemote by path, so it always tests the Swift code
// in this checkout. macOS only (Network.framework listener).
let package = Package(
    name: "PlanMeterInterop",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "PlanMeter", path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "planmeter-interop",
            dependencies: [.product(name: "PlanMeterRemote", package: "PlanMeter")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
