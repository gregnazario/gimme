// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "gimme",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "GimmeCore",
            path: "Sources/GimmeCore"
        ),
        .executableTarget(
            name: "gimme",
            dependencies: ["GimmeCore"],
            path: "Sources/gimme"
        ),
        .executableTarget(
            name: "GimmeUI",
            dependencies: ["GimmeCore"],
            path: "Sources/GimmeUI",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "GimmeTests",
            dependencies: ["GimmeCore"],
            path: "Tests/GimmeTests",
            exclude: ["Fixtures"])
    ]
)
