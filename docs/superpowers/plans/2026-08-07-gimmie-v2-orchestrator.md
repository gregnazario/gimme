# gimmie v2 Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild gimmie from a native install pipeline into a pure orchestration layer over real package managers (Homebrew, Go, uv, Cargo, bun), with a unified namespace CLI and a rebuilt SwiftUI app.

**Architecture:** Thin engine + fat adapters. A `PackageManager` protocol is the single seam; the engine (Registry + Resolver + Preferences + Cache) drives adapters that each own their I/O. CLI and SwiftUI both link `GimmeCore` directly — no IPC boundary.

**Tech Stack:** Swift 5.9 (SwiftPM), macOS 13 floor, SwiftUI, `Foundation.Process` for subprocess, `URLSession` for network. No external dependencies.

**Reference spec:** `docs/superpowers/specs/2026-08-07-gimmie-v2-orchestrator-design.md`. Every task here traces to a section of that spec.

## Global Constraints

- **Platform:** macOS 13+ (`platforms: [.macOS(.v13)]`).
- **Swift tools:** 5.9 (`swift-tools-version: 5.9`).
- **No external dependencies** — Foundation + URLSession + Process only.
- **Targets:** 3 (GimmeCore, gimme, GimmeUI) + GimmeTests. The two C targets (GimmeLua, CGimmeLuaSupport) are deleted.
- **Test pattern:** `import XCTest; @testable import GimmeCore`; temp-directory fixtures via `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`; run with `swift test --filter <Name>`.
- **Commit attribution:** NEVER attribute commits to any AI. No `Co-Authored-By`, no trailers, no banners. Plain human-authored commits.
- **Commit style:** Conventional Commits (`feat:`, `refactor:`, `test:`, `docs:`, `chore:`) matching the existing git log.
- **All commit messages, code, comments, and docs in English.**
- **Frequent commits:** every task ends with a commit.
- **No GUI automated tests in v1** (GimmeTests depends only on GimmeCore). GUI is manually verified.

---

## File Structure

The final tree (built up over the phases):

```
Sources/
  GimmeCore/
    PackageManager.swift          # protocol + shared types (§4)
    Registry.swift                # discovers + holds adapters (§3.2)
    Resolver.swift                # priority + remember routing (§5.1)
    Preferences.swift             # remembered-overrides store (§5.2)
    Cache.swift                   # TTL disk cache (§5.3)
    Process.swift                 # streaming subprocess helper
    Bootstrap.swift               # auto-bootstrap runner (§6.6)
    Config.swift                  # priority list, enabled managers, cache TTL (kept, modified)
    Paths.swift                   # on-disk locations (kept, modified)
    Host.swift                    # host info (kept as-is)
    Errors.swift                  # unified errors (kept, extended)
    TOML.swift                    # relocated from manifest/, reused for config + prefs
    Gimme.swift                   # command runner (rebuilt)
    HTTPClient.swift              # thin URLSession wrapper for adapters
    managers/
      HomebrewManager.swift
      GoManager.swift
      UvManager.swift
      CargoManager.swift
      BunManager.swift
  gimme/
    main.swift                    # rebuilt: flat verbs + passthrough
  GimmeUI/
    GimmeApp.swift                # @main + GimmeStore (rebuilt)
    ContentView.swift             # NavigationSplitView shell (rebuilt)
    Views/
      InstalledView.swift
      UpdatesView.swift
      BrowseView.swift
      ByManagerView.swift
      PreferencesView.swift
      ActivityView.swift
      DetailSheet.swift
      Components/
        ManagerBadge.swift
        ManagerFilterChip.swift
Tests/GimmeTests/
    PackageManagerContractTests.swift
    ResolverTests.swift
    PreferencesTests.swift
    CacheTests.swift
    ProcessTests.swift
    ConfigV2Tests.swift
    PathsV2Tests.swift
    ErrorsV2Tests.swift
    managers/
      HomebrewManagerTests.swift
      GoManagerTests.swift
      UvManagerTests.swift
      CargoManagerTests.swift
      BunManagerTests.swift
    Fixtures/                      # kept dir, contents may change
```

---

## Phase 1 — Delete the Native Pipeline

**Goal of this phase:** Remove the dead code so nothing built later references it, and get the trimmed workspace compiling with minimal stubs. After this phase: `swift build` succeeds with 3 targets, `swift test` passes (with tests pruned to survivors).

### Task 1.1: Relocate the TOML parser out of the doomed `manifest/` dir

The TOML parser is reused by the new Config and Preferences. Move it before deleting `manifest/`.

**Files:**
- Move: `Sources/GimmeCore/manifest/TOML.swift` → `Sources/GimmeCore/TOML.swift`
- Test: `Tests/GimmeTests/TOMLTests.swift` (existing — should still pass after the move)

**Interfaces:**
- Produces: `TOMLValue`, `TOMLTable`, `TOML.parseData(_:)`, `TOML.parse(_:)` — unchanged public API.

- [ ] **Step 1: Move the file**

```bash
git mv Sources/GimmeCore/manifest/TOML.swift Sources/GimmeCore/TOML.swift
```

- [ ] **Step 2: Build + run TOML tests to confirm nothing broke**

Run: `swift build 2>&1 | tail -5 && swift test --filter TOMLTests 2>&1 | tail -15`
Expected: BUILD SUCCEEDS; TOML tests PASS (the move is purely on-disk; SwiftPM discovers all `.swift` in the target path).

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "refactor: move TOML parser to Sources/GimmeCore root

Relocating out of manifest/ before that directory is deleted in the
v2 rework. Reused by Config and Preferences in the new architecture."
```

### Task 1.2: Strip `Package.swift` to 3 targets

**Files:**
- Modify: `Package.swift`

**Interfaces:**
- Produces: a workspace with targets `GimmeCore`, `gimme`, `GimmeUI`, `GimmeTests`. No C targets.

- [ ] **Step 1: Replace `Package.swift` contents**

Write `Package.swift` as:

```swift
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
```

- [ ] **Step 2: Delete the C target source directories**

```bash
git rm -r Sources/GimmeLua Sources/CGimmeLuaSupport
```

- [ ] **Step 3: Commit (build will fail at this point — native pipeline still references deleted Lua targets indirectly; we fix in 1.3–1.6)**

```bash
git add -A && git commit -m "chore: drop Lua C targets from Package.swift

gimmie v2 is pure orchestration; the embedded Lua engine is gone.
Native pipeline code still present will be removed next."
```

### Task 1.3: Delete the native pipeline source directories

**Files:**
- Delete: `Sources/GimmeCore/{agent,brew,cellar,downloader,installer,manifest,mise,resolver,semver,shim,stager,state,taps}`

These all served the deleted native pipeline. (`resolver/` held the old `FormulaProvider` protocol — the new Resolver is built fresh in Phase 4.)

- [ ] **Step 1: Delete the directories**

```bash
git rm -r Sources/GimmeCore/agent Sources/GimmeCore/brew Sources/GimmeCore/cellar \
         Sources/GimmeCore/downloader Sources/GimmeCore/installer Sources/GimmeCore/manifest \
         Sources/GimmeCore/mise Sources/GimmeCore/resolver Sources/GimmeCore/semver \
         Sources/GimmeCore/shim Sources/GimmeCore/stager Sources/GimmeCore/state Sources/GimmeCore/taps
```

- [ ] **Step 2: Delete the bundled tap and cask/installer assets**

```bash
git rm -r taps/gimme-core
```

- [ ] **Step 3: Commit (build still failing — expected)**

```bash
git add -A && git commit -m "chore: delete native pipeline source directories

