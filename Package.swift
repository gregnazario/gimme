// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "gimme",
    platforms: [.macOS(.v13)],
    targets: [
        // Vendored Lua 5.4 C library (no lua.c/luac.c main()).
        .target(
            name: "GimmeLua",
            path: "Sources/GimmeLua",
            exclude: ["include"],
            sources: ["lua54"],
            publicHeadersPath: "include",
            cSettings: [
                .define("LUA_USE_MACOSX"),
                .define("LUA_COMPAT_5_3"),
                .headerSearchPath("lua54"),
            ]
        ),
        // C glue: Lua API wrappers + ctx dispatch (uses a registered function-
        // pointer table, so it doesn't link against Swift symbols).
        .target(
            name: "CGimmeLuaSupport",
            dependencies: ["GimmeLua"],
            path: "Sources/CGimmeLuaSupport",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../GimmeLua/lua54"),
            ]
        ),
        .target(
            name: "GimmeCore",
            dependencies: ["GimmeLua", "CGimmeLuaSupport"],
            path: "Sources/GimmeCore"
        ),
        .executableTarget(
            name: "gimme",
            dependencies: ["GimmeCore"],
            path: "Sources/gimme"
        ),
        // Native macOS SwiftUI app — links GimmeCore directly.
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
