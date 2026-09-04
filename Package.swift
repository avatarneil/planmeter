// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlanMeter",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .executable(name: "PlanMeter", targets: ["PlanMeter"]),
        .library(name: "PlanMeterCore", targets: ["PlanMeterCore"]),
        .library(name: "PlanMeterRemote", targets: ["PlanMeterRemote"]),
        .library(name: "PlanMeterWatchShared", targets: ["PlanMeterWatchShared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(
            name: "PlanMeterCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Platform-neutral wire models, pairing, and the end-to-end encrypted
        // channel shared by the Mac server and the iOS companion.
        .target(
            name: "PlanMeterRemote",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The compact summary the iPhone relays to the watch; Foundation only.
        .target(
            name: "PlanMeterWatchShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PlanMeter",
            dependencies: [
                "PlanMeterCore",
                "PlanMeterRemote",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // The web client is copied into the .app by scripts/bundle.sh and
            // read from the source tree during `swift run`.
            exclude: ["Web"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                    .when(platforms: [.macOS])
                ),
            ]
        ),
        .executableTarget(
            name: "planmeter-cli",
            dependencies: ["PlanMeterCore"],
            path: "Sources/PlanMeterCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "planmeter-mcp",
            dependencies: ["PlanMeterCore"],
            path: "Sources/PlanMeterMCP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PlanMeterCoreTests",
            dependencies: ["PlanMeterCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PlanMeterRemoteTests",
            dependencies: ["PlanMeterRemote"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