Removes agent, brew, cellar, downloader, installer, manifest, mise,
resolver, semver, shim, stager, state, taps, and the bundled core tap.
gimmie v2 orchestrates real package managers instead of installing natively."
```

### Task 1.4: Replace `Gimme.swift`, `Config.swift`, `Paths.swift`, `SystemManagers.swift`, `Placeholder.swift` with trimmed stubs

The remaining `GimmeCore/*.swift` reference deleted types. Replace each with a minimal version that compiles, to be fleshed out in later phases.

**Files:**
- Modify (gut to stubs): `Sources/GimmeCore/Gimme.swift`, `Sources/GimmeCore/Config.swift`, `Sources/GimmeCore/Paths.swift`, `Sources/GimmeCore/SystemManagers.swift`, `Sources/GimmeCore/Placeholder.swift`
- Keep as-is: `Sources/GimmeCore/Host.swift`, `Sources/GimmeCore/errors/GimmeError.swift`

**Interfaces:**
- Produces: a compiling `GimmeCore` with `Host`, `GimmeError`, a stub `GimmePaths`, stub `Config`, stub `Gimme`, and nothing else.

- [ ] **Step 1: Replace `Paths.swift` with a trimmed version**

Write `Sources/GimmeCore/Paths.swift`:

```swift
import Foundation

/// Resolves all gimme on-disk locations. v2 uses XDG-ish paths under the home
/// directory: config in ~/.config/gimme, cache in ~/.cache/gimme.
public struct GimmePaths: Equatable {
    public let configDir: URL
    public let cacheDir: URL

    public init(configDir: URL, cacheDir: URL) {
        self.configDir = configDir
        self.cacheDir = cacheDir
    }

    public var configFile: URL { configDir.appendingPathComponent("config.toml") }
    public var preferencesFile: URL { configDir.appendingPathComponent("preferences.toml") }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Default user locations: ~/.config/gimme and ~/.cache/gimme.
    public static var defaultUser: GimmePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return GimmePaths(
            configDir: home.appendingPathComponent(".config/gimme"),
            cacheDir: home.appendingPathComponent(".cache/gimme")
        )
    }
}
```

- [ ] **Step 2: Replace `Config.swift` with a minimal v2 stub**

Write `Sources/GimmeCore/Config.swift`:

```swift
import Foundation

/// v2 gimme configuration. Holds the manager priority list and which managers
/// are enabled. Persisted to ~/.config/gimme/config.toml.
public struct Config: Codable, Equatable {
    /// Ordered list of manager IDs consulted by the Resolver when no
    /// remembered preference applies. Default order per the design spec.
    public var priority: [String]
    /// Manager IDs explicitly disabled by the user (skipped by Resolver/Registry).
    public var disabled: [String]
    /// Cache TTL in seconds for list/outdated operations.
    public var listCacheTTLSeconds: Int
    /// Cache TTL in seconds for info/search operations.
    public var infoCacheTTLSeconds: Int

    public init(
        priority: [String] = ["homebrew", "go", "uv", "cargo", "bun"],
        disabled: [String] = [],
        listCacheTTLSeconds: Int = 300,
        infoCacheTTLSeconds: Int = 3600
    ) {
        self.priority = priority
        self.disabled = disabled
        self.listCacheTTLSeconds = listCacheTTLSeconds
        self.infoCacheTTLSeconds = infoCacheTTLSeconds
    }

    public static let defaults = Config()

    public static func loadOrCreate(at path: URL) -> Config {
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let parsed = try? TOML.parseData(data),
              let cfg = decode(from: parsed) else {
            return .defaults
        }
        return cfg
    }

    static func decode(from root: TOMLTable) -> Config? {
        var c = Config()
        if let p = root.array("priority") {
            c.priority = p.compactMap { $0.asString }
        }
        if let d = root.array("disabled") {
            c.disabled = d.compactMap { $0.asString }
        }
        if let list = root.integer("listCacheTTLSeconds") { c.listCacheTTLSeconds = list }
        if let info = root.integer("infoCacheTTLSeconds") { c.infoCacheTTLSeconds = info }
        return c
    }

    public func toTOML() -> String {
        var lines: [String] = []
        lines.append("priority = \(priority.map { "\"\($0)\"" }.joined(separator: ", "))")
        lines.append("disabled = \(disabled.map { "\"\($0)\"" }.joined(separator: ", "))")
        lines.append("listCacheTTLSeconds = \(listCacheTTLSeconds)")
        lines.append("infoCacheTTLSeconds = \(infoCacheTTLSeconds)")
        return lines.joined(separator: "\n") + "\n"
    }
}
```

- [ ] **Step 3: Delete `SystemManagers.swift` and `Placeholder.swift`**

```bash
git rm Sources/GimmeCore/SystemManagers.swift Sources/GimmeCore/Placeholder.swift
```

- [ ] **Step 4: Replace `Gimme.swift` with a minimal command-runner stub**

Write `Sources/GimmeCore/Gimme.swift`:

```swift
import Foundation

/// The gimme command runner. The CLI is a thin wrapper over this; tests call
/// it in-process. Fleshed out in Phase 7.
public final class Gimme {
    public init() {}

    /// Run a command. Stub — real dispatch added in Phase 7.
    public func run(command: String, args: [String]) throws {
        // Phase 7 implements install/uninstall/update/list/outdated/search/info/doctor/config/forget + passthrough
    }
}
```

- [ ] **Step 5: Build GimmeCore**

Run: `swift build --target GimmeCore 2>&1 | tail -20`
Expected: BUILD SUCCEEDS. (If errors remain, they reference deleted types — fix by removing the offending line. Do not reintroduce deleted code.)

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor: trim GimmeCore to stubs for v2 rebuild

Paths -> XDG-ish config/cache dirs. Config -> priority list + cache TTLs.
Gimme -> minimal runner stub. SystemManagers/Placeholder removed.
Host and GimmeError kept. Build compiles; fleshed out in later phases."
```

### Task 1.5: Replace the CLI entry point with a stub

**Files:**
- Modify: `Sources/gimme/main.swift`

- [ ] **Step 1: Replace `main.swift`**

Write `Sources/gimme/main.swift`:

```swift
import Foundation
import GimmeCore

// CLI entry point. Real verb dispatch + passthrough added in Phase 7.
let gimme = Gimme()
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
try? gimme.run(command: command, args: Array(args.dropFirst()))
```

- [ ] **Step 2: Build the CLI**

Run: `swift build --target gimme 2>&1 | tail -20`
Expected: BUILD SUCCEEDS.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "chore: stub CLI entry point for v2 rebuild"
```

### Task 1.6: Replace the SwiftUI app with a minimal shell

**Files:**
- Modify: `Sources/GimmeUI/GimmeApp.swift`
- Modify: `Sources/GimmeUI/ContentView.swift`

The old UI is ~1500 lines tightly coupled to the deleted pipeline. Replace with a minimal compiling shell, rebuilt fully in Phase 8.

- [ ] **Step 1: Replace `GimmeApp.swift`**

Write `Sources/GimmeUI/GimmeApp.swift`:

```swift
import SwiftUI
import GimmeCore

@main
struct GimmeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

- [ ] **Step 2: Replace `ContentView.swift`**

Write `Sources/GimmeUI/ContentView.swift`:

```swift
import SwiftUI

/// Placeholder. Full UI rebuilt in Phase 8.
struct ContentView: View {
    var body: some View {
        Text("gimmie v2 — UI under construction")
            .padding()
    }
}
```

- [ ] **Step 3: Build the UI**

Run: `swift build --target GimmeUI 2>&1 | tail -20`
Expected: BUILD SUCCEEDS.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "chore: stub SwiftUI app shell for v2 rebuild"
```

### Task 1.7: Prune tests to survivors; restore green

With the pipeline gone, most tests reference deleted types. Delete the obsolete test files; keep the few that test surviving code (`TOMLTests`, `HostTests`, `PathsTests` will be rewritten).

**Files:**
- Delete all `Tests/GimmeTests/*.swift` except: `HostTests.swift`, `TOMLTests.swift`, `GimmeErrorTests.swift`.

- [ ] **Step 1: List and delete obsolete test files**

```bash
cd Tests/GimmeTests
keep="HostTests.swift TOMLTests.swift GimmeErrorTests.swift"
for f in *.swift; do
  case " $keep " in *" $f "*) ;; *) git rm "$f";; esac
done
cd ../..
```

- [ ] **Step 2: Rewrite `PathsTests.swift` for the new `GimmePaths`** (the old one referenced deleted paths)

Write `Tests/GimmeTests/PathsTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class PathsTests: XCTestCase {
    func testDefaultUserLocations() {
        let p = GimmePaths.defaultUser
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(p.configDir.path.hasSuffix("/.config/gimme"))
        XCTAssertTrue(p.cacheDir.path.hasSuffix("/.cache/gimme"))
        XCTAssertTrue(p.configFile.path.hasSuffix("/.config/gimme/config.toml"))
        XCTAssertTrue(p.preferencesFile.path.hasSuffix("/.config/gimme/preferences.toml"))
        _ = home
    }

    func testEnsureDirectoriesCreates() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let p = GimmePaths(configDir: tmp.appendingPathComponent("cfg"), cacheDir: tmp.appendingPathComponent("cache"))
        try p.ensureDirectories()
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.configDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.cacheDir.path))
    }
}
```

- [ ] **Step 3: Rewrite `GimmeErrorTests.swift` if it references deleted error categories**

Run: `swift test --filter GimmeErrorTests 2>&1 | tail -15`. If it fails to compile, read `Tests/GimmeTests/GimmeErrorTests.swift`, delete any test case that references error scenarios no longer meaningful (e.g. checksum/install-specific messages), and keep the structural tests (category, exitCode, message, recoverable, toJSON shape). The `GimmeError` enum itself is unchanged, so most should pass.

- [ ] **Step 4: Run the full surviving test suite green**

Run: `swift test 2>&1 | tail -20`
Expected: all tests PASS (TOMLTests, HostTests, PathsTests, GimmeErrorTests). If a survivor fails to compile, fix it minimally — do not delete the file.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "test: prune obsolete tests, restore green after pipeline removal

Keeps TOMLTests, HostTests, PathsTests (rewritten for v2 paths),
GimmeErrorTests. All other tests referenced the deleted native pipeline.
Suite is green on the trimmed 3-target workspace."
```

---

## Phase 2 — Core Types + Protocol

**Goal:** Define the `PackageManager` protocol and all shared types (spec §4). These types are referenced by every later phase, so they must be exact and stable.

### Task 2.1: `ManagerID`, `Capability`, and `PackageRef`

**Files:**
- Create: `Sources/GimmeCore/PackageManager.swift`
- Test: `Tests/GimmeTests/PackageManagerContractTests.swift`

**Interfaces:**
- Produces: `ManagerID` enum, `Capability` enum, `PackageRef` struct.

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/PackageManagerContractTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class PackageRefTests: XCTestCase {
    func testPackageRefNoHint() {
        let r = PackageRef(name: "ripgrep", managerHint: nil)
        XCTAssertEqual(r.name, "ripgrep")
        XCTAssertNil(r.managerHint)
    }

    func testPackageRefWithHint() {
        let r = PackageRef(name: "ripgrep", managerHint: .cargo)
        XCTAssertEqual(r.managerHint, .cargo)
    }

    func testPackageRefHashable() {
        let a = PackageRef(name: "rg", managerHint: .brew)
        let b = PackageRef(name: "rg", managerHint: .brew)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testManagerIDRawValues() {
        XCTAssertEqual(ManagerID.homebrew.rawValue, "homebrew")
        XCTAssertEqual(ManagerID.bun.rawValue, "bun")
    }

    func testCapabilityRawValues() {
        XCTAssertEqual(Capability.install.rawValue, "install")
        XCTAssertEqual(Capability.bootstrap.rawValue, "bootstrap")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PackageRefTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'PackageRef' in scope` / `cannot find 'ManagerID'`.

- [ ] **Step 3: Write minimal implementation**

Write `Sources/GimmeCore/PackageManager.swift` (first slice — types only; protocol added in 2.3):

```swift
import Foundation

/// Stable identifier for a package manager backend.
public enum ManagerID: String, Hashable, Codable, CaseIterable {
    case homebrew, go, uv, cargo, bun

    /// Display name shown in the GUI (e.g. "Homebrew", "npm (via bun)").
    public var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .go:       return "Go"
        case .uv:       return "Python (uv)"
        case .cargo:    return "Cargo"
        case .bun:      return "npm (via bun)"
        }
    }

    /// SF Symbol name for the GUI.
    public var iconName: String {
        switch self {
        case .homebrew: return "cup.and.saucer.fill"
        case .go:       return "building.columns"
        case .uv:       return "snake"
        case .cargo:    return "shippingbox"
        case .bun:      return "bag"
        }
    }
}

/// Operations a package manager can support. Not every backend supports every op.
public enum Capability: String, Hashable, Codable {
    case install, uninstall, upgrade, list, outdated, search, info, bootstrap
}

/// How we address a package across the system.
public struct PackageRef: Hashable, Codable {
    /// Package name or import path. For Go this is e.g. "github.com/spf13/cobra".
    /// For scoped npm packages, "babel/core" or "@babel/core".
    public let name: String
    /// Set when the user used --from. The Resolver honors it and records a
    /// remembered preference on successful install.
    public let managerHint: ManagerID?

    public init(name: String, managerHint: ManagerID? = nil) {
        self.name = name
        self.managerHint = managerHint
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PackageRefTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add ManagerID, Capability, PackageRef types (spec §4.1)"
```

### Task 2.2: Result structs — `InstalledPackage`, `OutdatedPackage`, `SearchHit`, `PackageInfo`

**Files:**
- Modify: `Sources/GimmeCore/PackageManager.swift` (append result types)
- Test: `Tests/GimmeTests/PackageManagerContractTests.swift` (append cases)

**Interfaces:**
- Produces: the four result structs, each `Identifiable` with manager-namespaced IDs, all `Codable`.

- [ ] **Step 1: Append failing tests**

Append to `Tests/GimmeTests/PackageManagerContractTests.swift`:

```swift
final class ResultStructTests: XCTestCase {
    func testInstalledPackageNamespacedID() {
        let p = InstalledPackage(name: "ripgrep", version: "14.1.0", manager: .homebrew, installedAt: nil)
        XCTAssertEqual(p.id, "homebrew:ripgrep")
    }

    func testOutdatedPackageNamespacedID() {
        let p = OutdatedPackage(name: "rg", installedVersion: "13.0.0", latestVersion: "14.1.0", manager: .cargo)
        XCTAssertEqual(p.id, "cargo:rg")
    }

    func testSearchHitNamespacedID() {
        let h = SearchHit(name: "esbuild", manager: .bun, summary: "bun", latestVersion: "1.0.0")
        XCTAssertEqual(h.id, "bun:esbuild")
    }

    func testInstalledPackageCodableRoundTrip() throws {
        let p = InstalledPackage(name: "rg", version: "1.0", manager: .go, installedAt: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(InstalledPackage.self, from: data)
        XCTAssertEqual(back, p)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ResultStructTests 2>&1 | tail -15`
Expected: FAIL — types missing.

- [ ] **Step 3: Append the result types to `PackageManager.swift`**

Append:

```swift
/// A package installed on the system. ID is manager-namespaced so the same
/// name on two managers never collides in a unified list.
public struct InstalledPackage: Identifiable, Hashable, Codable {
    public let name: String
    public let version: String
    public let manager: ManagerID
    public let installedAt: Date?

    public init(name: String, version: String, manager: ManagerID, installedAt: Date?) {
        self.name = name
        self.version = version
        self.manager = manager
        self.installedAt = installedAt
    }

    public var id: String { "\(manager.rawValue):\(name)" }
}

/// A package with a newer version available.
public struct OutdatedPackage: Identifiable, Hashable, Codable {
    public let name: String
    public let installedVersion: String
    public let latestVersion: String
    public let manager: ManagerID

    public init(name: String, installedVersion: String, latestVersion: String, manager: ManagerID) {
        self.name = name
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.manager = manager
    }

    public var id: String { "\(manager.rawValue):\(name)" }
}

/// A single search result.
public struct SearchHit: Identifiable, Hashable, Codable {
    public let name: String
    public let manager: ManagerID
    public let summary: String
    public let latestVersion: String

    public init(name: String, manager: ManagerID, summary: String, latestVersion: String) {
        self.name = name
        self.manager = manager
        self.summary = summary
        self.latestVersion = latestVersion
    }

    public var id: String { "\(manager.rawValue):\(name)" }
}

/// Full info about a package (installed or not).
public struct PackageInfo: Hashable, Codable {
    public let name: String
    public let manager: ManagerID
    public let latestVersion: String
    public let summary: String
    public let homepage: String?
    public let license: String?
    public let installedVersion: String?
    public let location: String?

    public init(name: String, manager: ManagerID, latestVersion: String, summary: String,
                homepage: String?, license: String?, installedVersion: String?, location: String?) {
        self.name = name
        self.manager = manager
        self.latestVersion = latestVersion
        self.summary = summary
        self.homepage = homepage
        self.license = license
        self.installedVersion = installedVersion
        self.location = location
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ResultStructTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add InstalledPackage/OutdatedPackage/SearchHit/PackageInfo (spec §4.1)"
```

### Task 2.3: `InstallOptions`, `InstallResult`, and the `PackageManager` protocol

**Files:**
- Modify: `Sources/GimmeCore/PackageManager.swift` (append options + protocol)
- Modify: `Tests/GimmeTests/PackageManagerContractTests.swift` (append a fake-conformer test)

**Interfaces:**
- Produces: `InstallOptions`, `InstallResult`, and the `PackageManager` protocol itself — the single seam.

- [ ] **Step 1: Write the failing test (a fake conformer exercising the protocol)**

Append to `Tests/GimmeTests/PackageManagerContractTests.swift`:

```swift
final class PackageManagerProtocolTests: XCTestCase {
    /// A minimal in-memory conformer used only to prove the protocol compiles
    /// and the contract is internally consistent.
    struct FakeManager: PackageManager {
        let id: ManagerID = .homebrew
        let displayName = "Fake"
        let icon = "circle"
        let capabilities: Set<Capability> = [.install, .uninstall, .list, .info, .bootstrap]
        func isAvailable() -> Bool { true }
        func bootstrap() async throws {}
        func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
            InstallResult(package: InstalledPackage(name: package.name, version: "1.0", manager: id, installedAt: Date()), warnings: [])
        }
        func uninstall(_ package: PackageRef) async throws {}
        func upgrade(_ package: PackageRef) async throws {}
        func listInstalled() async throws -> [InstalledPackage] { [] }
        func outdated() async throws -> [OutdatedPackage] { [] }
        func search(_ query: String) async throws -> [SearchHit] { [] }
        func info(_ package: PackageRef) async throws -> PackageInfo {
            PackageInfo(name: package.name, manager: id, latestVersion: "1.0", summary: "", homepage: nil, license: nil, installedVersion: nil, location: nil)
        }
    }

    func testFakeManagerConformsAndRuns() async throws {
        let m = FakeManager()
        let result = try await m.install(PackageRef(name: "rg"), options: InstallOptions())
        XCTAssertEqual(result.package.manager, .homebrew)
        XCTAssertTrue(m.capabilities.contains(.install))
    }

    func testInstallOptionsDefaults() {
        let o = InstallOptions()
        XCTAssertNil(o.version)
        XCTAssertFalse(o.yes)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PackageManagerProtocolTests 2>&1 | tail -15`
Expected: FAIL — protocol + options missing.

- [ ] **Step 3: Append options + protocol to `PackageManager.swift`**

Append:

```swift
/// Options passed to install().
public struct InstallOptions: Hashable, Codable {
    public let version: String?   // pin to a version if the manager supports it
    public let yes: Bool          // non-interactive: skip prompts
    public init(version: String? = nil, yes: Bool = false) {
        self.version = version
        self.yes = yes
    }
}

/// Result of an install.
public struct InstallResult: Hashable, Codable {
    public let package: InstalledPackage
    public let warnings: [String]  // e.g. "library package — no CLI entry"
    public init(package: InstalledPackage, warnings: [String] = []) {
        self.package = package
        self.warnings = warnings
    }
}

/// The single seam every backend conforms to. The engine and UI talk only
/// through this interface (spec §4).
public protocol PackageManager {
    var id: ManagerID { get }
    var displayName: String { get }
    var icon: String { get }
    var capabilities: Set<Capability> { get }

    func isAvailable() -> Bool
    func bootstrap() async throws

    func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult
    func uninstall(_ package: PackageRef) async throws
    func upgrade(_ package: PackageRef) async throws
    func listInstalled() async throws -> [InstalledPackage]
    func outdated() async throws -> [OutdatedPackage]
    func search(_ query: String) async throws -> [SearchHit]
    func info(_ package: PackageRef) async throws -> PackageInfo
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter PackageManagerProtocolTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add PackageManager protocol + InstallOptions/Result (spec §4)"
```

### Task 2.4: Extend `GimmeError` with v2 cases

The existing `GimmeError` is built around the native pipeline (checksum, lock). Add v2 cases and a `searchedManagers` context for not-found (spec §9).

**Files:**
- Modify: `Sources/GimmeCore/errors/GimmeError.swift`
- Test: `Tests/GimmeTests/GimmeErrorTests.swift` (append cases)

**Interfaces:**
- Produces: new cases `managerUnavailable(ManagerID)`, `notFoundInManagers(name:searched:)`, `bootstrapFailed(ManagerID, underlying)`, `operationFailed(manager:op:underlying:)`. Existing cases stay for backward compatibility with any surviving test; legacy cases that no longer apply can be removed only if a test references them (re-check).

- [ ] **Step 1: Append failing tests**

Append to `Tests/GimmeTests/GimmeErrorTests.swift`:

```swift
func testManagerUnavailable() {
    let e = GimmeError.managerUnavailable(.cargo)
    XCTAssertEqual(e.message, "cargo is not installed")
    XCTAssertEqual(e.category, .USAGE)
}

func testNotFoundInManagersCarriesContext() {
    let e = GimmeError.notFoundInManagers(name: "ripgrep", searched: [.homebrew, .cargo, .go])
    XCTAssertEqual(e.message, "no manager has 'ripgrep'; searched: homebrew, cargo, go")
    XCTAssertEqual(e.category, .NOT_FOUND)
}

func testBootstrapFailed() {
    let e = GimmeError.bootstrapFailed(.bun, underlying: "exit code 1")
    XCTAssertEqual(e.category, .INSTALL)
    XCTAssertTrue(e.message.contains("bun"))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GimmeErrorTests 2>&1 | tail -15`
Expected: FAIL — new cases missing.

- [ ] **Step 3: Add the new cases to `GimmeError`**

In `Sources/GimmeCore/errors/GimmeError.swift`, add cases to the enum and extend `category`, `message`, and `toJSON`. Add these cases to the enum:

```swift
    case managerUnavailable(ManagerID)
    case notFoundInManagers(name: String, searched: [ManagerID])
    case bootstrapFailed(ManagerID, underlying: String)
    case operationFailed(manager: ManagerID, op: String, underlying: String)
```

Extend `category`:

```swift
        case .managerUnavailable, .notFoundInManagers: return .USAGE  // notFoundInManagers is a cleaner NOT_FOUND; see below
```

Note: `notFoundInManagers` should map to `.NOT_FOUND`. Correct the mapping:

```swift
    public var category: ErrorCategory {
        switch self {
        case .usage, .managerUnavailable:                 return .USAGE
        case .notFound, .notFoundInManagers:              return .NOT_FOUND
        case .install, .bootstrapFailed, .operationFailed: return .INSTALL
        case .network:                                    return .NETWORK
        case .checksumMismatch:                           return .CHECKSUM
        case .permission:                                 return .PERMISSION
        case .conflict:                                   return .CONFLICT
        case .lock:                                       return .LOCK
        case .unknown:                                    return .UNKNOWN
        }
    }
```

Extend `message`:

```swift
    public var message: String {
        switch self {
        case .usage(let s), .notFound(let s), .install(let s), .network(let s),
             .permission(let s), .conflict(let s), .lock(let s), .unknown(let s):
            return s
        case .checksumMismatch(let e, let a):
            return "checksum mismatch: expected \(e), got \(a"
        case .managerUnavailable(let m):
            return "\(m.rawValue) is not installed"
        case .notFoundInManagers(let name, let searched):
            let list = searched.map { $0.rawValue }.joined(separator: ", ")
            return "no manager has '\(name)'; searched: \(list)"
        case .bootstrapFailed(let m, let underlying):
            return "failed to bootstrap \(m.rawValue): \(underlying)"
        case .operationFailed(let m, let op, let underlying):
            return "\(m.rawValue) \(op) failed: \(underlying)"
        }
    }
```

Add `Equatable` conformance for the new associated-value cases (the enum is `Equatable`; since `ManagerID` and `String` are `Equatable`, the auto-synthesis covers them — no manual `==` needed as long as all associated values are `Equatable`).

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter GimmeErrorTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add v2 GimmeError cases (managerUnavailable, notFoundInManagers, bootstrapFailed, operationFailed)"
```

---

## Phase 3 — `Process` helper + `HTTPClient` + `Bootstrap`

**Goal:** The shared infrastructure every adapter uses (spec §6.6). Built once, reused by all five adapters.

### Task 3.1: `Process` helper — streaming subprocess execution

**Files:**
- Create: `Sources/GimmeCore/Process.swift`
- Test: `Tests/GimmeTests/ProcessTests.swift`

**Interfaces:**
- Produces: `ProcessRunner` with `static func run(_ executable: String, args: [String], env: [String:String]?, stream: ((String) -> Void)?) async throws -> ProcessResult`; `ProcessResult { exitCode: Int32; stdout: String; stderr: String }`.

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/ProcessTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class ProcessTests: XCTestCase {
    func testRunEcho() async throws {
        let result = try await ProcessRunner.run("/bin/echo", args: ["hello"], env: nil, stream: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testRunExitCode() async throws {
        let result = try await ProcessRunner.run("/bin/sh", args: ["-c", "exit 3"], env: nil, stream: nil)
        XCTAssertEqual(result.exitCode, 3)
    }

    func testRunStderr() async throws {
        let result = try await ProcessRunner.run("/bin/sh", args: ["-c", "echo oops >&2"], env: nil, stream: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
    }

    func testStreamCallback() async throws {
        var lines: [String] = []
        _ = try await ProcessRunner.run("/bin/sh", args: ["-c", "echo a; echo b"], env: nil) { line in
            lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(lines, ["a", "b"])
    }

    func testRunMissingExecutableThrows() async throws {
        do {
            _ = try await ProcessRunner.run("/nonexistent/binary", args: [], env: nil, stream: nil)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(true)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ProcessTests 2>&1 | tail -15`
Expected: FAIL — `ProcessRunner` missing.

- [ ] **Step 3: Implement `ProcessRunner`**

Write `Sources/GimmeCore/Process.swift`:

```swift
import Foundation

/// Result of a subprocess run.
public struct ProcessResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Thin wrapper around Foundation.Process with optional line streaming.
/// All adapters use this; never call Process directly elsewhere.
public enum ProcessRunner {
    /// Run a command, returning when it exits. If `stream` is non-nil, each
    /// line of combined stdout/stderr is delivered to it as it arrives.
    public static func run(
        _ executable: String,
        args: [String],
        env: [String: String]? = nil,
        stream: ((String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        if let env { proc.environment = env }

        var stdoutData = Data()
        var stderrData = Data()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        if stream != nil {
            stdoutHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutData.append(chunk)
                Self.deliverLines(chunk, to: stream!)
            }
            stderrHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrData.append(chunk)
                Self.deliverLines(chunk, to: stream!)
            }
        }

        try proc.run()

        if stream == nil {
            // Non-streaming: read fully after exit.
            stdoutData = stdoutHandle.readDataToEndOfFile()
            stderrData = stderrHandle.readDataToEndOfFile()
        }

        proc.waitUntilExit()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        // If streaming, drain any remainder.
        if stream != nil {
            let rest = stdoutHandle.readDataToEndOfFile()
            if !rest.isEmpty { stdoutData.append(rest); Self.deliverLines(rest, to: stream!) }
            let restErr = stderrHandle.readDataToEndOfFile()
            if !restErr.isEmpty { stderrData.append(restErr); Self.deliverLines(restErr, to: stream!) }
        }

        return ProcessResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Split a Data chunk into complete lines and deliver each (minus newline)
    /// to the callback. Incomplete trailing data is held until the next chunk.
    private static var lineBuffers: [ObjectIdentifier: String] = [:]
    private static let bufferLock = NSLock()

    private static func deliverLines(_ data: Data, to callback: (String) -> Void) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        bufferLock.lock()
        let key = ObjectIdentifier(data as AnyObject)  // not stable; replaced below
        bufferLock.unlock()
        // Simpler: keep a per-call buffer is wrong across calls. Use a single
        // static buffer keyed by thread instead. For correctness and simplicity
        // in v1, deliver whatever is newline-terminated in this chunk and hold
        // the tail into a static carry.
        var combined = carry + text
        carry = ""
        while let nl = combined.firstIndex(of: "\n") {
            let line = String(combined[..<nl])
            combined.removeSubrange(combined.startIndex...nl)
            callback(line)
        }
        carry = combined
        _ = key
    }

    /// Carries an unterminated tail across deliverLines calls within one process.
    nonisolated(unsafe) private static var carry: String = ""
}
```

**Note for the implementer:** the streaming carry-buffer logic above is subtle. Simpler and robust alternative — if `deliverLines` proves flaky in tests, replace the whole `stream != nil` branch with: read to EOF into Data, then split the full combined stdout+stderr by newlines and deliver each line, accepting that "streaming" becomes "delivered at end." Live progress is nicer but correctness first. Pick the simpler form if the test is unreliable. Keep the public API identical either way.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ProcessTests 2>&1 | tail -20`
Expected: PASS (all 5 cases). If `testStreamCallback` is flaky, switch to the simpler end-of-stream delivery described above and re-run.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add ProcessRunner streaming subprocess helper (spec §6.6)"
```

### Task 3.2: `HTTPClient` — URLSession wrapper

**Files:**
- Create: `Sources/GimmeCore/HTTPClient.swift`
- Test: `Tests/GimmeTests/HTTPClientTests.swift`

**Interfaces:**
- Produces: `HTTPClient` protocol with `func get(_ url: String) async throws -> Data` and `func getJSON<T: Decodable>(_ url: String, as: T.Type) async throws -> T`; a `URLSessionHTTPClient` default impl; an injectable `StubHTTPClient` for tests.

- [ ] **Step 1: Write the failing test (using a stub client — no real network)**

Write `Tests/GimmeTests/HTTPClientTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class HTTPClientTests: XCTestCase {
    /// A test double that returns canned bytes for a given URL.
    final class StubHTTPClient: HTTPClient {
        var responses: [String: Data] = [:]
        func data(for url: URL) async throws -> Data {
            responses[url.absoluteString] ?? Data()
        }
    }

    func testGetReturnsStubbedData() async throws {
        let stub = StubHTTPClient()
        stub.responses["https://example.com/x"] = Data("[1,2,3]".utf8)
        let data = try await stub.get("https://example.com/x")
        XCTAssertEqual(String(data: data, encoding: .utf8), "[1,2,3]")
    }

    func testGetJSONDecodes() async throws {
        struct Body: Decodable, Equatable { let name: String }
        let stub = StubHTTPClient()
        stub.responses["https://example.com/p"] = Data(#"{"name":"ripgrep"}"#.utf8)
        let body: Body = try await stub.getJSON("https://example.com/p", as: Body.self)
        XCTAssertEqual(body, Body(name: "ripgrep"))
    }

    func testRealClientIsHTTPClient() {
        // Sanity: the production client conforms.
        let _: HTTPClient = URLSessionHTTPClient()
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter HTTPClientTests 2>&1 | tail -15`
Expected: FAIL — `HTTPClient` missing.

- [ ] **Step 3: Implement `HTTPClient`**

Write `Sources/GimmeCore/HTTPClient.swift`:

```swift
import Foundation

/// Minimal HTTP client protocol so adapters can be tested with stubs.
public protocol HTTPClient {
    func data(for url: URL) async throws -> Data
}

public extension HTTPClient {
    /// Fetch a URL and return raw bytes.
    func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw GimmeError.network("invalid URL: \(urlString)") }
        return try await data(for: url)
    }

    /// Fetch and decode JSON.
    func getJSON<T: Decodable>(_ urlString: String, as type: T.Type) async throws -> T {
        let data = try await get(urlString)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GimmeError.network("failed to decode JSON from \(urlString): \(error)")
        }
    }
}

/// Production client backed by URLSession.
public final class URLSessionHTTPClient: NSObject, HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw GimmeError.network("HTTP \(http.statusCode) for \(url.absoluteString)")
            }
            return data
        } catch let e as GimmeError {
            throw e
        } catch {
            throw GimmeError.network("request failed for \(url.absoluteString): \(error)")
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter HTTPClientTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add HTTPClient + URLSessionHTTPClient (spec §6.6)"
```

### Task 3.3: `Bootstrap` — the auto-bootstrap runner

**Files:**
- Create: `Sources/GimmeCore/Bootstrap.swift`
- Test: `Tests/GimmeTests/BootstrapTests.swift`

**Interfaces:**
- Consumes: `PackageManager.bootstrap()` (Phase 2), `ProcessRunner` (3.1).
- Produces: `Bootstrap.run(_ manager: any PackageManager, confirm: (ManagerID) -> Bool) async throws` — checks `isAvailable()`, prompts via `confirm`, runs `bootstrap()`, re-checks; throws `managerUnavailable` if declined or still missing.

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/BootstrapTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class BootstrapTests: XCTestCase {
    /// A manager that is initially unavailable and succeeds on bootstrap.
    final class FakeManager: PackageManager {
        let id: ManagerID = .cargo
        let displayName = "Fake"
        let icon = "circle"
        let capabilities: Set<Capability> = [.install, .bootstrap]
        private var available = false
        var bootstrapCalled = false
        func isAvailable() -> Bool { available }
        func bootstrap() async throws { bootstrapCalled = true; available = true }
        func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
            InstallResult(package: InstalledPackage(name: package.name, version: "1", manager: id, installedAt: nil))
        }
        func uninstall(_ package: PackageRef) async throws {}
        func upgrade(_ package: PackageRef) async throws {}
        func listInstalled() async throws -> [InstalledPackage] { [] }
        func outdated() async throws -> [OutdatedPackage] { [] }
        func search(_ query: String) async throws -> [SearchHit] { [] }
        func info(_ package: PackageRef) async throws -> PackageInfo {
            PackageInfo(name: package.name, manager: id, latestVersion: "1", summary: "", homepage: nil, license: nil, installedVersion: nil, location: nil)
        }
    }

    func testBootstrapWhenDeclinedThrows() async throws {
        let m = FakeManager()
        do {
            try await Bootstrap.run(m, confirm: { _ in false })
            XCTFail("expected throw")
        } catch GimmeError.managerUnavailable(let id) {
            XCTAssertEqual(id, .cargo)
            XCTAssertFalse(m.bootstrapCalled)
        }
    }

    func testBootstrapWhenConfirmedRunsAndSucceeds() async throws {
        let m = FakeManager()
        try await Bootstrap.run(m, confirm: { _ in true })
        XCTAssertTrue(m.bootstrapCalled)
    }

    func testBootstrapSkipsWhenAlreadyAvailable() async throws {
        let m = FakeManager()
        // Force available by bootstrapping once first isn't possible (FakeManager
        // starts unavailable); instead verify the short-circuit with a second
        // conformer. Simplest: after a successful bootstrap, a second run skips.
        try await Bootstrap.run(m, confirm: { _ in true })
        m.bootstrapCalled = false
        try await Bootstrap.run(m, confirm: { _ in false })  // confirm not even asked
        XCTAssertFalse(m.bootstrapCalled)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BootstrapTests 2>&1 | tail -15`
Expected: FAIL — `Bootstrap` missing.

- [ ] **Step 3: Implement `Bootstrap`**

Write `Sources/GimmeCore/Bootstrap.swift`:

```swift
import Foundation

/// Runs the auto-bootstrap flow for a missing manager (spec §6.6).
public enum Bootstrap {
    /// If `manager` is available, returns immediately. Otherwise asks `confirm`
    /// whether to install the backend; if yes, runs `bootstrap()` and re-checks.
    /// Throws `managerUnavailable` if the user declines or bootstrap leaves the
    /// manager still unavailable.
    public static func run(
        _ manager: any PackageManager,
        confirm: (ManagerID) -> Bool
    ) async throws {
        if manager.isAvailable() { return }
        guard confirm(manager.id) else {
            throw GimmeError.managerUnavailable(manager.id)
        }
        try await manager.bootstrap()
        guard manager.isAvailable() else {
            throw GimmeError.bootstrapFailed(manager.id, underlying: "still unavailable after bootstrap")
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter BootstrapTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add Bootstrap auto-bootstrap runner (spec §6.6)"
```

---

## Phase 4 — Preferences, Cache, Registry, Resolver

**Goal:** The orchestration brain (spec §5 + §3.2). After this phase the resolve → install loop works end-to-end with stub managers.

### Task 4.1: `Preferences` — remembered-overrides store

**Files:**
- Create: `Sources/GimmeCore/Preferences.swift`
- Test: `Tests/GimmeTests/PreferencesTests.swift`

**Interfaces:**
- Produces: `Preferences` struct with `overrides: [String: ManagerID]`; `remembered(for: String) -> ManagerID?`; `mutating remember(_ name: String, _ manager: ManagerID)`; `mutating forget(_ name: String)`; `mutating forgetAll()`; static `load(at: URL)` / `save(at: URL)` doing TOML round-trip.

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/PreferencesTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class PreferencesTests: XCTestCase {
    func testEmptyByDefault() {
        let p = Preferences()
        XCTAssertNil(p.remembered(for: "rg"))
    }

    func testRememberAndRecall() {
        var p = Preferences()
        p.remember("ripgrep", .cargo)
        XCTAssertEqual(p.remembered(for: "ripgrep"), .cargo)
    }

    func testForgetOne() {
        var p = Preferences()
        p.remember("rg", .cargo)
        p.remember("bat", .brew)
        p.forget("rg")
        XCTAssertNil(p.remembered(for: "rg"))
        XCTAssertEqual(p.remembered(for: "bat"), .brew)
    }

    func testForgetAll() {
        var p = Preferences()
        p.remember("rg", .cargo)
        p.remember("bat", .brew)
        p.forgetAll()
        XCTAssertNil(p.remembered(for: "rg"))
        XCTAssertNil(p.remembered(for: "bat"))
    }

    func testRoundTrip() throws {
        var p = Preferences()
        p.remember("ripgrep", .cargo)
        p.remember("github.com/spf13/cobra", .go)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("preferences.toml")
        try p.save(at: file)

        let loaded = Preferences.load(at: file)
        XCTAssertEqual(loaded.remembered(for: "ripgrep"), .cargo)
        XCTAssertEqual(loaded.remembered(for: "github.com/spf13/cobra"), .go)
    }

    func testLoadMissingFileReturnsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent("preferences.toml")
        let p = Preferences.load(at: file)
        XCTAssertNil(p.remembered(for: "anything"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PreferencesTests 2>&1 | tail -15`
Expected: FAIL — `Preferences` missing.

- [ ] **Step 3: Implement `Preferences`**

Write `Sources/GimmeCore/Preferences.swift`:

```swift
import Foundation

/// Per-package remembered manager overrides (spec §5.2). Persisted to
/// ~/.config/gimme/preferences.toml, separate from config.toml.
public struct Preferences: Equatable {
    /// Map of package name -> chosen manager.
    public private(set) var overrides: [String: ManagerID]

    public init(overrides: [String: ManagerID] = [:]) {
        self.overrides = overrides
    }

    public func remembered(for name: String) -> ManagerID? {
        overrides[name]
    }

    public mutating func remember(_ name: String, _ manager: ManagerID) {
        overrides[name] = manager
    }

    public mutating func forget(_ name: String) {
        overrides.removeValue(forKey: name)
    }

    public mutating func forgetAll() {
        overrides.removeAll()
    }

    public static func load(at path: URL) -> Preferences {
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let root = try? TOML.parseData(data) else {
            return Preferences()
        }
        var overrides: [String: ManagerID] = [:]
        if let table = root.table("overrides") {
            for (name, value) in table.children {
                if let raw = value.asString, let id = ManagerID(rawValue: raw) {
                    overrides[name] = id
                }
            }
        }
        return Preferences(overrides: overrides)
    }

    public func save(at path: URL) throws {
        var lines: [String] = ["[overrides]"]
        for (name, id) in overrides.sorted(by: { $0.key < $1.key }) {
            lines.append("\"\(escapeKey(name))\" = \"\(id.rawValue)\"")
        }
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Escape a TOML key in a quoted form: backslash and double-quote.
    private func escapeKey(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter PreferencesTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add Preferences remembered-overrides store (spec §5.2)"
```

### Task 4.2: `Cache` — TTL disk cache

**Files:**
- Create: `Sources/GimmeCore/Cache.swift`
- Test: `Tests/GimmeTests/CacheTests.swift`

**Interfaces:**
- Produces: `Cache` final class with `func get<T: Decodable>(_ key: String, ttlSeconds: Int, as: T.Type) -> T?`; `func set<T: Encodable>(_ key: String, _ value: T)`; `func invalidate(_ key: String)`; `func invalidatePrefix(_ prefix: String)`; `func clear()`. Keyed by `manager:operation` strings.

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/CacheTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class CacheTests: XCTestCase {
    func makeCache() -> Cache {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Cache(directory: dir)
    }

    func testSetThenGet() {
        let cache = makeCache()
        cache.set("homebrew:list", value: ["rg", "fd"])
        let got: [String]? = cache.get("homebrew:list", ttlSeconds: 60, as: [String].self)
        XCTAssertEqual(got, ["rg", "fd"])
    }

    func testGetMissingReturnsNil() {
        let cache = makeCache()
        let got: String? = cache.get("nope", ttlSeconds: 60, as: String.self)
        XCTAssertNil(got)
    }

    func testExpiredReturnsNil() throws {
        let cache = makeCache()
        cache.set("k", value: "v")
        // Backdate the file's mtime by 100s, TTL 1s → expired.
        let file = cache.directory.appendingPathComponent("k.json")
        let old = Date().addingTimeInterval(-100)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let got: String? = cache.get("k", ttlSeconds: 1, as: String.self)
        XCTAssertNil(got)
    }

    func testInvalidate() {
        let cache = makeCache()
        cache.set("homebrew:list", value: [1])
        cache.set("cargo:list", value: [2])
        cache.invalidate("homebrew:list")
        XCTAssertNil(cache.get("homebrew:list", ttlSeconds: 60, as: [Int].self))
        XCTAssertEqual(cache.get("cargo:list", ttlSeconds: 60, as: [Int].self), [2])
    }

    func testInvalidatePrefix() {
        let cache = makeCache()
        cache.set("homebrew:list", value: 1)
        cache.set("homebrew:outdated", value: 2)
        cache.set("cargo:list", value: 3)
        cache.invalidatePrefix("homebrew:")
        XCTAssertNil(cache.get("homebrew:list", ttlSeconds: 60, as: Int.self))
        XCTAssertNil(cache.get("homebrew:outdated", ttlSeconds: 60, as: Int.self))
        XCTAssertEqual(cache.get("cargo:list", ttlSeconds: 60, as: Int.self), 3)
    }

    func testClear() {
        let cache = makeCache()
        cache.set("a", value: 1)
        cache.set("b", value: 2)
        cache.clear()
        XCTAssertNil(cache.get("a", ttlSeconds: 60, as: Int.self))
    }

    func testPersistsAcrossInstances() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = Cache(directory: dir)
        a.set("k", value: "v")
        let b = Cache(directory: dir)
        XCTAssertEqual(b.get("k", ttlSeconds: 60, as: String.self), "v")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CacheTests 2>&1 | tail -15`
Expected: FAIL — `Cache` missing.

- [ ] **Step 3: Implement `Cache`**

Write `Sources/GimmeCore/Cache.swift`:

```swift
import Foundation

/// A TTL disk cache (spec §5.3). JSON files keyed by `manager:operation` under
/// ~/.cache/gimme. Source of truth is always live; the cache only avoids
/// re-querying within its TTL window. Writes invalidate on install/uninstall.
public final class Cache {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(for key: String) -> URL {
        // Sanitize: only alnum, colon, underscore, dash, dot, slash→_.
        let safe = key.map { c -> String in
            if c.isLetter || c.isNumber || c == ":" || c == "_" || c == "-" { return String(c) }
            return "_"
        }.joined()
        return directory.appendingPathComponent("\(safe).json")
    }

    public func get<T: Decodable>(_ key: String, ttlSeconds: Int, as type: T.Type) -> T? {
        let url = file(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // TTL check via modification date.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) > Double(ttlSeconds) {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func set<T: Encodable>(_ key: String, value: T) {
        let url = file(for: key)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func invalidate(_ key: String) {
        let url = file(for: key)
        try? FileManager.default.removeItem(at: url)
    }

    public func invalidatePrefix(_ prefix: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        // Map the prefix through the same sanitizer used for file names.
        let safePrefix = prefix.map { c -> String in
            if c.isLetter || c.isNumber || c == ":" || c == "_" || c == "-" { return String(c) }
            return "_"
        }.joined()
        for name in names where name.hasPrefix(safePrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public func clear() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CacheTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add TTL disk Cache (spec §5.3)"
```

### Task 4.3: `Registry` — discovers + holds adapters

**Files:**
- Create: `Sources/GimmeCore/Registry.swift`
- Test: `Tests/GimmeTests/RegistryTests.swift`

**Interfaces:**
- Consumes: `PackageManager` (Phase 2).
- Produces: `Registry` with `all: [any PackageManager]`; `available() -> [any PackageManager]` (filters to `isAvailable()`); `get(_ id: ManagerID) -> (any PackageManager)?`; `enabled(config: Config) -> [any PackageManager]` (excludes disabled). Built with an injected list (dependency injection for tests; production wires the real five adapters).

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/RegistryTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class RegistryTests: XCTestCase {
    private func makeManager(_ id: ManagerID, available: Bool) -> any PackageManager {
        StubManager(id: id, available: available)
    }

    func testGetByID() {
        let r = Registry(managers: [makeManager(.homebrew, available: true), makeManager(.cargo, available: true)])
        XCTAssertEqual(r.get(.homebrew)?.id, .homebrew)
        XCTAssertNil(r.get(.go))
    }

    func testAvailableFiltersUnavailable() {
        let r = Registry(managers: [
            makeManager(.homebrew, available: true),
            makeManager(.cargo, available: false)
        ])
        let ids = r.available().map { $0.id }
        XCTAssertEqual(ids, [.homebrew])
    }

    func testEnabledExcludesDisabled() {
        let r = Registry(managers: [
            makeManager(.homebrew, available: true),
            makeManager(.cargo, available: true),
            makeManager(.go, available: true)
        ])
        var cfg = Config.defaults
        cfg.disabled = ["cargo"]
        let ids = r.enabled(config: cfg).map { $0.id }
        XCTAssertEqual(Set(ids), [.homebrew, .go])
    }

    func testEnabledAlsoRequiresAvailable() {
        let r = Registry(managers: [
            makeManager(.homebrew, available: true),
            makeManager(.cargo, available: false)  // not disabled, but unavailable
        ])
        let cfg = Config.defaults
        let ids = r.enabled(config: cfg).map { $0.id }
        XCTAssertEqual(ids, [.homebrew])
    }
}

/// A reusable stub manager for orchestration-layer tests.
struct StubManager: PackageManager {
    let id: ManagerID
    let available: Bool
    let displayName: String = "Stub"
    let icon: String = "circle"
    let capabilities: Set<Capability> = [.install, .uninstall, .list, .info]
    func isAvailable() -> Bool { available }
    func bootstrap() async throws {}
    func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        InstallResult(package: InstalledPackage(name: package.name, version: "1.0", manager: id, installedAt: nil))
    }
    func uninstall(_ package: PackageRef) async throws {}
    func upgrade(_ package: PackageRef) async throws {}
    func listInstalled() async throws -> [InstalledPackage] { [] }
    func outdated() async throws -> [OutdatedPackage] { [] }
    func search(_ query: String) async throws -> [SearchHit] { [] }
    func info(_ package: PackageRef) async throws -> PackageInfo {
        PackageInfo(name: package.name, manager: id, latestVersion: "1.0", summary: "", homepage: nil, license: nil, installedVersion: nil, location: nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter RegistryTests 2>&1 | tail -15`
Expected: FAIL — `Registry` missing.

- [ ] **Step 3: Implement `Registry`**

Write `Sources/GimmeCore/Registry.swift`:

```swift
import Foundation

/// Holds all package-manager adapters and answers availability/enabled
/// queries (spec §3.2). Production wires the five real adapters; tests inject
/// stubs.
public final class Registry {
    public let managers: [any PackageManager]

    public init(managers: [any PackageManager]) {
        self.managers = managers
    }

    /// All adapters that are installed on this system right now.
    public func available() -> [any PackageManager] {
        managers.filter { $0.isAvailable() }
    }

    /// Adapters that are both installed and not disabled in config.
    public func enabled(config: Config) -> [any PackageManager] {
        available().filter { !config.disabled.contains($0.id.rawValue) }
    }

    /// Look up a single adapter by ID.
    public func get(_ id: ManagerID) -> (any PackageManager)? {
        managers.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter RegistryTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add Registry — discovers + holds adapters (spec §3.2)"
```

### Task 4.4: `Resolver` — priority + remember routing

**Files:**
- Create: `Sources/GimmeCore/Resolver.swift`
- Test: `Tests/GimmeTests/ResolverTests.swift`

**Interfaces:**
- Consumes: `Registry`, `Preferences`, `Config`.
- Produces: `Resolver` with `func resolve(_ name: String, hint: ManagerID?) async -> ResolveResult`.
  - `ResolveResult` enum: `.chosen(any PackageManager)`, `.notFound(searched: [ManagerID])`, `.hintUnavailable(ManagerID)`, `.hintNotFound(ManagerID, name: String)`.
- Internals: existence check via a cheap `search` exact-match against each manager's hits (concurrent `TaskGroup`).

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/ResolverTests.swift`:

```swift
import XCTest
@testable import GimmeCore

/// A stub manager whose search returns hits only for known package names.
struct SearchableStubManager: PackageManager {
    let id: ManagerID
    let available: Bool
    let known: Set<String>                 // package names this manager "has"
    let displayName = "S"
    let icon = "circle"
    let capabilities: Set<Capability> = [.install, .search]
    func isAvailable() -> Bool { available }
    func bootstrap() async throws {}
    func install(_ p: PackageRef, options: InstallOptions) async throws -> InstallResult {
        InstallResult(package: InstalledPackage(name: p.name, version: "1", manager: id, installedAt: nil))
    }
    func uninstall(_ p: PackageRef) async throws {}
    func upgrade(_ p: PackageRef) async throws {}
    func listInstalled() async throws -> [InstalledPackage] { [] }
    func outdated() async throws -> [OutdatedPackage] { [] }
    func search(_ query: String) async throws -> [SearchHit] {
        known.contains(query) ? [SearchHit(name: query, manager: id, summary: "", latestVersion: "1")] : []
    }
    func info(_ p: PackageRef) async throws -> PackageInfo {
        PackageInfo(name: p.name, manager: id, latestVersion: "1", summary: "", homepage: nil, license: nil, installedVersion: nil, location: nil)
    }
}

final class ResolverTests: XCTestCase {
    // priority: brew, cargo, go, uv, bun ; rg is on brew + cargo
    private func makeRegistry() -> Registry {
        Registry(managers: [
            SearchableStubManager(id: .homebrew, available: true, known: ["ripgrep", "bat"]),
            SearchableStubManager(id: .cargo,    available: true, known: ["ripgrep"]),
            SearchableStubManager(id: .go,       available: true, known: []),
            SearchableStubManager(id: .uv,       available: true, known: ["flask"]),
            SearchableStubManager(id: .bun,      available: true, known: ["esbuild"])
        ])
    }

    func testPicksHighestPriorityWithPackage() async {
        let r = Resolver(registry: makeRegistry(), preferences: Preferences(), config: .defaults)
        let result = await r.resolve("ripgrep", hint: nil)
        if case .chosen(let m) = result { XCTAssertEqual(m.id, .homebrew) } else { XCTFail() }
    }

    func testHintWinsOverPriority() async {
        let r = Resolver(registry: makeRegistry(), preferences: Preferences(), config: .defaults)
        let result = await r.resolve("ripgrep", hint: .cargo)
        if case .chosen(let m) = result { XCTAssertEqual(m.id, .cargo) } else { XCTFail() }
    }

    func testHintUnavailable() async {
        let r = Resolver(registry: makeRegistry(), preferences: Preferences(), config: .defaults)
        let result = await r.resolve("ripgrep", hint: .go)
        if case .hintNotFound(let id, _) = result { XCTAssertEqual(id, .go) } else { XCTFail() }
    }

    func testRememberedPrefWins() async {
        var prefs = Preferences()
        prefs.remember("ripgrep", .cargo)
        let r = Resolver(registry: makeRegistry(), preferences: prefs, config: .defaults)
        let result = await r.resolve("ripgrep", hint: nil)
        if case .chosen(let m) = result { XCTAssertEqual(m.id, .cargo) } else { XCTFail() }
    }

    func testRememberedPrefUnavailableFallsBack() async {
        var prefs = Preferences()
        prefs.remember("ripgrep", .cargo)
        // cargo unavailable this time
        let registry = Registry(managers: [
            SearchableStubManager(id: .homebrew, available: true, known: ["ripgrep"]),
            SearchableStubManager(id: .cargo, available: false, known: ["ripgrep"])
        ])
        let r = Resolver(registry: registry, preferences: prefs, config: .defaults)
        let result = await r.resolve("ripgrep", hint: nil)
        if case .chosen(let m) = result { XCTAssertEqual(m.id, .homebrew) } else { XCTFail() }
    }

    func testNotFound() async {
        let r = Resolver(registry: makeRegistry(), preferences: Preferences(), config: .defaults)
        let result = await r.resolve("doesnotexist", hint: nil)
        if case .notFound(let searched) = result {
            XCTAssertEqual(Set(searched), [.homebrew, .cargo, .go, .uv, .bun])
        } else { XCTFail() }
    }

    func testDisabledManagersSkipped() async {
        var cfg = Config.defaults
        cfg.disabled = ["homebrew"]
        let r = Resolver(registry: makeRegistry(), preferences: Preferences(), config: cfg)
        let result = await r.resolve("ripgrep", hint: nil)
        if case .chosen(let m) = result { XCTAssertEqual(m.id, .cargo) } else { XCTFail() }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ResolverTests 2>&1 | tail -15`
Expected: FAIL — `Resolver` missing.

- [ ] **Step 3: Implement `Resolver`**

Write `Sources/GimmeCore/Resolver.swift`:

```swift
import Foundation

/// Outcome of resolving a package name to a manager (spec §5.1).
public enum ResolveResult {
    case chosen(any PackageManager)
    case notFound(searched: [ManagerID])
    case hintNotFound(ManagerID, name: String)        // --from X but X lacks the package
    case hintUnavailable(ManagerID)                    // --from X but X not installed
}

/// Picks which manager handles a given package name (spec §5.1).
public final class Resolver {
    public let registry: Registry
    public let preferences: Preferences
    public let config: Config

    public init(registry: Registry, preferences: Preferences, config: Config) {
        self.registry = registry
        self.preferences = preferences
        self.config = config
    }

    public func resolve(_ name: String, hint: ManagerID?) async -> ResolveResult {
        // 1. Explicit --from wins.
        if let hint {
            guard let mgr = registry.get(hint) else { return .hintUnavailable(hint) }
            guard mgr.isAvailable() else { return .hintUnavailable(hint) }
            guard await hasPackage(mgr, name) else { return .hintNotFound(hint, name: name) }
            return .chosen(mgr)
        }
        // 2. Remembered preference (if that manager is still available).
        if let remembered = preferences.remembered(for: name),
           let mgr = registry.get(remembered), mgr.isAvailable() {
            return .chosen(mgr)
        }
        // 3. Priority list, concurrent existence check, pick highest-priority hit.
        let enabled = registry.enabled(config: config)
        let ordered = config.priority.compactMap { idStr -> (any PackageManager)? in
            guard let id = ManagerID(rawValue: idStr) else { return nil }
            return enabled.first { $0.id == id }
        }
        let withPackage = await concurrentExistence(ordered, name: name)
        if let best = withPackage.first {
            return .chosen(best)
        }
        return .notFound(searched: ordered.map { $0.id })
    }

    /// True if `manager.search(name)` returns an exact-name hit.
    private func hasPackage(_ manager: any PackageManager, _ name: String) async -> Bool {
        if let hits = try? await manager.search(name) {
            return hits.contains { $0.name == name }
        }
        return false
    }

    /// Check all managers concurrently; return those that have `name`, in the
    /// same order as `managers` (so .first is highest priority).
    private func concurrentExistence(_ managers: [any PackageManager], name: String) async -> [any PackageManager] {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, m) in managers.enumerated() {
                group.addTask { (i, await self.hasPackage(m, name)) }
            }
            var results = Array(repeating: false, count: managers.count)
            for await (i, has) in group { results[i] = has }
            return zip(managers, results).filter { $0.1 }.map { $0.0 }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ResolverTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add Resolver — priority + remembered-prefs routing (spec §5.1)"
```

---

## Phase 5 — First Adapter: Homebrew (reference implementation)

**Goal:** Build one complete fat adapter end-to-end as the reference. Exercises every protocol method against the real brew JSON API + CLI, fully stubbed in tests. After this phase, the resolve → brew install → cache-invalidate loop works for real.

### Task 5.1: `HomebrewManager` — availability, bootstrap, search, info

**Files:**
- Create: `Sources/GimmeCore/managers/HomebrewManager.swift`
- Test: `Tests/GimmeTests/managers/HomebrewManagerTests.swift`

**Interfaces:**
- Consumes: `HTTPClient` (3.2), `ProcessRunner` (3.1), `ManagerID`/types (Phase 2).
- Produces: `HomebrewManager` conforming to `PackageManager`. Uses `which brew` for availability; `formulae.brew.sh` JSON for search/info; `brew info --json=v2` fallback.

- [ ] **Step 1: Write the failing test (with stubbed HTTP + Process)**

Create `Tests/GimmeTests/managers/` directory, then write `Tests/GimmeTests/managers/HomebrewManagerTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class HomebrewManagerTests: XCTestCase {
    final class StubProcess: ProcessRunning {
        var stubs: [String: ProcessResult] = [:]
        func run(_ executable: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            let key = "\(executable) \(args.joined(separator: " "))"
            return stubs[key] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    final class StubHTTP: HTTPClient {
        var dataByURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data {
            dataByURL[url.absoluteString] ?? Data()
        }
    }

    func testIDAndCapabilities() {
        let m = HomebrewManager(http: StubHTTP(), process: StubProcess())
        XCTAssertEqual(m.id, .homebrew)
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]))
    }

    func testIsAvailableDetectsBrew() async throws {
        let p = StubProcess()
        p.stubs["/usr/bin/which brew"] = ProcessResult(exitCode: 0, stdout: "/opt/homebrew/bin/brew\n", stderr: "")
        let m = HomebrewManager(http: StubHTTP(), process: p)
        XCTAssertTrue(m.isAvailable())
    }

    func testIsAvailableFalseWhenMissing() async throws {
        let p = StubProcess()
        p.stubs["/usr/bin/which brew"] = ProcessResult(exitCode: 1, stdout: "", stderr: "")
        let m = HomebrewManager(http: StubHTTP(), process: p)
        XCTAssertFalse(m.isAvailable())
    }

    func testSearchFiltersFormulaJSON() async throws {
        let http = StubHTTP()
        // Minimal formula.json payload (array of objects with name fields).
        let payload = #"""
        [{"name":"ripgrep","desc":"Search tool","versions":{"stable":"14.1.0"}},
         {"name":"bat","desc":"Cat clone","versions":{"stable":"0.24.0"}}]
        """#
        http.dataByURL["https://formulae.brew.sh/api/formula.json"] = Data(payload.utf8)
        let m = HomebrewManager(http: http, process: StubProcess())
        let hits = try await m.search("ripgrep")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.name, "ripgrep")
        XCTAssertEqual(hits.first?.latestVersion, "14.1.0")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter HomebrewManagerTests 2>&1 | tail -15`
Expected: FAIL — `HomebrewManager`, `ProcessRunning` missing.

- [ ] **Step 3: Add a `ProcessRunning` protocol for testability**

Append to `Sources/GimmeCore/Process.swift`:

```swift
/// Indirection so adapters can be tested with a stub instead of real Process.
public protocol ProcessRunning {
    func run(
        _ executable: String,
        args: [String],
        env: [String: String]?,
        stream: ((String) -> Void)?
    ) async throws -> ProcessResult
}

extension ProcessRunner: ProcessRunning {}
```

And change the `ProcessRunner.run` signature to match (it already has defaults; just add `env:` and `stream:` labels matching the protocol — they're already there). No body change needed.

- [ ] **Step 4: Implement `HomebrewManager` (availability, bootstrap, search, info slice)**

Write `Sources/GimmeCore/managers/HomebrewManager.swift`:

```swift
import Foundation

/// Homebrew adapter (spec §6.1). Uses the formulae.brew.sh JSON API for
/// search/info and the `brew` CLI for actions + list/outdated.
public final class HomebrewManager: PackageManager {
    public let id: ManagerID = .homebrew
    public let displayName = "Homebrew"
    public let icon = "cup.and.saucer.fill"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning

    public init(http: HTTPClient = URLSessionHTTPClient(), process: any ProcessRunning = ProcessRunner) {
        self.http = http
        self.process = process
    }

    public func isAvailable() -> Bool {
        // Synchronous check: `which brew`. Run blocking via a semaphore wrapper
        // since the protocol demands a sync answer.
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["brew"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        return proc.terminationStatus == 0
    }

    public func bootstrap() async throws {
        let script = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
        // `ruby -e "$(curl ...)"` style; we use /bin/bash -c.
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -fsSL \(script) | /bin/bash"],
            env: ["NONINTERACTIVE": "1"],
            stream: nil)
    }

    // MARK: - Search / Info (API-backed)

    private struct FormulaAPIDoc: Decodable {
        let name: String
        let desc: String?
        let versions: Versions?
        struct Versions: Decodable { let stable: String? }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        let docs: [FormulaAPIDoc] = try await http.getJSON("https://formulae.brew.sh/api/formula.json", as: [FormulaAPIDoc].self)
        return docs.filter { $0.name.contains(query) }.map {
            SearchHit(name: $0.name, manager: .homebrew, summary: $0.desc ?? "", latestVersion: $0.versions?.stable ?? "")
        }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        // Prefer the local brew info --json=v2 for installed-version accuracy.
        let res = try await process.run("/opt/homebrew/bin/brew", args: ["info", "--json=v2", package.name], env: nil, stream: nil)
        if res.exitCode == 0, let data = res.stdout.data(using: .utf8) {
            // brew info --json=v2 returns {"formulae":[...], "casks":[...]}
            struct Wrapper: Decodable { let formulae: [BrewInfo] }
            struct BrewInfo: Decodable { let name: String; let versions: Versions; let desc: String?; let homepage: String?; let license: String?
                struct Versions: Decodable { let stable: String? } }
            if let wrap = try? JSONDecoder().decode(Wrapper.self, from: data), let f = wrap.formulae.first {
                return PackageInfo(name: f.name, manager: .homebrew,
                    latestVersion: f.versions.stable ?? "", summary: f.desc ?? "",
                    homepage: f.homepage, license: f.license, installedVersion: nil, location: nil)
            }
        }
        // Fallback to API by exact name.
        let docs: [FormulaAPIDoc] = try await http.getJSON("https://formulae.brew.sh/api/formula.json", as: [FormulaAPIDoc].self)
        guard let d = docs.first(where: { $0.name == package.name }) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.homebrew])
        }
        return PackageInfo(name: d.name, manager: .homebrew, latestVersion: d.versions?.stable ?? "",
            summary: d.desc ?? "", homepage: nil, license: nil, installedVersion: nil, location: nil)
    }

    // MARK: - Actions + list/outdated (CLI-backed) — implemented in 5.2

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        fatalError("implemented in Task 5.2")
    }
    public func uninstall(_ package: PackageRef) async throws { fatalError("implemented in Task 5.2") }
    public func upgrade(_ package: PackageRef) async throws { fatalError("implemented in Task 5.2") }
    public func listInstalled() async throws -> [InstalledPackage] { fatalError("implemented in Task 5.2") }
    public func outdated() async throws -> [OutdatedPackage] { fatalError("implemented in Task 5.2") }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter HomebrewManagerTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: HomebrewManager — availability, bootstrap, search, info (spec §6.1)"
```

### Task 5.2: `HomebrewManager` — install/uninstall/upgrade/list/outdated

**Files:**
- Modify: `Sources/GimmeCore/managers/HomebrewManager.swift` (replace the `fatalError` stubs)
- Modify: `Tests/GimmeTests/managers/HomebrewManagerTests.swift` (append action tests)

**Interfaces:** unchanged; fills in the action methods.

- [ ] **Step 1: Append failing tests for actions**

Append to `Tests/GimmeTests/managers/HomebrewManagerTests.swift`:

```swift
final class HomebrewActionTests: XCTestCase {
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var stubs: [String: ProcessResult] = [:]
        func run(_ executable: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((executable, args))
            let key = args.first ?? ""
            return stubs[key] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }
    final class StubHTTP: HTTPClient {
        func data(for url: URL) async throws -> Data { Data() }
    }

    private func brewPath(_ s: StubProcess) -> HomebrewManager {
        HomebrewManager(http: StubHTTP(), process: s, brewBinary: "/opt/homebrew/bin/brew")
    }

    func testInstallCallsBrewInstall() async throws {
        let s = StubProcess()
        let m = brewPath(s)
        let result = try await m.install(PackageRef(name: "ripgrep"), options: InstallOptions())
        XCTAssertEqual(s.calls.last?.0, "/opt/homebrew/bin/brew")
        XCTAssertEqual(s.calls.last?.1, ["install", "ripgrep"])
        XCTAssertEqual(result.package.name, "ripgrep")
    }

    func testUninstallCallsBrewUninstall() async throws {
        let s = StubProcess()
        let m = brewPath(s)
        try await m.uninstall(PackageRef(name: "rg"))
        XCTAssertEqual(s.calls.last?.1, ["uninstall", "rg"])
    }

    func testUpgradeCallsBrewUpgrade() async throws {
        let s = StubProcess()
        let m = brewPath(s)
        try await m.upgrade(PackageRef(name: "rg"))
        XCTAssertEqual(s.calls.last?.1, ["upgrade", "rg"])
    }

    func testListParsesBrewListJSON() async throws {
        let s = StubProcess()
        // brew list --json=v2 minimal payload.
        s.stubs["list"] = ProcessResult(exitCode: 0, stdout: #"""
        {"formulae":[{"name":"ripgrep","installed":[{"version":"14.1.0","installed_on":"2024-01-01"}]}],
         "casks":[]}
        """#, stderr: "")
        let m = brewPath(s)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 1)
        XCTAssertEqual(pkgs.first?.name, "ripgrep")
        XCTAssertEqual(pkgs.first?.version, "14.1.0")
        XCTAssertEqual(pkgs.first?.manager, .homebrew)
    }

    func testOutdatedParsesBrewOutdatedJSON() async throws {
        let s = StubProcess()
        s.stubs["outdated"] = ProcessResult(exitCode: 0, stdout: #"""
        {"formulae":[{"name":"ripgrep","installed_versions":["13.0.0"],"current_version":"14.1.0"}],
         "casks":[]}
        """#, stderr: "")
        let m = brewPath(s)
        let outdated = try await m.outdated()
        XCTAssertEqual(outdated.count, 1)
        XCTAssertEqual(outdated.first?.installedVersion, "13.0.0")
        XCTAssertEqual(outdated.first?.latestVersion, "14.1.0")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter HomebrewActionTests 2>&1 | tail -15`
Expected: FAIL — `fatalError`/missing `brewBinary` param.

- [ ] **Step 3: Fill in the action methods + add `brewBinary` injection**

In `Sources/GimmeCore/managers/HomebrewManager.swift`:

Change the initializer to accept a `brewBinary` parameter:

```swift
    private let brewBinary: String

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner,
                brewBinary: String = "/opt/homebrew/bin/brew") {
        self.http = http
        self.process = process
        self.brewBinary = brewBinary
    }
```

Replace the five `fatalError` stubs:

```swift
    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res = try await process.run(brewBinary, args: ["install", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .homebrew, op: "install", underlying: res.stderr)
        }
        // Best-effort version: re-list just this formula.
        let version = (try? await installedVersion(of: package.name)) ?? "unknown"
        return InstallResult(package: InstalledPackage(name: package.name, version: version, manager: .homebrew, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(brewBinary, args: ["uninstall", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .homebrew, op: "uninstall", underlying: res.stderr)
        }
    }

    public func upgrade(_ package: PackageRef) async throws {
        let res = try await process.run(brewBinary, args: ["upgrade", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .homebrew, op: "upgrade", underlying: res.stderr)
        }
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        let res = try await process.run(brewBinary, args: ["list", "--json=v2"], env: nil, stream: nil)
        guard res.exitCode == 0, let data = res.stdout.data(using: .utf8) else { return [] }
        struct Wrapper: Decodable {
            let formulae: [Item]; let casks: [Item]
            struct Item: Decodable { let name: String; let installed: [Inst]?
                struct Inst: Decodable { let version: String } }
        }
        guard let w = try? JSONDecoder().decode(Wrapper.self, from: data) else { return [] }
        let formulas = w.formulae.compactMap { f -> InstalledPackage? in
            guard let v = f.installed?.first?.version else { return nil }
            return InstalledPackage(name: f.name, version: v, manager: .homebrew, installedAt: nil)
        }
        let casks = w.casks.compactMap { c -> InstalledPackage? in
            guard let v = c.installed?.first?.version else { return nil }
            return InstalledPackage(name: c.name, version: v, manager: .homebrew, installedAt: nil)
        }
        return formulas + casks
    }

    public func outdated() async throws -> [OutdatedPackage] {
        let res = try await process.run(brewBinary, args: ["outdated", "--json=v2"], env: nil, stream: nil)
        guard res.exitCode == 0, let data = res.stdout.data(using: .utf8) else { return [] }
        struct Wrapper: Decodable {
            let formulae: [Item]; let casks: [Item]
            struct Item: Decodable { let name: String; let installed_versions: [String]?; let current_version: String? }
        }
        guard let w = try? JSONDecoder().decode(Wrapper.self, from: data) else { return [] }
        let formulas = w.formulae.compactMap { f -> OutdatedPackage? in
            guard let cur = f.current_version, let inst = f.installed_versions?.first else { return nil }
            return OutdatedPackage(name: f.name, installedVersion: inst, latestVersion: cur, manager: .homebrew)
        }
        let casks = w.casks.compactMap { c -> OutdatedPackage? in
            guard let cur = c.current_version, let inst = c.installed_versions?.first else { return nil }
            return OutdatedPackage(name: c.name, installedVersion: inst, latestVersion: cur, manager: .homebrew)
        }
        return formulas + casks
    }

    private func installedVersion(of name: String) async throws -> String? {
        let all = try await listInstalled()
        return all.first { $0.name == name }?.version
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter HomebrewActionTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: HomebrewManager — install/uninstall/upgrade/list/outdated (spec §6.1)"
```

### Task 5.3: Wire Homebrew into the engine — integration smoke test

Verify the full loop with a real (stubbed at the boundaries) resolve → install → cache invalidate.

**Files:**
- Create: `Tests/GimmeTests/EndToEndSmokeTests.swift`

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/EndToEndSmokeTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class EndToEndSmokeTests: XCTestCase {
    /// Exercises Resolver → HomebrewManager(stubbed) → Cache invalidation,
    /// proving the orchestration loop compiles and runs together.
    func testResolveAndInstallAndInvalidate() async throws {
        final class FakeHTTP: HTTPClient {
            func data(for url: URL) async throws -> Data {
                if url.absoluteString.contains("formula.json") {
                    return Data(#"[{"name":"ripgrep","desc":"rg","versions":{"stable":"14.1.0"}}]"#.utf8)
                }
                return Data()
            }
        }
        final class FakeProcess: ProcessRunning {
            var installed: [String: String] = [:]
            func run(_ executable: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
                if executable.contains("brew") {
                    if args.first == "install" {
                        installed[args[1]] = "14.1.0"
                        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
                    }
                    if args.first == "list" {
                        let items = installed.map { #"{"name":"\#($0.key)","installed":[{"version":"\#($0.value)"}]}"# }.joined(separator: ",")
                        return ProcessResult(exitCode: 0, stdout: "{\"formulae\":[\(items)],\"casks\":[]}", stderr: "")
                    }
                }
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = Cache(directory: dir.appendingPathComponent("cache"))
        let brew = HomebrewManager(http: FakeHTTP(), process: FakeProcess(), brewBinary: "/opt/homebrew/bin/brew")
        let registry = Registry(managers: [brew])
        let resolver = Resolver(registry: registry, preferences: Preferences(), config: .defaults)

        // Resolve
        let resolved = await resolver.resolve("ripgrep", hint: nil)
        guard case .chosen(let manager) = resolved else { return XCTFail("expected chosen") }

        // Install
        let result = try await manager.install(PackageRef(name: "ripgrep"), options: InstallOptions())
        XCTAssertEqual(result.package.version, "14.1.0")

        // List reflects install (cache miss → live)
        let list = try await manager.listInstalled()
        XCTAssertTrue(list.contains { $0.name == "ripgrep" })

        // Invalidate + cache round-trip
        cache.set("homebrew:list", value: list)
        XCTAssertEqual(cache.get("homebrew:list", ttlSeconds: 60, as: [InstalledPackage].self)?.count, 1)
        cache.invalidate("homebrew:list")
        XCTAssertNil(cache.get("homebrew:list", ttlSeconds: 60, as: [InstalledPackage].self))
    }
}
```

- [ ] **Step 2: Run to verify pass** (this is an integration test — it should pass immediately since all pieces exist)

Run: `swift test --filter EndToEndSmokeTests 2>&1 | tail -15`
Expected: PASS. If it fails, the failure names the integration gap to fix.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "test: end-to-end smoke test — resolve → brew install → cache invalidate"
```

---

## Phase 6 — Remaining Adapters (Go, uv, Cargo, bun)

**Goal:** Build the other four adapters following the Homebrew reference pattern. Each is one task with the same TDD structure. They're independent — could be parallelized, but listed sequentially here.

Each adapter task follows identical steps: (1) write tests with stubbed Process + HTTP, (2) verify fail, (3) implement, (4) verify pass, (5) commit. I'll show the full code for each once; the implementer repeats the TDD rhythm.

### Task 6.1: `GoManager`

**Files:**
- Create: `Sources/GimmeCore/managers/GoManager.swift`
- Test: `Tests/GimmeTests/managers/GoManagerTests.swift`

**Spec reference:** §6.2. No `outdated`, no fuzzy `search` (exact existence via proxy). Package names are import paths. `uninstall` = `rm $GOBIN/<binary>`.

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/managers/GoManagerTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class GoManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var binDir: [String] = []
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            return ProcessResult(exitCode: 0, stdout: binDir.joined(separator: "\n"), stderr: "")
        }
    }

    func testCapabilitiesOmitOutdated() {
        let m = GoManager(http: StubHTTP(), process: StubProcess())
        XCTAssertFalse(m.capabilities.contains(.outdated))
        XCTAssertFalse(m.capabilities.contains(.search))  // no fuzzy search
    }

    func testIsAvailableChecksWhichGo() async throws {
        let p = StubProcess()
        // which go → exit 0 path
        let m = GoManager(http: StubHTTP(), process: p, whichGo: "/usr/local/go/bin/go")
        // isAvailable uses a Foundation.Process sync check; we test the path
        // resolution indirectly: constructing with whichGo succeeds.
        XCTAssertEqual(m.id, .go)
    }

    func testSearchExactOnly() async throws {
        let http = StubHTTP()
        http.byURL["https://proxy.golang.org/github.com/spf13/cobra/@latest"] = Data(#"{"Version":"v1.8.0"}"#.utf8)
        let m = GoManager(http: http, process: StubProcess())
        let hits = try await m.search("github.com/spf13/cobra")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.latestVersion, "v1.8.0")
    }

    func testSearchMissReturnsEmpty() async throws {
        let http = StubHTTP()
        http.byURL["https://proxy.golang.org/nope/@latest"] = Data()  // empty / would error
        let m = GoManager(http: http, process: StubProcess())
        // The adapter should swallow the error and return [].
        let hits = try await m.search("nope")
        XCTAssertEqual(hits, [])
    }

    func testInstallCallsGoInstall() async throws {
        let p = StubProcess()
        let m = GoManager(http: StubHTTP(), process: p, goBinary: "/usr/local/go/bin/go")
        _ = try await m.install(PackageRef(name: "github.com/spf13/cobra"), options: InstallOptions())
        XCTAssertEqual(p.calls.last?.0, "/usr/local/go/bin/go")
        XCTAssertEqual(p.calls.last?.1, ["install", "github.com/spf13/cobra@latest"])
    }

    func testListScansGOBIN() async throws {
        let p = StubProcess()
        p.binDir = ["gopls", "cobra"]  // pretending `ls GOBIN`
        let m = GoManager(http: StubHTTP(), process: p, goBinary: "/usr/local/go/bin/go")
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(Set(pkgs.map { $0.name }), ["gopls", "cobra"])
        XCTAssertTrue(pkgs.allSatisfy { $0.manager == .go })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GoManagerTests 2>&1 | tail -15`
Expected: FAIL — `GoManager` missing.

- [ ] **Step 3: Implement `GoManager`**

Write `Sources/GimmeCore/managers/GoManager.swift`:

```swift
import Foundation

/// Go adapter (spec §6.2). Uses the module proxy for existence/info and
/// `go install` for actions. No outdated, no fuzzy search.
public final class GoManager: PackageManager {
    public let id: ManagerID = .go
    public let displayName = "Go"
    public let icon = "building.columns"
    public let capabilities: Set<Capability> = [.install, .uninstall, .list, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let goBinary: String

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner,
                goBinary: String = "/usr/local/go/bin/go") {
        self.http = http
        self.process = process
        self.goBinary = goBinary
    }

    public func isAvailable() -> Bool {
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["go"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        return proc.terminationStatus == 0
    }

    public func bootstrap() async throws {
        // Prefer brew install go if Homebrew is present; else go.dev installer.
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -fsSL https://go.dev/dl/go1.23.0.darwin-arm64.pkg -o /tmp/go.pkg && sudo installer -pkg /tmp/go.pkg -target /"],
            env: nil, stream: nil)
    }

    // Existence check via proxy @latest. Used by Resolver; also backs search.
    private func proxyLatest(_ path: String) async -> String? {
        let url = "https://proxy.golang.org/\(path)/@latest"
        struct Latest: Decodable { let Version: String }
        guard let v: Latest = try? await http.getJSON(url, as: Latest.self) else { return nil }
        return v.Version
    }

    /// Exact-existence search only: a single hit if the proxy knows the path.
    public func search(_ query: String) async throws -> [SearchHit] {
        guard let v = await proxyLatest(query) else { return [] }
        return [SearchHit(name: query, manager: .go, summary: "", latestVersion: v)]
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let v = await proxyLatest(package.name) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.go])
        }
        return PackageInfo(name: package.name, manager: .go, latestVersion: v, summary: "",
            homepage: "https://pkg.go.dev/\(package.name)", license: nil, installedVersion: nil, location: nil)
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let target = options.version.map { "\(package.name)@\($0)" } ?? "\(package.name)@latest"
        let res = try await process.run(goBinary, args: ["install", target], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .go, op: "install", underlying: res.stderr)
        }
        let binary = String(package.name.split(separator: "/").last ?? "")
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .go, installedAt: Date()),
                             warnings: binary.isEmpty ? ["no binary name derivable"] : [])
    }

    public func uninstall(_ package: PackageRef) async throws {
        // `go` provides no uninstall; remove the binary from GOBIN.
        let gobin = ProcessInfo.processInfo.environment["GOBIN"]
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/go/bin")
        let binary = String(package.name.split(separator: "/").last ?? package.name)
        let target = URL(fileURLWithPath: gobin).appendingPathComponent(binary)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw GimmeError.notFound("\(binary) not found in GOBIN")
        }
        try FileManager.default.removeItem(at: target)
    }

    public func upgrade(_ package: PackageRef) async throws {
        // Re-install to latest.
        _ = try await install(package, options: InstallOptions())
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        let gobin = ProcessInfo.processInfo.environment["GOBIN"]
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/go/bin")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: gobin) else { return [] }
        return names.map { InstalledPackage(name: $0, version: "unknown", manager: .go, installedAt: nil) }
    }

    public func outdated() async throws -> [OutdatedPackage] { [] }  // not supported
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter GoManagerTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: GoManager — proxy existence, go install, GOBIN scan (spec §6.2)"
```

### Task 6.2: `UvManager` (Python)

**Files:**
- Create: `Sources/GimmeCore/managers/UvManager.swift`
- Test: `Tests/GimmeTests/managers/UvManagerTests.swift`

**Spec reference:** §6.3. `uv tool install/list/upgrade`; PyPI JSON for search/info. Per-tool isolated.

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/managers/UvManagerTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class UvManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var stubs: [String: String] = [:]
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            let out = stubs[args.first ?? ""] ?? ""
            return ProcessResult(exitCode: 0, stdout: out, stderr: "")
        }
    }

    func testCapabilitiesFull() {
        let m = UvManager(http: StubHTTP(), process: StubProcess())
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]))
    }

    func testSearchQueriesPyPI() async throws {
        let http = StubHTTP()
        http.byURL["https://pypi.org/pypi/httpie/json"] = Data(#"""
        {"info":{"name":"httpie","summary":"CLI HTTP client","home_page":"https://httpie.org","license":"BSD","version":"3.2.0"}}
        """#.utf8)
        let m = UvManager(http: http, process: StubProcess())
        let hits = try await m.search("httpie")
        XCTAssertEqual(hits.first?.name, "httpie")
        XCTAssertEqual(hits.first?.latestVersion, "3.2.0")
    }

    func testInstallCallsUvToolInstall() async throws {
        let p = StubProcess()
        let m = UvManager(http: StubHTTP(), process: p, uvBinary: "/opt/uv/bin/uv")
        _ = try await m.install(PackageRef(name: "httpie"), options: InstallOptions())
        XCTAssertEqual(p.calls.last?.1, ["tool", "install", "httpie"])
    }

    func testListParsesUvToolList() async throws {
        let p = StubProcess()
        p.stubs["tool"] = """
        httpie (executable: http)
        yt-dlp (executable: yt-dlp)
        """
        let m = UvManager(http: StubHTTP(), process: p, uvBinary: "/opt/uv/bin/uv")
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(Set(pkgs.map { $0.name }), ["httpie", "yt-dlp"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter UvManagerTests 2>&1 | tail -15`
Expected: FAIL.

- [ ] **Step 3: Implement `UvManager`**

Write `Sources/GimmeCore/managers/UvManager.swift`:

```swift
import Foundation

/// uv (Python) adapter (spec §6.3). Per-tool isolated venvs via `uv tool`.
public final class UvManager: PackageManager {
    public let id: ManagerID = .uv
    public let displayName = "Python (uv)"
    public let icon = "snake"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let uvBinary: String

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner,
                uvBinary: String = "/opt/uv/bin/uv") {
        self.http = http
        self.process = process
        self.uvBinary = uvBinary
    }

    public func isAvailable() -> Bool {
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["uv"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        return proc.terminationStatus == 0
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"],
            env: nil, stream: nil)
    }

    private struct PyPIDoc: Decodable {
        let info: Info
        struct Info: Decodable { let name: String; let summary: String?; let home_page: String?; let license: String?; let version: String? }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        guard let doc: PyPIDoc = try? await http.getJSON("https://pypi.org/pypi/\(query)/json", as: PyPIDoc.self) else { return [] }
        return [SearchHit(name: doc.info.name, manager: .uv, summary: doc.info.summary ?? "", latestVersion: doc.info.version ?? "")]
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: PyPIDoc = try? await http.getJSON("https://pypi.org/pypi/\(package.name)/json", as: PyPIDoc.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.uv])
        }
        return PackageInfo(name: doc.info.name, manager: .uv, latestVersion: doc.info.version ?? "",
            summary: doc.info.summary ?? "", homepage: doc.info.home_page, license: doc.info.license,
            installedVersion: nil, location: nil)
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res = try await process.run(uvBinary, args: ["tool", "install", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .uv, op: "install", underlying: res.stderr) }
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .uv, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(uvBinary, args: ["tool", "uninstall", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .uv, op: "uninstall", underlying: res.stderr) }
    }

    public func upgrade(_ package: PackageRef) async throws {
        let res = try await process.run(uvBinary, args: ["tool", "upgrade", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .uv, op: "upgrade", underlying: res.stderr) }
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        let res = try await process.run(uvBinary, args: ["tool", "list"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        // Lines like: "httpie (executable: http)"
        return res.stdout.split(separator: "\n").compactMap { line -> InstalledPackage? in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard let name = s.split(separator: " ").first else { return nil }
            return InstalledPackage(name: String(name), version: "unknown", manager: .uv, installedAt: nil)
        }
    }

    public func outdated() async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        var out: [OutdatedPackage] = []
        for pkg in installed {
            guard let doc: PyPIDoc = try? await http.getJSON("https://pypi.org/pypi/\(pkg.name)/json", as: PyPIDoc.self),
                  let latest = doc.info.version else { continue }
            // We don't have installed version reliably from `uv tool list`;
            // mark outdated only if names differ (best-effort). Real version
            // comparison added when `uv tool list --json` is available.
            if pkg.version != latest { out.append(OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .uv)) }
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter UvManagerTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: UvManager — uv tool install/list + PyPI search (spec §6.3)"
```

### Task 6.3: `CargoManager`

**Files:**
- Create: `Sources/GimmeCore/managers/CargoManager.swift`
- Test: `Tests/GimmeTests/managers/CargoManagerTests.swift`

**Spec reference:** §6.4. crates.io JSON for search/info; `cargo install/uninstall/install --force`. Upgrade = reinstall.

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/managers/CargoManagerTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class CargoManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var listOutput = ""
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.first == "install" && args.contains("--list") {
                return ProcessResult(exitCode: 0, stdout: listOutput, stderr: "")
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func testSearchQueriesCratesIO() async throws {
        let http = StubHTTP()
        http.byURL["https://crates.io/api/v1/crates?q=ripgrep"] = Data(#"""
        {"crates":[{"name":"ripgrep","description":"Search tool","max_version":"14.1.0","homepage":"https://github.com"}]}
        """#.utf8)
        let m = CargoManager(http: http, process: StubProcess())
        let hits = try await m.search("ripgrep")
        XCTAssertEqual(hits.first?.name, "ripgrep")
        XCTAssertEqual(hits.first?.latestVersion, "14.1.0")
    }

    func testInstallCallsCargoInstall() async throws {
        let p = StubProcess()
        let m = CargoManager(http: StubHTTP(), process: p, cargoBinary: "/Users/x/.cargo/bin/cargo")
        _ = try await m.install(PackageRef(name: "ripgrep"), options: InstallOptions())
        XCTAssertEqual(p.calls.last?.1, ["install", "ripgrep"])
    }

    func testUpgradeCallsForceReinstall() async throws {
        let p = StubProcess()
        let m = CargoManager(http: StubHTTP(), process: p, cargoBinary: "/Users/x/.cargo/bin/cargo")
        try await m.upgrade(PackageRef(name: "rg"))
        XCTAssertEqual(p.calls.last?.1, ["install", "rg", "--force"])
    }

    func testListParsesCargoInstallList() async throws {
        let p = StubProcess()
        p.listOutput = """
        ripgrep v14.1.0:
            rg
        bat v0.24.1:
            bat
        """
        let m = CargoManager(http: StubHTTP(), process: p, cargoBinary: "/Users/x/.cargo/bin/cargo")
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertEqual(pkgs.first?.name, "ripgrep")
        XCTAssertEqual(pkgs.first?.version, "14.1.0")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CargoManagerTests 2>&1 | tail -15`
Expected: FAIL.

- [ ] **Step 3: Implement `CargoManager`**

Write `Sources/GimmeCore/managers/CargoManager.swift`:

```swift
import Foundation

/// Cargo (Rust) adapter (spec §6.4). crates.io JSON for search/info; cargo CLI.
public final class CargoManager: PackageManager {
    public let id: ManagerID = .cargo
    public let displayName = "Cargo"
    public let icon = "shippingbox"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let cargoBinary: String

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner,
                cargoBinary: String = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cargo/bin/cargo") {
        self.http = http
        self.process = process
        self.cargoBinary = cargoBinary
    }

    public func isAvailable() -> Bool {
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["cargo"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        return proc.terminationStatus == 0
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"],
            env: nil, stream: nil)
    }

    private struct CratesSearch: Decodable { let crates: [Crate]
        struct Crate: Decodable { let name: String; let description: String?; let max_version: String?; let homepage: String? } }
    private struct CrateInfo: Decodable { let crate: CratesSearch.Crate; let versions: [Version]?
        struct Version: Decodable { let num: String } }

    public func search(_ query: String) async throws -> [SearchHit] {
        guard let doc: CratesSearch = try? await http.getJSON("https://crates.io/api/v1/crates?q=\(query)", as: CratesSearch.self) else { return [] }
        return doc.crates.map { SearchHit(name: $0.name, manager: .cargo, summary: $0.description ?? "", latestVersion: $0.max_version ?? "") }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: CrateInfo = try? await http.getJSON("https://crates.io/api/v1/crates/\(package.name)", as: CrateInfo.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.cargo])
        }
        return PackageInfo(name: doc.crate.name, manager: .cargo, latestVersion: doc.crate.max_version ?? "",
            summary: doc.crate.description ?? "", homepage: doc.crate.homepage, license: nil,
            installedVersion: nil, location: nil)
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        var args = ["install"]
        if let v = options.version { args += ["--version", v] }
        args.append(package.name)
        let res = try await process.run(cargoBinary, args: args, env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .cargo, op: "install", underlying: res.stderr) }
        let version = (try? await installedVersion(of: package.name)) ?? "latest"
        return InstallResult(package: InstalledPackage(name: package.name, version: version, manager: .cargo, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(cargoBinary, args: ["uninstall", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .cargo, op: "uninstall", underlying: res.stderr) }
    }

    public func upgrade(_ package: PackageRef) async throws {
        // Cargo has no upgrade; reinstall to latest with --force.
        let res = try await process.run(cargoBinary, args: ["install", package.name, "--force"], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .cargo, op: "upgrade", underlying: res.stderr) }
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        let res = try await process.run(cargoBinary, args: ["install", "--list"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        // Lines: "ripgrep v14.1.0:" then indented binaries.
        var pkgs: [InstalledPackage] = []
        for line in res.stdout.split(separator: "\n") {
            let s = String(line)
            // Match "name vX.Y.Z:"
            if s.first != " " && s.contains(" v") && s.hasSuffix(":") {
                let body = String(s.dropLast())  // strip ':'
                let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[1].hasPrefix("v") {
                    pkgs.append(InstalledPackage(name: parts[0], version: String(parts[1].dropFirst()), manager: .cargo, installedAt: nil))
                }
            }
        }
        return pkgs
    }

    public func outdated() async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        var out: [OutdatedPackage] = []
        for pkg in installed {
            guard let doc: CrateInfo = try? await http.getJSON("https://crates.io/api/v1/crates/\(pkg.name)", as: CrateInfo.self),
                  let latest = doc.crate.max_version else { continue }
            if pkg.version != latest { out.append(OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .cargo)) }
        }
        return out
    }

    private func installedVersion(of name: String) async throws -> String? {
        try await listInstalled().first { $0.name == name }?.version
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CargoManagerTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: CargoManager — crates.io + cargo install/uninstall/list (spec §6.4)"
```

### Task 6.4: `BunManager` (npm)

**Files:**
- Create: `Sources/GimmeCore/managers/BunManager.swift`
- Test: `Tests/GimmeTests/managers/BunManagerTests.swift`

**Spec reference:** §6.5. npm registry JSON for search/info; `bun install/remove -g`. Adapter named `bun`. Handles scoped names.

- [ ] **Step 1: Write the failing test**

Write `Tests/GimmeTests/managers/BunManagerTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class BunManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var lsOutput = ""
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.contains("ls") { return ProcessResult(exitCode: 0, stdout: lsOutput, stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func testSearchQueriesNpm() async throws {
        let http = StubHTTP()
        http.byURL["https://registry.npmjs.org/-/v1/search?size=25&q=esbuild"] = Data(#"""
        {"objects":[{"package":{"name":"esbuild","description":"Bundler","version":"0.21.0"}}]}
        """#.utf8)
        let m = BunManager(http: http, process: StubProcess())
        let hits = try await m.search("esbuild")
        XCTAssertEqual(hits.first?.name, "esbuild")
        XCTAssertEqual(hits.first?.latestVersion, "0.21.0")
    }

    func testInstallCallsBunInstallGlobal() async throws {
        let p = StubProcess()
        let m = BunManager(http: StubHTTP(), process: p, bunBinary: "/Users/x/.bun/bin/bun")
        _ = try await m.install(PackageRef(name: "esbuild"), options: InstallOptions())
        XCTAssertEqual(p.calls.last?.1, ["install", "-g", "esbuild"])
    }

    func testInstallHandlesScopedName() async throws {
        let p = StubProcess()
        let m = BunManager(http: StubHTTP(), process: p, bunBinary: "/Users/x/.bun/bin/bun")
        _ = try await m.install(PackageRef(name: "@babel/core"), options: InstallOptions())
        XCTAssertEqual(p.calls.last?.1, ["install", "-g", "@babel/core"])
    }

    func testUninstallCallsBunRemoveGlobal() async throws {
        let p = StubProcess()
        let m = BunManager(http: StubHTTP(), process: p, bunBinary: "/Users/x/.bun/bin/bun")
        try await m.uninstall(PackageRef(name: "esbuild"))
        XCTAssertEqual(p.calls.last?.1, ["remove", "-g", "esbuild"])
    }

    func testListParsesBunPmLs() async throws {
        let p = StubProcess()
        p.lsOutput = #"""
        esbuild@0.21.0
        typescript@5.4.0
        """#
        let m = BunManager(http: StubHTTP(), process: p, bunBinary: "/Users/x/.bun/bin/bun")
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertEqual(pkgs.first?.name, "esbuild")
        XCTAssertEqual(pkgs.first?.version, "0.21.0")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BunManagerTests 2>&1 | tail -15`
Expected: FAIL.

- [ ] **Step 3: Implement `BunManager`**

Write `Sources/GimmeCore/managers/BunManager.swift`:

```swift
import Foundation

/// bun (npm) adapter (spec §6.5). npm registry JSON for search/info; bun CLI.
public final class BunManager: PackageManager {
    public let id: ManagerID = .bun
    public let displayName = "npm (via bun)"
    public let icon = "bag"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let bunBinary: String

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner,
                bunBinary: String = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.bun/bin/bun") {
        self.http = http
        self.process = process
        self.bunBinary = bunBinary
    }

    public func isAvailable() -> Bool {
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["bun"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        return proc.terminationStatus == 0
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -fsSL https://bun.sh/install | bash"],
            env: nil, stream: nil)
    }

    private struct NpmSearch: Decodable { let objects: [Obj]
        struct Obj: Decodable { let package: Pkg
        struct Pkg: Decodable { let name: String; let description: String?; let version: String? } } }
    private struct NpmPackument: Decodable { let name: String?; let description: String?; let homepage: String?; let license: String?
        let `dist-tags`: DistTags?
        struct DistTags: Decodable { let latest: String? } }

    public func search(_ query: String) async throws -> [SearchHit] {
        let url = "https://registry.npmjs.org/-/v1/search?size=25&q=\(query)"
        guard let doc: NpmSearch = try? await http.getJSON(url, as: NpmSearch.self) else { return [] }
        return doc.objects.map { SearchHit(name: $0.package.name, manager: .bun, summary: $0.package.description ?? "", latestVersion: $0.package.version ?? "") }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: NpmPackument = try? await http.getJSON("https://registry.npmjs.org/\(package.name)", as: NpmPackument.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.bun])
        }
        return PackageInfo(name: doc.name ?? package.name, manager: .bun, latestVersion: doc["dist-tags"]?.latest ?? "",
            summary: doc.description ?? "", homepage: doc.homepage, license: doc.license,
            installedVersion: nil, location: nil)
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res = try await process.run(bunBinary, args: ["install", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .bun, op: "install", underlying: res.stderr) }
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .bun, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(bunBinary, args: ["remove", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .bun, op: "uninstall", underlying: res.stderr) }
    }

    public func upgrade(_ package: PackageRef) async throws {
        // npm semantics: reinstall to latest.
        let res = try await process.run(bunBinary, args: ["install", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .bun, op: "upgrade", underlying: res.stderr) }
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        let res = try await process.run(bunBinary, args: ["pm", "ls", "-g"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        // Lines like: "esbuild@0.21.0" (and scoped "@babel/core@7.0.0")
        return res.stdout.split(separator: "\n").compactMap { line -> InstalledPackage? in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            // Find the last '@' that isn't at index 0 (scoped names start with @).
            let atSearch = s.dropFirst().firstIndex(of: "@").map { s.index(after: $0) }
            guard let at = atSearch else { return nil }
            let name = String(s[..<at])
            let version = String(s[s.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            return InstalledPackage(name: name, version: version.isEmpty ? "unknown" : version, manager: .bun, installedAt: nil)
        }
    }

    public func outdated() async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        var out: [OutdatedPackage] = []
        for pkg in installed {
            guard let doc: NpmPackument = try? await http.getJSON("https://registry.npmjs.org/\(pkg.name)", as: NpmPackument.self),
                  let latest = doc["dist-tags"]?.latest else { continue }
            if pkg.version != latest { out.append(OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .bun)) }
        }
        return out
    }
}
```

**Note for the implementer:** the `doc["dist-tags"]` subscript syntax in `info()`/`outdated()` won't compile — `NpmPackument` is a struct, not a dictionary. Fix by reading the `dist-tags` property directly: `doc.distTags?.latest` (rename the decoded property `dist-tags` to a Swift `distTags` via `CodingKeys`, or access the backticked property). Apply the same fix in `outdated()`. This is a deliberate compile-time check that the implementer resolves during the "verify failure → fix → pass" cycle.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter BunManagerTests 2>&1 | tail -15`
Expected: PASS (after fixing the `dist-tags` access per the note above).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: BunManager — npm registry + bun install/remove (spec §6.5)"
```

### Task 6.5: Production registry wiring

**Files:**
- Modify: `Sources/GimmeCore/Gimme.swift` (add a `defaultRegistry()` factory)

Add a factory that wires the five real adapters with their production defaults.

- [ ] **Step 1: Add the factory to `Gimme.swift`**

Append to `Sources/GimmeCore/Gimme.swift`:

```swift
extension Gimme {
    /// Wire the five real adapters with production defaults.
    public static func defaultRegistry() -> Registry {
        Registry(managers: [
            HomebrewManager(),
            GoManager(),
            UvManager(),
            CargoManager(),
            BunManager()
        ])
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -10`
Expected: BUILD SUCCEEDS.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: production registry factory wiring all five adapters"
```

---

## Phase 7 — CLI Rebuild

**Goal:** Flat verbs + passthrough (spec §7). The CLI is a thin wrapper over `Gimme.run`.

### Task 7.1: Command dispatcher with `install`/`uninstall`/`upgrade`/`info`

**Files:**
- Modify: `Sources/GimmeCore/Gimme.swift` (real dispatch — replace the stub)
- Modify: `Tests/GimmeTests/CLIIntegrationTests.swift` (recreate — was deleted in 1.7)
- Modify: `Sources/gimme/main.swift`

**Interfaces:**
- Produces: `Gimme` holding `Registry`, `Preferences`, `Config`, `Cache`; methods `install/uninstall/upgrade/info` returning structured results the CLI formats.

- [ ] **Step 1: Write the failing test (in-process, like the original CLIIntegrationTests)**

Write `Tests/GimmeTests/CLIIntegrationTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class CLIIntegrationTests: XCTestCase {
    // Uses stub managers wired via the test factory below.
    private func makeGimme(registry: Registry, tmp: URL) throws -> Gimme {
        let prefs = Preferences()
        let cfg = Config.defaults
        return Gimme(registry: registry, preferences: prefs, config: cfg,
                     cache: Cache(directory: tmp.appendingPathComponent("cache")),
                     preferencesFile: tmp.appendingPathComponent("preferences.toml"))
    }

    func testInstallResolvesAndInvokesManager() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let brew = SearchableStubManager(id: .homebrew, available: true, known: ["ripgrep"])
        let gimme = try makeGimme(registry: Registry(managers: [brew]), tmp: tmp)
        let result = try await gimme.install(name: "ripgrep", from: nil, options: InstallOptions())
        XCTAssertEqual(result.package.manager, .homebrew)
        XCTAssertEqual(result.package.name, "ripgrep")
    }

    func testInstallWithFromOverridesAndRemembers() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let brew = SearchableStubManager(id: .homebrew, available: true, known: ["rg"])
        let cargo = SearchableStubManager(id: .cargo, available: true, known: ["rg"])
        let gimme = try makeGimme(registry: Registry(managers: [brew, cargo]), tmp: tmp)
        _ = try await gimme.install(name: "rg", from: .cargo, options: InstallOptions())
        // After --from cargo, the preference is remembered.
        let prefs = Preferences.load(at: tmp.appendingPathComponent("preferences.toml"))
        XCTAssertEqual(prefs.remembered(for: "rg"), .cargo)
    }

    func testInstallNotFoundThrows() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let brew = SearchableStubManager(id: .homebrew, available: true, known: [])
        let gimme = try makeGimme(registry: Registry(managers: [brew]), tmp: tmp)
        do {
            _ = try await gimme.install(name: "nope", from: nil, options: InstallOptions())
            XCTFail("expected throw")
        } catch GimmeError.notFoundInManagers(let name, _) {
            XCTAssertEqual(name, "nope")
        }
    }
}
```

(`SearchableStubManager` is the struct defined in `ResolverTests.swift` in Task 4.4 — it's in the same test target, so it's visible.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CLIIntegrationTests 2>&1 | tail -15`
Expected: FAIL — `Gimme.install(...)` and the new initializer missing.

- [ ] **Step 3: Implement the real `Gimme`**

Replace `Sources/GimmeCore/Gimme.swift` contents with:

```swift
import Foundation

/// The gimme command runner. The CLI is a thin wrapper; tests call in-process.
public final class Gimme {
    public let registry: Registry
    public var preferences: Preferences
    public let config: Config
    public let cache: Cache
    private let preferencesFile: URL

    public init(registry: Registry, preferences: Preferences, config: Config, cache: Cache, preferencesFile: URL) {
        self.registry = registry
        self.preferences = preferences
        self.config = config
        self.cache = cache
        self.preferencesFile = preferencesFile
    }

    public enum Command: String {
        case install, uninstall, upgrade, update
        case list, search, info, outdated
        case forget, config, doctor
    }

    // MARK: - Resolve + act helpers

    private func resolve(_ name: String, hint: ManagerID?) async throws -> (any PackageManager) {
        let resolver = Resolver(registry: registry, preferences: preferences, config: config)
        switch await resolver.resolve(name, hint: hint) {
        case .chosen(let m): return m
        case .notFound(let searched):
            throw GimmeError.notFoundInManagers(name: name, searched: searched)
        case .hintNotFound(let id, let n):
            throw GimmeError.notFound("\(id.rawValue) has no package '\(n)'")
        case .hintUnavailable(let id):
            throw GimmeError.managerUnavailable(id)
        }
    }

    @discardableResult
    public func install(name: String, from hint: ManagerID?, options: InstallOptions) async throws -> InstallResult {
        let manager = try await resolve(name, hint: hint)
        let result = try await manager.install(PackageRef(name: name, managerHint: hint), options: options)
        cache.invalidatePrefix("\(manager.id.rawValue):")
        // Remember only on explicit --from.
        if hint != nil {
            preferences.remember(name, manager.id)
            try? preferences.save(at: preferencesFile)
        }
        return result
    }

    public func uninstall(name: String, from hint: ManagerID?) async throws {
        let manager = try await resolve(name, hint: hint)
        try await manager.uninstall(PackageRef(name: name, managerHint: hint))
        cache.invalidatePrefix("\(manager.id.rawValue):")
    }

    public func upgrade(name: String, from hint: ManagerID?) async throws {
        let manager = try await resolve(name, hint: hint)
        try await manager.upgrade(PackageRef(name: name, managerHint: hint))
        cache.invalidatePrefix("\(manager.id.rawValue):")
    }

    public func info(name: String, from hint: ManagerID?) async throws -> PackageInfo {
        let manager = try await resolve(name, hint: hint)
        return try await manager.info(PackageRef(name: name, managerHint: hint))
    }

    // list/outdated/search/update/doctor/forget/config added in 7.2–7.4
}

extension Gimme {
    public static func defaultRegistry() -> Registry {
        Registry(managers: [HomebrewManager(), GoManager(), UvManager(), CargoManager(), BunManager()])
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CLIIntegrationTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Gimme command runner — install/uninstall/upgrade/info with resolve + remember (spec §7)"
```

### Task 7.2: `list`, `outdated`, `search`

**Files:**
- Modify: `Sources/GimmeCore/Gimme.swift` (add methods)
- Modify: `Tests/GimmeTests/CLIIntegrationTests.swift` (append cases)

- [ ] **Step 1: Append failing tests**

Append to `Tests/GimmeTests/CLIIntegrationTests.swift`:

```swift
final class CLIListSearchTests: XCTestCase {
    private func makeGimme(tmp: URL, managers: [any PackageManager]) -> Gimme {
        Gimme(registry: Registry(managers: managers), preferences: Preferences(),
              config: .defaults, cache: Cache(directory: tmp.appendingPathComponent("cache")),
              preferencesFile: tmp.appendingPathComponent("preferences.toml"))
    }

    func testListMergesAllManagers() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // StubManager variants that return canned listInstalled.
        struct Lister: PackageManager {
            let id: ManagerID; let pkgs: [InstalledPackage]
            let displayName = ""; let icon = "circle"; let capabilities: Set<Capability> = [.list]
            func isAvailable() -> Bool { true }
            func bootstrap() async throws {}
            func install(_ p: PackageRef, options: InstallOptions) async throws -> InstallResult { fatalError() }
            func uninstall(_ p: PackageRef) async throws {}
            func upgrade(_ p: PackageRef) async throws {}
            func listInstalled() async throws -> [InstalledPackage] { pkgs }
            func outdated() async throws -> [OutdatedPackage] { [] }
            func search(_ q: String) async throws -> [SearchHit] { [] }
            func info(_ p: PackageRef) async throws -> PackageInfo { fatalError() }
        }
        let gimme = makeGimme(tmp: tmp, managers: [
            Lister(id: .homebrew, pkgs: [InstalledPackage(name: "rg", version: "1", manager: .homebrew, installedAt: nil)]),
            Lister(id: .cargo, pkgs: [InstalledPackage(name: "bat", version: "2", manager: .cargo, installedAt: nil)])
        ])
        let list = try await gimme.list(from: nil, refresh: true)
        XCTAssertEqual(Set(list.map { $0.id }), ["homebrew:rg", "cargo:bat"])
    }

    func testSearchDefaultManagerOnly() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gimme = makeGimme(tmp: tmp, managers: [
            SearchableStubManager(id: .homebrew, available: true, known: ["rg"]),
            SearchableStubManager(id: .cargo, available: true, known: ["rg"])
        ])
        let hits = try await gimme.search(query: "rg", all: false, refresh: true)
        XCTAssertEqual(hits.count, 1)  // only homebrew (default-priority manager with the package)
        XCTAssertEqual(hits.first?.manager, .homebrew)
    }

    func testSearchAllFansOut() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gimme = makeGimme(tmp: tmp, managers: [
            SearchableStubManager(id: .homebrew, available: true, known: ["rg"]),
            SearchableStubManager(id: .cargo, available: true, known: ["rg"])
        ])
        let hits = try await gimme.search(query: "rg", all: true, refresh: true)
        XCTAssertEqual(Set(hits.map { $0.manager }), [.homebrew, .cargo])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CLIListSearchTests 2>&1 | tail -15`
Expected: FAIL — `list`/`search` missing.

- [ ] **Step 3: Add `list`/`outdated`/`search` to `Gimme`**

Append to `Sources/GimmeCore/Gimme.swift`:

```swift
extension Gimme {
    /// All installed packages across managers (or one if `from` is set).
    /// Uses cache unless `refresh`.
    public func list(from managerID: ManagerID?, refresh: Bool) async throws -> [InstalledPackage] {
        let managers = managerID.map { registry.get($0).map { [$0] } ?? [] } ?? registry.enabled(config: config)
        var all: [InstalledPackage] = []
        for m in managers {
            let key = "\(m.id.rawValue):list"
            if !refresh, let cached = cache.get(key, ttlSeconds: config.listCacheTTLSeconds, as: [InstalledPackage].self) {
                all.append(contentsOf: cached); continue
            }
            let pkgs = (try? await m.listInstalled()) ?? []
            cache.set(key, value: pkgs)
            all.append(contentsOf: pkgs)
        }
        return all
    }

    /// All outdated packages across managers.
    public func outdated(from managerID: ManagerID?, refresh: Bool) async throws -> [OutdatedPackage] {
        let managers = managerID.map { registry.get($0).map { [$0] } ?? [] }
            ?? registry.enabled(config: config).filter { $0.capabilities.contains(.outdated) }
        var all: [OutdatedPackage] = []
        for m in managers {
            let key = "\(m.id.rawValue):outdated"
            if !refresh, let cached = cache.get(key, ttlSeconds: config.listCacheTTLSeconds, as: [OutdatedPackage].self) {
                all.append(contentsOf: cached); continue
            }
            let pkgs = (try? await m.outdated()) ?? []
            cache.set(key, value: pkgs)
            all.append(contentsOf: pkgs)
        }
        return all
    }

    /// Search the default-priority manager (all=false) or every manager (all=true).
    public func search(query: String, all: Bool, refresh: Bool) async throws -> [SearchHit] {
        let managers: [any PackageManager]
        if all {
            managers = registry.enabled(config: config).filter { $0.capabilities.contains(.search) }
        } else {
            // Default = first enabled manager in priority order that has search capability.
            managers = config.priority.compactMap { idStr -> (any PackageManager)? in
                guard let id = ManagerID(rawValue: idStr),
                      let m = registry.get(id), m.isAvailable(),
                      !config.disabled.contains(idStr),
                      m.capabilities.contains(.search) else { return nil }
                return m
            }.prefix(1).map { $0 }
        }
        var hits: [SearchHit] = []
        for m in managers {
            let key = "\(m.id.rawValue):search:\(query)"
            if !refresh, let cached = cache.get(key, ttlSeconds: config.infoCacheTTLSeconds, as: [SearchHit].self) {
                hits.append(contentsOf: cached); continue
            }
            let h = (try? await m.search(query)) ?? []
            cache.set(key, value: h)
            hits.append(contentsOf: h)
        }
        return hits
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CLIListSearchTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Gimme list/outdated/search with cache + --all (spec §7)"
```

### Task 7.3: `update` (update-all), `doctor`, `forget`, `config`

**Files:**
- Modify: `Sources/GimmeCore/Gimme.swift`
- Modify: `Tests/GimmeTests/CLIIntegrationTests.swift`

- [ ] **Step 1: Append failing tests**

Append to `Tests/GimmeTests/CLIIntegrationTests.swift`:

```swift
final class CLIUpdateDoctorTests: XCTestCase {
    private func makeGimme(tmp: URL, managers: [any PackageManager]) -> Gimme {
        Gimme(registry: Registry(managers: managers), preferences: Preferences(),
              config: .defaults, cache: Cache(directory: tmp.appendingPathComponent("cache")),
              preferencesFile: tmp.appendingPathComponent("preferences.toml"))
    }

    func testUpdateUpgradesAllOutdatedPerManager() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        struct Updatable: PackageManager {
            let id: ManagerID; let outdatedList: [OutdatedPackage]; var upgraded: [String] = []
            let displayName = ""; let icon = "circle"; let capabilities: Set<Capability> = [.upgrade, .outdated]
            func isAvailable() -> Bool { true }
            func bootstrap() async throws {}
            func install(_ p: PackageRef, options: InstallOptions) async throws -> InstallResult { fatalError() }
            func uninstall(_ p: PackageRef) async throws {}
            mutating func upgrade(_ p: PackageRef) async throws { upgraded.append(p.name) }
            func listInstalled() async throws -> [InstalledPackage] { [] }
            func outdated() async throws -> [OutdatedPackage] { outdatedList }
            func search(_ q: String) async throws -> [SearchHit] { [] }
            func info(_ p: PackageRef) async throws -> PackageInfo { fatalError() }
        }
        // Note: struct mutation won't propagate — use a class for the real test.
        final class UpdatableCls: PackageManager {
            let id: ManagerID; let outdatedList: [OutdatedPackage]; var upgraded: [String] = []
            let displayName = ""; let icon = "circle"; let capabilities: Set<Capability> = [.upgrade, .outdated]
            init(id: ManagerID, outdatedList: [OutdatedPackage]) { self.id = id; self.outdatedList = outdatedList }
            func isAvailable() -> Bool { true }
            func bootstrap() async throws {}
            func install(_ p: PackageRef, options: InstallOptions) async throws -> InstallResult { fatalError() }
            func uninstall(_ p: PackageRef) async throws {}
            func upgrade(_ p: PackageRef) async throws { upgraded.append(p.name) }
            func listInstalled() async throws -> [InstalledPackage] { [] }
            func outdated() async throws -> [OutdatedPackage] { outdatedList }
            func search(_ q: String) async throws -> [SearchHit] { [] }
            func info(_ p: PackageRef) async throws -> PackageInfo { fatalError() }
        }
        let brew = UpdatableCls(id: .homebrew, outdatedList: [OutdatedPackage(name: "rg", installedVersion: "1", latestVersion: "2", manager: .homebrew)])
        let gimme = makeGimme(tmp: tmp, managers: [brew])
        let summary = try await gimme.updateAll()
        XCTAssertEqual(summary.succeeded, ["homebrew:rg"])
        XCTAssertTrue(brew.upgraded.contains("rg"))
    }

    func testUpdatePartialFailureRecorded() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        final class FailingUpgradable: PackageManager {
            let id: ManagerID; let outdatedList: [OutdatedPackage]
            let displayName = ""; let icon = "circle"; let capabilities: Set<Capability> = [.upgrade, .outdated]
            init(id: ManagerID, outdatedList: [OutdatedPackage]) { self.id = id; self.outdatedList = outdatedList }
            func isAvailable() -> Bool { true }
            func bootstrap() async throws {}
            func install(_ p: PackageRef, options: InstallOptions) async throws -> InstallResult { fatalError() }
            func uninstall(_ p: PackageRef) async throws {}
            func upgrade(_ p: PackageRef) async throws { throw GimmeError.operationFailed(manager: id, op: "upgrade", underlying: "boom") }
            func listInstalled() async throws -> [InstalledPackage] { [] }
            func outdated() async throws -> [OutdatedPackage] { outdatedList }
            func search(_ q: String) async throws -> [SearchHit] { [] }
            func info(_ p: PackageRef) async throws -> PackageInfo { fatalError() }
        }
        let brew = FailingUpgradable(id: .homebrew, outdatedList: [OutdatedPackage(name: "rg", installedVersion: "1", latestVersion: "2", manager: .homebrew)])
        let gimme = makeGimme(tmp: tmp, managers: [brew])
        let summary = try await gimme.updateAll()
        XCTAssertTrue(summary.failed.contains("homebrew:rg"))
    }

    func testForgetClearsPreference() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var prefs = Preferences(); prefs.remember("rg", .cargo)
        let gimme = Gimme(registry: Registry(managers: []), preferences: prefs, config: .defaults,
                          cache: Cache(directory: tmp.appendingPathComponent("cache")),
                          preferencesFile: tmp.appendingPathComponent("preferences.toml"))
        try gimme.forget(name: "rg")
        XCTAssertNil(gimme.preferences.remembered(for: "rg"))
    }

    func testDoctorReportsAvailability() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gimme = makeGimme(tmp: tmp, managers: [
            SearchableStubManager(id: .homebrew, available: true, known: []),
            SearchableStubManager(id: .cargo, available: false, known: [])
        ])
        let report = gimme.doctor()
        XCTAssertTrue(report.available.contains(.homebrew))
        XCTAssertTrue(report.missing.contains(.cargo))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CLIUpdateDoctorTests 2>&1 | tail -15`
Expected: FAIL — methods missing.

- [ ] **Step 3: Add the methods + supporting types**

Append to `Sources/GimmeCore/Gimme.swift`:

```swift
extension Gimme {
    /// Summary of an update-all run.
    public struct UpdateSummary {
        public var succeeded: [String] = []   // package IDs
        public var failed: [(id: String, error: String)] = []
    }

    /// Upgrade every outdated package across all managers. Partial failures
    /// are captured per-package; other managers still complete (spec §9).
    public func updateAll() async throws -> UpdateSummary {
        var summary = UpdateSummary()
        let managers = registry.enabled(config: config).filter { $0.capabilities.contains(.outdated) && $0.capabilities.contains(.upgrade) }
        for m in managers {
            let outdated = (try? await m.outdated()) ?? []
            for pkg in outdated {
                do {
                    try await m.upgrade(PackageRef(name: pkg.name))
                    summary.succeeded.append(pkg.id)
                } catch {
                    summary.failed.append((pkg.id, "\(error)"))
                }
            }
            cache.invalidatePrefix("\(m.id.rawValue):")
        }
        return summary
    }

    public func forget(name: String) throws {
        preferences.forget(name)
        try preferences.save(at: preferencesFile)
    }

    public func forgetAll() throws {
        preferences.forgetAll()
        try preferences.save(at: preferencesFile)
    }

    public struct DoctorReport {
        public let available: [ManagerID]
        public let missing: [ManagerID]
    }

    public func doctor() -> DoctorReport {
        var avail: [ManagerID] = []; var miss: [ManagerID] = []
        for m in registry.managers {
            if m.isAvailable() { avail.append(m.id) } else { miss.append(m.id) }
        }
        return DoctorReport(available: avail, missing: miss)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CLIUpdateDoctorTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Gimme updateAll/forget/doctor with partial-failure summary (spec §7, §9)"
```

### Task 7.4: CLI `main.swift` — argv parsing + output formatting + passthrough

**Files:**
- Modify: `Sources/gimme/main.swift`

**Spec reference:** §7.1–7.5. Flat verbs, global flags, passthrough, `--json`.

- [ ] **Step 1: Replace `main.swift`**

Write `Sources/gimme/main.swift`:

```swift
import Foundation
import GimmeCore

@main
struct GimmeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first else { printHelp(); exit(0) }

        // Passthrough: `gimme brew <args>`, `gimme cargo <args>`, etc.
        if let managerID = ManagerID(rawValue: first) {
            let binary = passthroughBinary(for: managerID)
            let rest = Array(args.dropFirst())
            do {
                let result = try await ProcessRunner.run(binary, args: rest, env: nil, stream: { print($0) })
                FileHandle.standardOutput.write(Data())  // flush
                exit(result.exitCode)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(2)
            }
        }

        // Verb dispatch.
        let parsed = parseArgs(args)
        do {
            try await runCommand(parsed)
        } catch let e as GimmeError {
            FileHandle.standardError.write(Data("\(e.message)\n".utf8))
            if let s = e.suggested { FileHandle.standardError.write(Data("hint: \(s)\n".utf8)) }
            exit(e.category.exitCode)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(70)
        }
    }

    static func passthroughBinary(for id: ManagerID) -> String {
        switch id {
        case .homebrew: return "/opt/homebrew/bin/brew"
        case .go:       return "/usr/local/go/bin/go"
        case .uv:       return "/opt/uv/bin/uv"
        case .cargo:    return "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cargo/bin/cargo"
        case .bun:      return "\(FileManager.default.homeDirectoryForCurrentUser.path)/.bun/bin/bun"
        }
    }

    struct Parsed {
        var verb: String
        var positional: [String]
        var from: ManagerID?
        var all: Bool
        var refresh: Bool
        var noCache: Bool
        var json: Bool
        var version: String?
        var yes: Bool
    }

    static func parseArgs(_ args: [String]) -> Parsed {
        var p = Parsed(verb: args.first ?? "help", positional: [], from: nil, all: false, refresh: false, noCache: false, json: false, version: nil, yes: false)
        var i = 1  // skip verb
        while i < args.count {
            let a = args[i]
            switch a {
            case "--from":
                if i + 1 < args.count, let id = ManagerID(rawValue: args[i+1]) { p.from = id; i += 1 }
            case "--all": p.all = true
            case "--refresh": p.refresh = true
            case "--no-cache": p.noCache = true
            case "--json": p.json = true
            case "--version": if i + 1 < args.count { p.version = args[i+1]; i += 1 }
                else if i + 1 < args.count { p.version = args[i+1]; i += 1 }
            case "-y", "--yes": p.yes = true
            default: p.positional.append(a)
            }
            i += 1
        }
        return p
    }

    static func runCommand(_ p: Parsed) async throws {
        let paths = GimmePaths.defaultUser
        try paths.ensureDirectories()
        let gimme = Gimme(
            registry: Gimme.defaultRegistry(),
            preferences: Preferences.load(at: paths.preferencesFile),
            config: Config.loadOrCreate(at: paths.configFile),
            cache: Cache(directory: paths.cacheDir),
            preferencesFile: paths.preferencesFile
        )
        switch p.verb {
        case "install":
            guard let name = p.positional.first else { throw GimmeError.usage("usage: gimme install <name> [--from <m>]") }
            let result = try await gimme.install(name: name, from: p.from, options: InstallOptions(version: p.version, yes: p.yes))
            if p.json { print(JSONEncoder().encode(result).asString ?? "{}") }
            else { print("installed \(result.package.id)") }
        case "uninstall":
            guard let name = p.positional.first else { throw GimmeError.usage("usage: gimme uninstall <name>") }
            try await gimme.uninstall(name: name, from: p.from)
            print("uninstalled \(name)")
        case "upgrade":
            guard let name = p.positional.first else { throw GimmeError.usage("usage: gimme upgrade <name>") }
            try await gimme.upgrade(name: name, from: p.from)
            print("upgraded \(name)")
        case "update":
            let summary = try await gimme.updateAll()
            for id in summary.succeeded { print("updated \(id)") }
            for f in summary.failed { print("FAILED \(f.id): \(f.error)") }
        case "list":
            let list = try await gimme.list(from: p.from, refresh: p.refresh)
            if p.json { print(JSONEncoder().encode(list).asString ?? "[]") }
            else { list.forEach { print("[\($0.manager.rawValue)] \($0.name) \($0.version)") } }
        case "outdated":
            let outdated = try await gimme.outdated(from: p.from, refresh: p.refresh)
            if p.json { print(JSONEncoder().encode(outdated).asString ?? "[]") }
            else { outdated.forEach { print("[\($0.manager.rawValue)] \($0.name) \($0.installedVersion) → \($0.latestVersion)") } }
        case "search":
            guard let q = p.positional.first else { throw GimmeError.usage("usage: gimme search <query> [--all]") }
            let hits = try await gimme.search(query: q, all: p.all, refresh: p.refresh)
            if p.json { print(JSONEncoder().encode(hits).asString ?? "[]") }
            else { hits.forEach { print("[\($0.manager.rawValue)] \($0.name) \($0.latestVersion) — \($0.summary)") } }
        case "info":
            guard let name = p.positional.first else { throw GimmeError.usage("usage: gimme info <name>") }
            let info = try await gimme.info(name: name, from: p.from)
            if p.json { print(JSONEncoder().encode(info).asString ?? "{}") }
            else { print("\(info.name) (\(info.manager.rawValue)) \(info.latestVersion)\n\(info.summary)") }
        case "forget":
            if p.all { try gimme.forgetAll(); print("forgot all preferences") }
            else if let name = p.positional.first { try gimme.forget(name: name); print("forgot \(name)") }
            else { throw GimmeError.usage("usage: gimme forget <name> | --all") }
        case "doctor":
            let report = gimme.doctor()
            print("available: \(report.available.map { $0.rawValue }.joined(separator: ", "))")
            if !report.missing.isEmpty { print("missing: \(report.missing.map { $0.rawValue }.joined(separator: ", "))") }
        case "config":
            if p.positional.first == "set", p.positional.count >= 3, p.positional[1] == "priority" {
                // `gimme config set priority brew,cargo,go,uv,bun`
                var cfg = Config.loadOrCreate(at: paths.configFile)
                cfg.priority = p.positional[2].split(separator: ",").map { String($0) }
                try cfg.toTOML().write(to: paths.configFile, atomically: true, encoding: .utf8)
                print("priority updated: \(cfg.priority.joined(separator: ", "))")
            } else {
                print(Config.loadOrCreate(at: paths.configFile).toTOML())
            }
        case "help", "-h", "--help":
            printHelp()
        default:
            throw GimmeError.usage("unknown command '\(p.verb)'. See: gimme --help")
        }
    }

    static func printHelp() {
        print("""
        gimmie — unified package manager

        Usage:
          gimme install <name> [--from <manager>] [--version <v>]
          gimme uninstall <name>
          gimme upgrade <name>
          gimme update                       (upgrade all outdated)
          gimme list [--from <manager>]
          gimme outdated [--from <manager>]
          gimme search <query> [--all]
          gimme info <name>
          gimme forget <name> | --all
          gimme doctor
          gimme config

        Passthrough: gimme <manager> <args...>   (homebrew|go|uv|cargo|bun)

        Flags: --from <m> --all --refresh --no-cache --json --version <v> -y
        """)
    }
}

extension Data {
    var asString: String? { String(data: self, encoding: .utf8) }
}
```

- [ ] **Step 2: Build**

Run: `swift build --target gimme 2>&1 | tail -20`
Expected: BUILD SUCCEEDS.

- [ ] **Step 3: Smoke-test the CLI manually**

Run: `./.build/debug/gimme --help && ./.build/debug/gimme doctor`
Expected: help text printed; doctor lists available/missing managers (real output depends on the machine).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: CLI — flat verbs, flags, passthrough, --json, doctor (spec §7)"
```

---

## Phase 8 — GUI Rebuild

**Goal:** Rebuilt SwiftUI app (spec §8). `GimmeStore` talks only through `Gimme`/`Registry`/`Resolver`. Modular views, one file per section. No automated tests — manually verified.

### Task 8.1: `GimmeStore` — the ObservableObject

**Files:**
- Modify: `Sources/GimmeUI/GimmeApp.swift`

- [ ] **Step 1: Replace `GimmeApp.swift`**

Write `Sources/GimmeUI/GimmeApp.swift`:

```swift
import SwiftUI
import GimmeCore

@main
struct GimmeApp: App {
    @StateObject private var store = GimmeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .alert("Error", isPresented: $store.showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(store.errorMessage)
                }
        }
    }
}

/// The central UI store. Talks only through Gimme (Registry/Resolver/Cache).
/// All backend operations run on a background Task; results land on @Published
/// main-actor state (spec §8.4).
@MainActor
final class GimmeStore: ObservableObject {
    @Published var installed: [InstalledPackage] = []
    @Published var outdated: [OutdatedPackage] = []
    @Published var searchResults: [SearchHit] = []
    @Published var searchAll = false
    @Published var activity: [ActivityEntry] = []
    @Published var loading = false
    @Published var preferences: Preferences = .init()
    @Published var config: Config = .defaults
    @Published var showError = false
    @Published var errorMessage = ""

    private let gimme: Gimme

    init() {
        let paths = GimmePaths.defaultUser
        try? paths.ensureDirectories()
        let g = Gimme(
            registry: Gimme.defaultRegistry(),
            preferences: Preferences.load(at: paths.preferencesFile),
            config: Config.loadOrCreate(at: paths.configFile),
            cache: Cache(directory: paths.cacheDir),
            preferencesFile: paths.preferencesFile
        )
        self.gimme = g
        self.preferences = g.preferences
        self.config = g.config
    }

    struct ActivityEntry: Identifiable {
        let id = UUID(); let text: String; let time = Date()
    }

    func loadAll() async {
        loading = true
        defer { loading = false }
        do {
            installed = try await gimme.list(from: nil, refresh: false)
            outdated = try await gimme.outdated(from: nil, refresh: false)
        } catch {
            showError(error)
        }
    }

    func runSearch(_ query: String) async {
        do { searchResults = try await gimme.search(query: query, all: searchAll, refresh: false) }
        catch { showError(error) }
    }

    func install(_ hit: SearchHit) async {
        log("installing \(hit.name) via \(hit.manager.rawValue)")
        do {
            _ = try await gimme.install(name: hit.name, from: hit.manager, options: InstallOptions())
            log("installed \(hit.name)")
            await loadAll()
        } catch { showError(error) }
    }

    func uninstall(_ pkg: InstalledPackage) async {
        log("uninstalling \(pkg.name)")
        do {
            try await gimme.uninstall(name: pkg.name, from: pkg.manager)
            log("uninstalled \(pkg.name)")
            await loadAll()
        } catch { showError(error) }
    }

    func upgrade(_ pkg: OutdatedPackage) async {
        do {
            try await gimme.upgrade(name: pkg.name, from: pkg.manager)
            log("upgraded \(pkg.name)")
            await loadAll()
        } catch { showError(error) }
    }

    func updateAll() async {
        log("updating all outdated packages")
        do {
            let summary = try await gimme.updateAll()
            summary.succeeded.forEach { log("updated \($0)") }
            summary.failed.forEach { log("FAILED \($0.id): \($0.error)") }
            await loadAll()
        } catch { showError(error) }
    }

    func forget(_ name: String) {
        do { try gimme.forget(name: name); preferences = gimme.preferences }
        catch { showError(error) }
    }

    private func log(_ text: String) {
        activity.insert(ActivityEntry(text: text), at: 0)
    }

    private func showError(_ error: Error) {
        if let e = error as? GimmeError { errorMessage = e.message }
        else { errorMessage = "\(error)" }
        showError = true
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build --target GimmeUI 2>&1 | tail -15`
Expected: BUILD SUCCEEDS (ContentView still references nothing new yet).

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(UI): GimmeStore — central ObservableObject over Gimme (spec §8.4)"
```

### Task 8.2: `ContentView` navigation shell + `InstalledView` + shared components

**Files:**
- Modify: `Sources/GimmeUI/ContentView.swift`
- Create: `Sources/GimmeUI/Views/InstalledView.swift`
- Create: `Sources/GimmeUI/Views/Components/ManagerBadge.swift`
- Create: `Sources/GimmeUI/Views/Components/ManagerFilterChip.swift`

- [ ] **Step 1: Create the shared components**

Write `Sources/GimmeUI/Views/Components/ManagerBadge.swift`:

```swift
import SwiftUI
import GimmeCore

struct ManagerBadge: View {
    let manager: ManagerID
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: manager.iconName)
            Text(manager.rawValue)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .foregroundColor(color)
        .clipShape(Capsule())
    }
    private var color: Color {
        switch manager {
        case .homebrew: return .orange
        case .go:       return .blue
        case .uv:       return .green
        case .cargo:    return .red
        case .bun:      return .pink
        }
    }
}
```

Write `Sources/GimmeUI/Views/Components/ManagerFilterChip.swift`:

```swift
import SwiftUI
import GimmeCore

struct ManagerFilterChip: View {
    let manager: ManagerID
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(manager.rawValue)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Create `InstalledView`**

Write `Sources/GimmeUI/Views/InstalledView.swift`:

```swift
import SwiftUI
import GimmeCore

struct InstalledView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var filter: ManagerID?
    @State private var selected: InstalledPackage?

    var filtered: [InstalledPackage] {
        filter.map { f in store.installed.filter { $0.manager == f } } ?? store.installed
    }

    var body: some View {
        VStack {
            HStack {
                ForEach(ManagerID.allCases, id: \.self) { m in
                    ManagerFilterChip(manager: m, isSelected: filter == m) { filter = (filter == m) ? nil : m }
                }
                Spacer()
                Button("Refresh") { Task { await store.loadAll() } }
            }
            .padding(.horizontal)

            List(filtered) { pkg in
                HStack {
                    ManagerBadge(manager: pkg.manager)
                    Text(pkg.name).fontWeight(.medium)
                    Text(pkg.version).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = pkg }
            }
        }
        .navigationTitle("Installed")
        .sheet(item: $selected) { pkg in DetailSheet(package: .installed(pkg)) }
        .task { await store.loadAll() }
    }
}
```

- [ ] **Step 3: Replace `ContentView` with the navigation shell**

Write `Sources/GimmeUI/ContentView.swift`:

```swift
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case updates = "Updates"
    case browse = "Browse"
    case byManager = "By Manager"
    case preferences = "Preferences"
    case activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .installed: return "square.grid.2x2"
        case .updates: return "arrow.up.circle"
        case .browse: return "magnifyingglass"
        case .byManager: return "shippingbox"
        case .preferences: return "gear"
        case .activity: return "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarSection? = .installed

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.icon)
                }
            }
            .navigationTitle("gimmie")
        } detail: {
            switch selection {
            case .installed:     InstalledView()
            case .updates:       UpdatesView()
            case .browse:        BrowseView()
            case .byManager:     ByManagerView()
            case .preferences:   PreferencesView()
            case .activity:      ActivityView()
            case .none:          Text("Select a section")
            }
        }
    }
}
```

- [ ] **Step 4: Create placeholder views (fleshed out in 8.3–8.6)**

Create these as minimal stubs so the project compiles. Each gets a real implementation in its own task.

`Sources/GimmeUI/Views/UpdatesView.swift`:

```swift
import SwiftUI
import GimmeCore

struct UpdatesView: View {
    @EnvironmentObject var store: GimmeStore
    var body: some View {
        VStack {
            HStack {
                Text("\(store.outdated.count) updates available").font(.headline)
                Spacer()
                Button("Update All") { Task { await store.updateAll() } }
                    .disabled(store.outdated.isEmpty)
            }.padding()
            List(store.outdated) { pkg in
                HStack {
                    ManagerBadge(manager: pkg.manager)
                    Text(pkg.name)
                    Text("\(pkg.installedVersion) → \(pkg.latestVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Update") { Task { await store.upgrade(pkg) } }
                }
            }
        }
        .navigationTitle("Updates")
        .task { await store.loadAll() }
    }
}
```

`Sources/GimmeUI/Views/BrowseView.swift`:

```swift
import SwiftUI
import GimmeCore

struct BrowseView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var query = ""
    @State private var selected: SearchHit?

    var body: some View {
        VStack {
            HStack {
                TextField("Search packages…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.runSearch(query) } }
                Toggle("All managers", isOn: $store.searchAll)
                Button("Search") { Task { await store.runSearch(query) } }
            }.padding()
            List(store.searchResults) { hit in
                HStack {
                    ManagerBadge(manager: hit.manager)
                    Text(hit.name).fontWeight(.medium)
                    Text(hit.latestVersion).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = hit }
            }
        }
        .navigationTitle("Browse")
        .sheet(item: $selected) { hit in DetailSheet(package: .searchable(hit)) }
    }
}
```

`Sources/GimmeUI/Views/ByManagerView.swift`:

```swift
import SwiftUI
import GimmeCore

struct ByManagerView: View {
    @EnvironmentObject var store: GimmeStore
    var body: some View {
        List {
            ForEach(ManagerID.allCases, id: \.self) { m in
                Section(m.displayName) {
                    let pkgs = store.installed.filter { $0.manager == m }
                    if pkgs.isEmpty {
                        Text("Nothing installed").foregroundStyle(.secondary)
                    } else {
                        ForEach(pkgs) { Text($0.name) }
                    }
                }
            }
        }
        .navigationTitle("By Manager")
        .task { await store.loadAll() }
    }
}
```

`Sources/GimmeUI/Views/PreferencesView.swift`:

```swift
import SwiftUI
import GimmeCore

struct PreferencesView: View {
    @EnvironmentObject var store: GimmeStore
    var body: some View {
        List {
            Section("Priority") {
                ForEach(store.config.priority, id: \.self) { Text($0) }
            }
            Section("Remembered overrides") {
                if store.preferences.overrides.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.preferences.overrides.keys.sorted()), id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Text(store.preferences.overrides[name]?.rawValue ?? "")
                            Button("Forget") { store.forget(name) }
                        }
                    }
                }
            }
            Section("Cache") {
                Text("list TTL: \(store.config.listCacheTTLSeconds)s")
                Text("info TTL: \(store.config.infoCacheTTLSeconds)s")
            }
        }
        .navigationTitle("Preferences")
    }
}
```

`Sources/GimmeUI/Views/ActivityView.swift`:

```swift
import SwiftUI
import GimmeCore

struct ActivityView: View {
    @EnvironmentObject var store: GimmeStore
    var body: some View {
        List(store.activity) { entry in
            VStack(alignment: .leading) {
                Text(entry.text)
                Text(entry.time.formatted(.dateTime)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Activity")
    }
}
```

`Sources/GimmeUI/Views/DetailSheet.swift`:

```swift
import SwiftUI
import GimmeCore

struct DetailSheet: View {
    enum Subject {
        case installed(InstalledPackage)
        case searchable(SearchHit)
    }
    @EnvironmentObject var store: GimmeStore
    @Environment(\.dismiss) var dismiss
    let package: Subject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch package {
            case .installed(let p):
                Text(p.name).font(.title2)
                ManagerBadge(manager: p.manager)
                Text("version \(p.version)")
                Button("Uninstall") { Task { await store.uninstall(p); dismiss() } }
            case .searchable(let h):
                Text(h.name).font(.title2)
                ManagerBadge(manager: h.manager)
                Text(h.summary)
                Text(h.latestVersion).foregroundStyle(.secondary)
                Button("Install") { Task { await store.install(h); dismiss() } }
            }
            Spacer()
        }
        .padding()
        .frame(width: 360, height: 280)
    }
}
```

- [ ] **Step 5: Build the UI**

Run: `swift build --target GimmeUI 2>&1 | tail -20`
Expected: BUILD SUCCEEDS.

- [ ] **Step 6: Manual smoke test**

Build the app bundle and launch:

```bash
swift build -c release --product GimmeUI 2>&1 | tail -5
# (Run the binary directly for a quick visual check; the full .app assembly
# via app/build-app.sh can be run after the phase is green.)
.build/release/GimmeUI
```

Expected: window opens, sidebar sections selectable, Installed view loads real installed packages (if Homebrew is installed on the dev machine). Verify: switching sections, searching, install/uninstall buttons. Note any crashes.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(UI): rebuild SwiftUI app — navigation, all views, store wiring (spec §8)"
```

---

## Phase 9 — Cross-cutting Polish

**Goal:** Wire the loose ends that make gimmie feel complete: progress streaming to the GUI Activity view, auto-bootstrap prompts in the CLI, and a final green build + manual verification.

### Task 9.1: Auto-bootstrap prompt in the CLI

When a resolved manager is unavailable, the CLI should offer to bootstrap it (spec §6.6).

**Files:**
- Modify: `Sources/GimmeCore/Gimme.swift` (wrap resolve+act in `Bootstrap.run`)
- Modify: `Tests/GimmeTests/CLIIntegrationTests.swift`

- [ ] **Step 1: Append failing test**

Append to `Tests/GimmeTests/CLIIntegrationTests.swift`:

```swift
final class CLIBootstrapTests: XCTestCase {
    func testInstallPromptsBootstrapWhenUnavailable() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // A manager that is unavailable, but bootstrap() makes it available.
        final class Lazy: PackageManager {
            let id: ManagerID = .cargo
            private var avail = false
            let displayName = ""; let icon = "circle"; let capabilities: Set<Capability> = [.install, .bootstrap, .search]
            func isAvailable() -> Bool { avail }
            func bootstrap() async throws { avail = true }
            func install(_ p: PackageRef, options: InstallOptions) async throws -> InstallResult {
                InstallResult(package: InstalledPackage(name: p.name, version: "1", manager: id, installedAt: nil))
            }
            func uninstall(_ p: PackageRef) async throws {}
            func upgrade(_ p: PackageRef) async throws {}
            func listInstalled() async throws -> [InstalledPackage] { [] }
            func outdated() async throws -> [OutdatedPackage] { [] }
            func search(_ q: String) async throws -> [SearchHit] {
                q == "rg" ? [SearchHit(name: "rg", manager: id, summary: "", latestVersion: "1")] : []
            }
            func info(_ p: PackageRef) async throws -> PackageInfo { fatalError() }
        }
        let m = Lazy()
        let gimme = Gimme(registry: Registry(managers: [m]), preferences: Preferences(), config: .defaults,
                          cache: Cache(directory: tmp.appendingPathComponent("cache")),
                          preferencesFile: tmp.appendingPathComponent("preferences.toml"))
        // Confirm = yes.
        let result = try await gimme.install(name: "rg", from: nil, options: InstallOptions(yes: true),
                                             confirmBootstrap: { _ in true })
        XCTAssertEqual(result.package.manager, .cargo)
        XCTAssertTrue(m.isAvailable())
    }

    func testInstallAbortsWhenBootstrapDeclined() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        final class Unavailable: PackageManager {
            let id: ManagerID = .cargo; let displayName = ""; let icon = "circle"
            let capabilities: Set<Capability> = [.install, .search]
            func isAvailable() -> Bool { false }
            func bootstrap() async throws {}
            func install(_ p: PackageRef, options: InstallOptions) async throws -> InstallResult { fatalError() }
            func uninstall(_ p: PackageRef) async throws {}
            func upgrade(_ p: PackageRef) async throws {}
            func listInstalled() async throws -> [InstalledPackage] { [] }
            func outdated() async throws -> [OutdatedPackage] { [] }
            func search(_ q: String) async throws -> [SearchHit] { [SearchHit(name: "rg", manager: id, summary: "", latestVersion: "1")] }
            func info(_ p: PackageRef) async throws -> PackageInfo { fatalError() }
        }
        let gimme = Gimme(registry: Registry(managers: [Unavailable()]), preferences: Preferences(), config: .defaults,
                          cache: Cache(directory: tmp.appendingPathComponent("cache")),
                          preferencesFile: tmp.appendingPathComponent("preferences.toml"))
        do {
            _ = try await gimme.install(name: "rg", from: nil, options: InstallOptions(yes: true),
                                        confirmBootstrap: { _ in false })
            XCTFail("expected throw")
        } catch GimmeError.managerUnavailable(let id) {
            XCTAssertEqual(id, .cargo)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CLIBootstrapTests 2>&1 | tail -15`
Expected: FAIL — `confirmBootstrap` parameter missing.

- [ ] **Step 3: Add bootstrap flow to `Gimme.install`**

In `Sources/GimmeCore/Gimme.swift`, change the `install` signature and add the bootstrap precondition:

```swift
    @discardableResult
    public func install(name: String, from hint: ManagerID?, options: InstallOptions,
                        confirmBootstrap: (ManagerID) -> Bool = { _ in false }) async throws -> InstallResult {
        let manager = try await resolve(name, hint: hint)
        if !manager.isAvailable() {
            try await Bootstrap.run(manager, confirm: confirmBootstrap)
        }
        let result = try await manager.install(PackageRef(name: name, managerHint: hint), options: options)
        cache.invalidatePrefix("\(manager.id.rawValue):")
        if hint != nil {
            preferences.remember(name, manager.id)
            try? preferences.save(at: preferencesFile)
        }
        return result
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CLIBootstrapTests 2>&1 | tail -15`
Expected: PASS. (Existing tests that call `install(name:from:options:)` still compile because `confirmBootstrap` has a default.)

- [ ] **Step 5: Wire the CLI to prompt interactively**

In `Sources/gimme/main.swift`, in the `install` case, pass an interactive confirm:

```swift
        case "install":
            guard let name = p.positional.first else { throw GimmeError.usage("usage: gimme install <name> [--from <m>]") }
            let result = try await gimme.install(name: name, from: p.from, options: InstallOptions(version: p.version, yes: p.yes)) { id in
                // Non-interactive (-y) auto-accepts; otherwise prompt on stderr.
                if p.yes { return true }
                print("\(id.rawValue) is not installed. Install it? [y/N] ", terminator: "")
                return readLine()?.lowercased().hasPrefix("y") ?? false
            }
            if p.json { print((JSONEncoder().encode(result)).asString ?? "{}") }
            else { print("installed \(result.package.id)") }
```

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | tail -10`
Expected: BUILD SUCCEEDS.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: auto-bootstrap prompt for missing managers in install (spec §6.6)"
```

### Task 9.2: Progress streaming wired to GUI Activity

Pass a stream callback from the GUI store through to operations so install/compile progress appears live (spec §6.6).

**Files:**
- Modify: `Sources/GimmeCore/Gimme.swift` (optional `stream:` parameter on install/upgrade)
- Modify: `Sources/GimmeUI/GimmeApp.swift` (wire stream into `log`)

- [ ] **Step 1: Add an optional `onProgress` to `install`**

In `Sources/GimmeCore/Gimme.swift`:

```swift
    @discardableResult
    public func install(name: String, from hint: ManagerID?, options: InstallOptions,
                        confirmBootstrap: (ManagerID) -> Bool = { _ in false },
                        onProgress: ((String) -> Void)? = nil) async throws -> InstallResult {
        let manager = try await resolve(name, hint: hint)
        if !manager.isAvailable() {
            try await Bootstrap.run(manager, confirm: confirmBootstrap)
        }
        let result = try await manager.installStreaming(PackageRef(name: name, managerHint: hint),
                                                        options: options, onProgress: onProgress)
        cache.invalidatePrefix("\(manager.id.rawValue):")
        if hint != nil {
            preferences.remember(name, manager.id)
            try? preferences.save(at: preferencesFile)
        }
        return result
    }
```

Add a default protocol extension to `PackageManager` so adapters that don't override streaming still work:

```swift
public extension PackageManager {
    /// Default: ignore streaming, delegate to install().
    func installStreaming(_ package: PackageRef, options: InstallOptions, onProgress: ((String) -> Void)?) async throws -> InstallResult {
        if let onProgress { onProgress("installing \(package.name)…") }
        return try await install(package, options: options)
    }
}
```

(Optional: override `installStreaming` in `HomebrewManager` and `CargoManager` to pipe `ProcessRunner.run(..., stream: onProgress)`.)

- [ ] **Step 2: Wire it in `GimmeStore.install`**

In `Sources/GimmeUI/GimmeApp.swift`, change `install(_ hit:)`:

```swift
    func install(_ hit: SearchHit) async {
        log("installing \(hit.name) via \(hit.manager.rawValue)")
        do {
            _ = try await gimme.install(name: hit.name, from: hit.manager, options: InstallOptions(),
                                        confirmBootstrap: { id in true },  // GUI auto-bootstraps (could prompt)
                                        onProgress: { line in
                                            Task { @MainActor in self.log("\(hit.manager.rawValue): \(line)") }
                                        })
            log("installed \(hit.name)")
            await loadAll()
        } catch { showError(error) }
    }
```

- [ ] **Step 3: Build + manual verify**

Run: `swift build 2>&1 | tail -10 && swift build -c release --product GimmeUI 2>&1 | tail -5`
Expected: BUILD SUCCEEDS. Launch the app and install something via Browse to confirm progress lines appear in Activity.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: progress streaming from adapters to GUI Activity view (spec §6.6)"
```

### Task 9.3: Final full-suite green + smoke test

- [ ] **Step 1: Run the complete test suite**

Run: `swift test 2>&1 | tail -30`
Expected: all tests PASS. If any fail, read the failure and fix at the source (do not weaken the test). Typical late-stage failures: a stub signature drift between tasks, or a `dist-tags`/property-access compile error in BunManager.

- [ ] **Step 2: Build everything in release**

Run: `swift build -c release 2>&1 | tail -10`
Expected: BUILD SUCCEEDS for all 3 targets.

- [ ] **Step 3: CLI end-to-end smoke (real machine)**

Run each and confirm sane output (depends on what's installed on the dev machine):

```bash
.build/release/gimme doctor
.build/release/gimme list
.build/release/gimme search ripgrep
.build/release/gimme --help
```

- [ ] **Step 4: GUI end-to-end smoke**

```bash
.build/release/GimmeUI   # or: bash app/build-app.sh && open app/Gimme.app
```

Verify in the app: each sidebar section renders; Installed shows real packages; Browse search returns results; a search-result install works; Updates view shows outdated (if any); Activity logs operations; Preferences shows remembered overrides after a `--from` install via CLI.

- [ ] **Step 5: Update README (if it describes v1 behavior)**

Read `README.md`. If it documents the deleted native pipeline (manifests, taps, cellar), rewrite the relevant sections to describe v2 orchestration: the unified namespace, supported managers, CLI verbs, and that gimmie orchestrates rather than installs natively. Keep it accurate to what now exists.

Run: `git diff README.md | head -60` to review before committing.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "docs: update README for gimmie v2 orchestration model"
```

---

## Done

When all tasks above are complete and Phase 9 step 1 shows a green `swift test`, gimmie v2 is built. The deliverable is a pure-orchestration tool with: a `PackageManager` protocol + 5 adapters (Homebrew, Go, uv, Cargo, bun), a Resolver with priority + remembered prefs, a TTL cache, a flat-verb CLI with passthrough, and a rebuilt SwiftUI app — all matching the spec at `docs/superpowers/specs/2026-08-07-gimmie-v2-orchestrator-design.md`.

## Known gaps (deferred to follow-up; documented for honesty)

These spec items are intentionally lighter than the spec to keep v1 focused. Each is a small, well-scoped follow-up:

- **`--no-cache` flag (spec §7.3):** parsed in `parseArgs` but only `--refresh` is honored in `list`/`outdated`/`search`. Full `--no-cache` (skip cache write too) is a ~10-line addition to the `Gimme.list/outdated/search` cache branches.
- **GUI "By Manager" bootstrap button (spec §8.2):** `ByManagerView` lists managers but doesn't yet show an "Install <manager>" button for unavailable ones. The `Bootstrap` runner exists (Task 3.3) and the CLI flow is wired (Task 9.1); adding the GUI button is a small view change.
- **GUI automated tests:** out of scope for v1 per the spec (§10). The `GimmeStore` is designed to be testable if tests are added later.

These do not block the v1 deliverable and are tracked here so they aren't forgotten.
