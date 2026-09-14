// swift-tools-version: 6.2
import PackageDescription

// Strictness layer on top of Swift 6 language mode (which already enforces
// complete concurrency checking): upcoming features that will become the
// default in future language modes, adopted now so drift surfaces at build
// time. Deliberately NOT enabled: NonisolatedNonsendingByDefault — that one
// changes runtime behavior (nonisolated async work would run on the caller's
// actor), not just checking strictness.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "gimme",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "GimmeCore",
            path: "Sources/GimmeCore",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "gimme",
            dependencies: ["GimmeCore"],
            path: "Sources/gimme",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "GimmeUI",
            dependencies: ["GimmeCore"],
            path: "Sources/GimmeUI",
            resources: [
                .process("Resources")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "GimmeTests",
            dependencies: ["GimmeCore"],
            path: "Tests/GimmeTests",
            exclude: ["Fixtures"],
            swiftSettings: swiftSettings)
    ]
)
