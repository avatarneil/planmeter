// swift-tools-version: 6.0
import PackageDescription

// Apple hosts build every target, exactly as before. Other hosts (Linux now,
// Windows later) build only the platform-neutral pieces: the core, the remote
// protocol, the watch payload, the CLI, the MCP server, and the host library and
// daemon (planmeterd).
//
// Keep the Apple branch's dependency list unchanged. Xcode Cloud builds the iOS
// app with automatic package resolution disabled, so any dependency change seen
// by an Apple host must also update all three checked-in Package.resolved files.
// Manifests are evaluated for the host, so `canImport(Darwin)` is true for every
// Apple build, including iOS and watchOS builds driven from a Mac.

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

#if canImport(Darwin)
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
]
// CryptoKit and the SDK's SQLite3 module ship with the OS.
let cryptoDependencies: [Target.Dependency] = []
let sqliteDependencies: [Target.Dependency] = []
let systemTargets: [Target] = []
#else
let dependencies: [Package.Dependency] = [
    // CryptoKit's API on non-Apple platforms. Pinned exactly, like Sparkle.
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
]
let cryptoDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
let sqliteDependencies: [Target.Dependency] = ["CSQLite"]
let systemTargets: [Target] = [
    // The system libsqlite3, standing in for the Apple SDK's SQLite3 module.
    .systemLibrary(
        name: "CSQLite",
        pkgConfig: "sqlite3",
        providers: [.apt(["libsqlite3-dev"]), .yum(["sqlite-devel"])]
    ),
]
#endif

// MARK: - Portable targets (every platform)

let portableProducts: [Product] = [
    .library(name: "PlanMeterCore", targets: ["PlanMeterCore"]),
    .library(name: "PlanMeterRemote", targets: ["PlanMeterRemote"]),
    .library(name: "PlanMeterWatchShared", targets: ["PlanMeterWatchShared"]),
    .library(name: "PlanMeterHost", targets: ["PlanMeterHost"]),
    .executable(name: "planmeterd", targets: ["planmeterd"]),
]

let portableTargets: [Target] = [
    .target(
        name: "PlanMeterCore",
        dependencies: sqliteDependencies + cryptoDependencies,
        swiftSettings: swift5,
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    // Platform-neutral wire models, pairing, and the end-to-end encrypted
    // channel shared by the Mac server and the iOS companion.
    .target(
        name: "PlanMeterRemote",
        dependencies: cryptoDependencies,
        swiftSettings: swift5
    ),
    // The compact summary the iPhone relays to the watch; Foundation only.
    .target(
        name: "PlanMeterWatchShared",
        swiftSettings: swift5
    ),
    // The host side shared by the Mac app and planmeterd: remote report
    // builder, pairing and RPC handling, Tailscale helpers, a POSIX HTTP
    // listener, and the headless engine and control API. Portable: no
    // Network.framework, AppKit, SwiftUI, or Observation.
    .target(
        name: "PlanMeterHost",
        dependencies: ["PlanMeterCore", "PlanMeterRemote"],
        swiftSettings: swift5
    ),
    // Headless host daemon for Linux (and macOS, for development).
    .executableTarget(
        name: "planmeterd",
        dependencies: ["PlanMeterHost", "PlanMeterCore", "PlanMeterRemote"],
        swiftSettings: swift5
    ),
    .executableTarget(
        name: "planmeter-cli",
        dependencies: ["PlanMeterCore"],
        path: "Sources/PlanMeterCLI",
        swiftSettings: swift5
    ),
    .executableTarget(
        name: "planmeter-mcp",
        dependencies: ["PlanMeterCore"],
        path: "Sources/PlanMeterMCP",
        swiftSettings: swift5
    ),
    .testTarget(name: "PlanMeterWatchSharedTests", dependencies: ["PlanMeterWatchShared"], swiftSettings: swift5),
    .testTarget(
        name: "PlanMeterCoreTests",
        dependencies: ["PlanMeterCore"] + sqliteDependencies,
        swiftSettings: swift5
    ),
    .testTarget(
        name: "PlanMeterRemoteTests",
        dependencies: ["PlanMeterRemote"] + cryptoDependencies,
        swiftSettings: swift5
    ),
    .testTarget(
        name: "PlanMeterHostTests",
        dependencies: ["PlanMeterHost", "PlanMeterCore", "PlanMeterRemote"],
        swiftSettings: swift5
    ),
]

// MARK: - Apple-only targets (SwiftUI, Charts, CloudKit, Sparkle)

#if canImport(Darwin)
let appleProducts: [Product] = [
    .executable(name: "PlanMeter", targets: ["PlanMeter"]),
    .library(name: "PlanMeterDesktopShared", targets: ["PlanMeterDesktopShared"]),
    .library(name: "PlanMeterWatchCloud", targets: ["PlanMeterWatchCloud"]),
]

let appleTargets: [Target] = [
    .target(name: "PlanMeterDesktopShared", swiftSettings: swift5),
    .target(name: "PlanMeterWatchCloud", dependencies: ["PlanMeterRemote", "PlanMeterWatchShared"], swiftSettings: swift5),
    .testTarget(name: "PlanMeterWatchCloudTests", dependencies: ["PlanMeterWatchCloud", "PlanMeterRemote", "PlanMeterWatchShared"], swiftSettings: swift5),
    .executableTarget(
        name: "PlanMeter",
        dependencies: [
            "PlanMeterDesktopShared",
            "PlanMeterCore",
            "PlanMeterRemote",
            "PlanMeterHost",
            .product(name: "Sparkle", package: "Sparkle"),
        ],
        // The web client is copied into the .app by scripts/bundle.sh and
        // read from the source tree during `swift run`.
        exclude: ["Web"],
        swiftSettings: swift5,
        linkerSettings: [
            .unsafeFlags(
                ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                .when(platforms: [.macOS])
            ),
        ]
    ),
    .testTarget(name: "PlanMeterDesktopSharedTests", dependencies: ["PlanMeterDesktopShared"], swiftSettings: swift5),
    .testTarget(
        name: "PlanMeterTests",
        dependencies: ["PlanMeter", "PlanMeterHost"],
        swiftSettings: swift5
    ),
]
#else
let appleProducts: [Product] = []
let appleTargets: [Target] = []
#endif

let package = Package(
    name: "PlanMeter",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: appleProducts + portableProducts,
    dependencies: dependencies,
    targets: portableTargets + appleTargets + systemTargets
)
