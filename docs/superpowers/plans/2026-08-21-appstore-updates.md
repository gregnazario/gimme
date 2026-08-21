# App Store Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fifteenth adapter, `AppStoreManager`, that lists Mac App Store apps, flags outdated ones against the iTunes Lookup API, and upgrades them via `mas` (or the App Store page when `mas` is absent).

**Architecture:** Updates-only adapter behind the existing `PackageManager` seam. Read path is dependency-free: scan `.app` bundles for `_MASReceipt` markers, compare versions against `https://itunes.apple.com/lookup?bundleId=<id>` with a 6 h disk cache. Write path is hybrid: `mas upgrade <trackId>` when the `mas` binary resolves, else `open macappstore://apps.apple.com/app/id<trackId>` with a 10 s coalescing guard.

**Tech Stack:** Swift 5.9 (SwiftPM, no external deps), XCTest, existing `HTTPClient` / `ProcessRunning` / `Cache` seams.

**Spec:** `docs/superpowers/specs/2026-08-21-appstore-updates-design.md`

## Global Constraints

- English only everywhere; Conventional Commits; **never attribute commits to an AI** (no trailers, no banners).
- macOS 13 floor; no new package dependencies.
- Tests are in-process: no real network, no real installs, no reliance on the host's `/Applications`.
- Never false-flag: an app that can't be resolved or compared is skipped, not marked outdated.
- `swift test` green before every commit. Run `swift build` too — GimmeUI is a target and exhaustive `ManagerID` switches there are compile-checked.
- Commit only (never push) unless the user asks.

---

### Task 1: Manager identity — `ManagerID.appstore`, ecosystem bucket, palette color

**Files:**
- Modify: `Sources/GimmeCore/PackageManager.swift:5-45` (enum `ManagerID`)
- Modify: `Sources/GimmeCore/Ecosystem.swift:30-40` (`ManagerID.ecosystem`)
- Modify: `Sources/GimmeUI/Views/Components/ManagerPalette.swift:15-32` (`nsHex`)
- Test: `Tests/GimmeTests/EcosystemTests.swift:27-31` (`testSystemEcosystem`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `ManagerID.appstore` (rawValue `"appstore"`, displayName `"App Store"`, iconName `"app.badge.fill"`), `.appstore.ecosystem == .system`, palette hex `"#007AFF"`. Later tasks switch on this case; the compiler enforces exhaustiveness everywhere.

- [ ] **Step 1: Commit the design spec (left uncommitted during review)**

```bash
git add docs/superpowers/specs/2026-08-21-appstore-updates-design.md
git commit -m "docs: add App Store updates design spec"
```

- [ ] **Step 2: Write the failing test** — in `Tests/GimmeTests/EcosystemTests.swift`, extend `testSystemEcosystem`:

```swift
    func testSystemEcosystem() {
        XCTAssertEqual(ManagerID.homebrew.ecosystem, .system)
        XCTAssertEqual(ManagerID.aqua.ecosystem, .system)
        XCTAssertEqual(ManagerID.ubi.ecosystem, .system)
        XCTAssertEqual(ManagerID.appstore.ecosystem, .system)
    }
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter EcosystemTests`
Expected: FAIL — compile error, `type 'ManagerID' has no member 'appstore'`

- [ ] **Step 4: Implement** — three small edits.

In `Sources/GimmeCore/PackageManager.swift`, add the case to the enum declaration line:

```swift
public enum ManagerID: String, Hashable, Codable, CaseIterable {
    case homebrew, go, uv, cargo, bun, npm, pnpm, yarn, gem, composer, deno, pipx, aqua, ubi, appstore
```

and add both switch rows:

```swift
        case .ubi:      return "ubi"
        case .appstore: return "App Store"
```

```swift
        case .ubi:      return "wrench.and.screwdriver"
        case .appstore: return "app.badge.fill"
```

In `Sources/GimmeCore/Ecosystem.swift`, add to the `system` row of `ManagerID.ecosystem`:

```swift
        case .homebrew, .aqua, .ubi, .appstore: return .system
```

In `Sources/GimmeUI/Views/Components/ManagerPalette.swift`, add (keeps hue spacing — bright system blue, distinct from go's deep `#0369A1` and deno's `#2563EB`):

```swift
        case .appstore: return "#007AFF"  // App Store blue
```

- [ ] **Step 5: Run build + tests to verify green**

Run: `swift build && swift test --filter EcosystemTests`
Expected: BUILD SUCCEEDED (any other exhaustive switch the compiler flags gets the same one-line treatment), tests PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/GimmeCore/PackageManager.swift Sources/GimmeCore/Ecosystem.swift Sources/GimmeUI/Views/Components/ManagerPalette.swift Tests/GimmeTests/EcosystemTests.swift
git commit -m "feat: add appstore ManagerID, ecosystem bucket, and palette color"
```

---

### Task 2: `AppStoreManager` skeleton + receipt scan (`listInstalled`)

**Files:**
- Create: `Sources/GimmeCore/managers/AppStoreManager.swift`
- Create: `Tests/GimmeTests/managers/AppStoreManagerTests.swift`
- Modify: `Sources/GimmeCore/Gimme.swift:344-355` (`defaultRegistry`) — register at the end of the list

**Interfaces:**
- Consumes: `PackageManager`, `HTTPClient`, `ProcessRunning`, `BinaryResolver`, `GimmeError` (all existing).
- Produces: `public final class AppStoreManager: PackageManager` with
  `init(http:process:applicationDirs:indexCache:masBinary:)`, `capabilities == [.list, .outdated, .upgrade]`,
  `isAvailable() == true`, and `listInstalled()`. Internal `struct MASApp { name, bundleID, version }`
  and `func scanInstalledApps() -> [MASApp]` are used by Tasks 3–4. The initializer signature is final — later tasks only add methods.

- [ ] **Step 1: Write the failing tests** — create `Tests/GimmeTests/managers/AppStoreManagerTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class AppStoreManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        var requests: [String] = []
        func data(for url: URL) async throws -> Data {
            requests.append(url.absoluteString)
            return byURL[url.absoluteString] ?? Data()
        }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("appstore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Create a fake .app bundle in a temp "Applications" dir.
    @discardableResult
    func makeApp(_ dir: URL, _ bundleFile: String, bundleID: String, version: String,
                 name: String? = nil, mas: Bool = true) throws -> URL {
        let app = dir.appendingPathComponent(bundleFile)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if mas {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/_MASReceipt"),
                                                    withIntermediateDirectories: true)
            try Data([0x00]).write(to: app.appendingPathComponent("Contents/_MASReceipt/receipt"))
        }
        let info = contents.appendingPathComponent("Info.plist")
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundleDisplayName": name ?? bundleFile.replacingOccurrences(of: ".app", with: ""),
        ]
        try (plist as NSDictionary).write(to: info, atomically: true)
        return app
    }

    func manager(_ http: HTTPClient? = nil, _ p: StubProcess? = nil) -> AppStoreManager {
        AppStoreManager(http: http ?? StubHTTP(), process: p ?? StubProcess(),
                        applicationDirs: [tmp], masBinary: "")
    }

    func testIDAndCapabilities() {
        let m = manager()
        XCTAssertEqual(m.id, .appstore)
        XCTAssertEqual(m.displayName, "App Store")
        XCTAssertEqual(m.capabilities, [.list, .outdated, .upgrade])
        XCTAssertTrue(m.isAvailable())
    }

    func testListFindsOnlyMASReceiptApps() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        try makeApp(tmp, "Chrome.app", bundleID: "com.google.Chrome", version: "138.0.0", mas: false) // non-MAS neighbor
        let pkgs = try await manager().listInstalled()
        XCTAssertEqual(pkgs.count, 1)
        XCTAssertEqual(pkgs.first?.name, "Slack")
        XCTAssertEqual(pkgs.first?.version, "4.51.180")
        XCTAssertEqual(pkgs.first?.manager, .appstore)
        XCTAssertNil(pkgs.first?.installedAt)
    }

    func testListSkipsAppsMissingVersionOrBundleID() async throws {
        // Hand-write a receipt app whose plist lacks CFBundleIdentifier.
        let app = tmp.appendingPathComponent("Broken.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/_MASReceipt"),
                                                withIntermediateDirectories: true)
        try Data([0x00]).write(to: app.appendingPathComponent("Contents/_MASReceipt/receipt"))
        try ["CFBundleShortVersionString": "1.0"] as NSDictionary
            .write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try makeApp(tmp, "Good.app", bundleID: "com.good.app", version: "2.0")
        let pkgs = try await manager().listInstalled()
        XCTAssertEqual(pkgs.map(\.name), ["Good"])
    }

    func testListDedupesAcrossDirsFirstDirWins() async throws {
        let dir2 = tmp.appendingPathComponent("home-apps")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try makeApp(tmp, "One.app", bundleID: "com.one.app", version: "1.0")
        try makeApp(dir2, "One.app", bundleID: "com.one.app", version: "9.9")
        try makeApp(dir2, "Two.app", bundleID: "com.two.app", version: "2.0")
        let m = AppStoreManager(http: StubHTTP(), process: StubProcess(),
                                applicationDirs: [tmp, dir2], masBinary: "")
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertTrue(pkgs.contains { $0.name == "One" && $0.version == "1.0" })
    }

    func testListHandlesMissingDirectory() async throws {
        let m = AppStoreManager(http: StubHTTP(), process: StubProcess(),
                                applicationDirs: [tmp.appendingPathComponent("nope")], masBinary: "")
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs, [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppStoreManagerTests`
Expected: FAIL — compile error, `cannot find 'AppStoreManager' in scope`

- [ ] **Step 3: Implement** — create `Sources/GimmeCore/managers/AppStoreManager.swift`:

```swift
import Foundation

/// Mac App Store adapter (spec: docs/superpowers/specs/2026-08-21-appstore-updates-design.md).
/// Updates-only: list, outdated, upgrade. The read path never depends on the
/// `mas` CLI — installed apps are found by scanning .app bundles for an
/// _MASReceipt marker, and versions are compared against the public iTunes
/// Lookup API (no auth, `country=us`). `mas` is used opportunistically for the
/// write path; without it, upgrade opens the app's page in the App Store.
public final class AppStoreManager: PackageManager {
    public let id: ManagerID = .appstore
    public let displayName = "App Store"
    public let icon = "app.badge.fill"
    public let capabilities: Set<Capability> = [.list, .outdated, .upgrade]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let applicationDirs: [URL]
    private let indexCache: Cache?
    private let masBinaryOverride: String?

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                applicationDirs: [URL]? = nil,
                indexCache: Cache? = nil,
                masBinary: String? = nil) {
        self.http = http
        self.process = process
        self.applicationDirs = applicationDirs ?? [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        self.indexCache = indexCache
        self.masBinaryOverride = masBinary
    }

    /// Requires only /Applications, which exists on every Mac — the adapter is
    /// always available; there is nothing to bootstrap.
    public func isAvailable() -> Bool { true }
    public func bootstrap() async throws {}

    // MARK: - Not advertised in capabilities (updates-only adapter)

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        throw GimmeError.operationFailed(manager: .appstore, op: "install",
            underlying: "App Store installs are not supported — use the App Store app")
    }
    public func uninstall(_ package: PackageRef) async throws {
        throw GimmeError.operationFailed(manager: .appstore, op: "uninstall",
            underlying: "App Store uninstalls are not supported — drag the app to the Trash")
    }
    public func search(_ query: String) async throws -> [SearchHit] { [] }
    public func info(_ package: PackageRef) async throws -> PackageInfo {
        throw GimmeError.notFoundInManagers(name: package.name, searched: [.appstore])
    }

    // MARK: - Receipt scan

    /// An installed Mac App Store app found by receipt scan.
    struct MASApp {
        let name: String       // human-facing display name ("Slack")
        let bundleID: String   // "com.tinyspeck.slackmacgap"
        let version: String    // CFBundleShortVersionString
    }

    /// Shallow scan of the application directories. A .app bundle is an App
    /// Store install iff it contains Contents/_MASReceipt/receipt; apps with an
    /// unreadable plist, a missing bundle ID or a missing version are skipped
    /// (never-false-flag bias). Duplicates across dirs: the first dir wins.
    func scanInstalledApps() -> [MASApp] {
        var apps: [MASApp] = []
        var seen = Set<String>()
        for dir in applicationDirs {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                let bundle = dir.appendingPathComponent(entry, isDirectory: true)
                guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/_MASReceipt/receipt").path) else { continue }
                guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
                      let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      let bundleID = dict["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
                      let version = dict["CFBundleShortVersionString"] as? String, !version.isEmpty
                else { continue }
                guard seen.insert(bundleID).inserted else { continue }
                let name = (dict["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (dict["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? String(entry.dropLast(4))
                apps.append(MASApp(name: name, bundleID: bundleID, version: version))
            }
        }
        return apps
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        scanInstalledApps().map {
            InstalledPackage(name: $0.name, version: $0.version, manager: .appstore, installedAt: nil)
        }
    }

    // outdated() and upgrade() are implemented in later plan tasks.
    public func outdated() async throws -> [OutdatedPackage] { [] }
    public func upgrade(_ package: PackageRef) async throws {
        throw GimmeError.notFoundInManagers(name: package.name, searched: [.appstore])
    }
}
```

Then register it in `Sources/GimmeCore/Gimme.swift` `defaultRegistry()` (after `UbiManager()`; note the new index-cache wiring):

```swift
            DenoManager(), PipxManager(), AquaManager(), UbiManager(),
            AppStoreManager(indexCache: Cache(directory: GimmePaths.defaultUser.cacheDir))
```

- [ ] **Step 4: Run tests to verify green**

Run: `swift build && swift test --filter AppStoreManagerTests`
Expected: PASS (all 5 tests). Note: the in-process suite never touches the real `/Applications` — all tests inject `applicationDirs`.

- [ ] **Step 5: Commit**

```bash
git add Sources/GimmeCore/managers/AppStoreManager.swift Tests/GimmeTests/managers/AppStoreManagerTests.swift Sources/GimmeCore/Gimme.swift
git commit -m "feat: AppStoreManager receipt scan lists installed App Store apps"
```

---

### Task 3: `outdated()` — version comparison, iTunes Lookup, 6 h cache

**Files:**
- Modify: `Sources/GimmeCore/managers/AppStoreManager.swift`
- Test: `Tests/GimmeTests/managers/AppStoreManagerTests.swift`

**Interfaces:**
- Consumes: `scanInstalledApps()` / `MASApp` from Task 2; `HTTPClient.getJSON`; `Cache.get/set`.
- Produces: `static func isOlder(_ installed: String, than latest: String) -> Bool` and `func lookup(bundleID: String) async -> LookupResponse?` (internal, Codable `LookupResponse { resultCount, results: [{ trackId, trackName?, version? }] }`). Task 4 calls `lookup(bundleID:)` for the track ID.

- [ ] **Step 1: Write the failing tests** — append to `AppStoreManagerTests`:

```swift
    // MARK: - version comparison

    func testIsOlderNumericSegments() {
        XCTAssertTrue(AppStoreManager.isOlder("4.51.180", than: "4.51.191"))
        XCTAssertFalse(AppStoreManager.isOlder("4.51.191", than: "4.51.180"))
        XCTAssertTrue(AppStoreManager.isOlder("16.4", than: "16.10"))   // numeric, not lexical
        XCTAssertFalse(AppStoreManager.isOlder("1.0", than: "1.0.0"))   // padded equal
        XCTAssertFalse(AppStoreManager.isOlder("2.0", than: "2.0"))
        XCTAssertTrue(AppStoreManager.isOlder("1.2b3", than: "1.2b4"))  // non-numeric falls back to lexical
    }

    // MARK: - outdated

    private func stubLookup(_ http: StubHTTP, _ bundleID: String, version: String?, trackId: Int = 123) {
        let json: String
        if let version {
            json = #"{"resultCount":1,"results":[{"trackId":\#(trackId),"trackName":"T","version":"\#(version)"}]}"#
        } else {
            json = #"{"resultCount":0,"results":[]}"#
        }
        http.byURL["https://itunes.apple.com/lookup?bundleId=\(bundleID)&country=us"] = Data(json.utf8)
    }

    func testOutdatedFlagsOnlyOlderApps() async throws {
        try makeApp(tmp, "Old.app", bundleID: "com.old.app", version: "1.0.0")
        try makeApp(tmp, "New.app", bundleID: "com.new.app", version: "2.0.0")
        try makeApp(tmp, "Gone.app", bundleID: "com.gone.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.old.app", version: "1.5.0")
        stubLookup(http, "com.new.app", version: "2.0.0")
        stubLookup(http, "com.gone.app", version: nil)  // resultCount 0: pulled from store
        let out = try await manager(http).outdated()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "Old")
        XCTAssertEqual(out.first?.installedVersion, "1.0.0")
        XCTAssertEqual(out.first?.latestVersion, "1.5.0")
        XCTAssertEqual(out.first?.manager, .appstore)
    }

    func testOutdatedSkipsUnresolvableLookups() async throws {
        // Empty stub body → decode failure → skipped, never flagged.
        try makeApp(tmp, "Flaky.app", bundleID: "com.flaky.app", version: "1.0.0")
        let out = try await manager(StubHTTP()).outdated()
        XCTAssertEqual(out, [])
    }

    func testOutdatedServedFromCacheWithinTTL() async throws {
        try makeApp(tmp, "Cached.app", bundleID: "com.cached.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.cached.app", version: "2.0.0")
        let cache = Cache(directory: tmp.appendingPathComponent("cache"))
        let m = AppStoreManager(http: http, process: StubProcess(), applicationDirs: [tmp],
                                indexCache: cache, masBinary: "")
        _ = try await m.outdated()
        let http2 = StubHTTP()  // no stubs: a network read would decode Data() → skip → empty
        let m2 = AppStoreManager(http: http2, process: StubProcess(), applicationDirs: [tmp],
                                 indexCache: cache, masBinary: "")
        let out = try await m2.outdated()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(http2.requests, [])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppStoreManagerTests`
Expected: FAIL — `type 'AppStoreManager' has no member 'isOlder'`

- [ ] **Step 3: Implement** — replace the Task-2 placeholder `outdated()` in `AppStoreManager.swift` and add:

```swift
    // MARK: - Update detection (iTunes Lookup API)

    /// iTunes Lookup response. Codable so the decoded struct itself is what the
    /// disk cache stores (key `appstore:lookup:<bundleID>`).
    struct LookupResponse: Codable {
        let resultCount: Int
        let results: [Result]
        struct Result: Codable {
            let trackId: Int
            let trackName: String?
            let version: String?
        }
    }

    private static let lookupTTL = 6 * 3600

    /// True when `installed` is strictly older than `latest`: dot-segment
    /// numeric comparison with zero-padding ("1.0" == "1.0.0"); non-numeric
    /// segments fall back to lexical ordering. Never true for equal values.
    static func isOlder(_ installed: String, than latest: String) -> Bool {
        guard installed != latest else { return false }
        let a = installed.split(separator: ".").map(String.init)
        let b = latest.split(separator: ".").map(String.init)
        for i in 0..<max(a.count, b.count) {
            let sa = i < a.count ? a[i] : "0"
            let sb = i < b.count ? b[i] : "0"
            if let na = Int(sa), let nb = Int(sb) {
                if na != nb { return na < nb }
            } else if sa != sb {
                return sa < sb
            }
        }
        return false
    }

    /// Fetch (or serve from cache) the store record for a bundle ID. Returns
    /// nil on any failure — callers skip the app rather than flag it.
    func lookup(bundleID: String) async -> LookupResponse? {
        let key = "appstore:lookup:\(bundleID)"
        if let indexCache, let cached = indexCache.get(key, ttlSeconds: Self.lookupTTL, as: LookupResponse.self) {
            return cached
        }
        let url = "https://itunes.apple.com/lookup?bundleId=\(bundleID)&country=us"
        guard let resp: LookupResponse = try? await http.getJSON(url, as: LookupResponse.self) else { return nil }
        indexCache?.set(key, value: resp)
        return resp
    }

    public func outdated() async throws -> [OutdatedPackage] {
        await withTaskGroup(of: OutdatedPackage?.self) { group in
            for app in scanInstalledApps() {
                group.addTask {
                    guard let store = await self.lookup(bundleID: app.bundleID)?.results.first,
                          let latest = store.version, !latest.isEmpty,
                          Self.isOlder(app.version, than: latest) else { return nil }
                    return OutdatedPackage(name: app.name, installedVersion: app.version,
                                           latestVersion: latest, manager: .appstore)
                }
            }
            var out: [OutdatedPackage] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }
```

- [ ] **Step 4: Run tests to verify green**

Run: `swift test --filter AppStoreManagerTests`
Expected: PASS (9 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/GimmeCore/managers/AppStoreManager.swift Tests/GimmeTests/managers/AppStoreManagerTests.swift
git commit -m "feat: AppStoreManager outdated checks via iTunes Lookup API with 6h cache"
```

---

### Task 4: `upgrade()` — hybrid mas/App Store with open-coalescing

**Files:**
- Modify: `Sources/GimmeCore/managers/AppStoreManager.swift`
- Test: `Tests/GimmeTests/managers/AppStoreManagerTests.swift`

**Interfaces:**
- Consumes: `scanInstalledApps()`, `lookup(bundleID:)` (Task 3), `BinaryResolver.resolve("mas")`, `ProcessRunning`.
- Produces: working `upgrade(_ package: PackageRef)`. Accepts a display name ("Slack") or a bundle ID ("com.tinyspeck.slackmacgap").

- [ ] **Step 1: Write the failing tests** — append to `AppStoreManagerTests`:

```swift
    // MARK: - upgrade

    func testUpgradeRunsMasWhenPresent() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        let http = StubHTTP()
        stubLookup(http, "com.tinyspeck.slackmacgap", version: "4.51.191", trackId: 803453959)
        let p = StubProcess()
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp], masBinary: "/tmp/mas-stub")
        try await m.upgrade(PackageRef(name: "Slack"))
        XCTAssertTrue(p.calls.contains { $0.0 == "/tmp/mas-stub" && $0.1 == ["upgrade", "803453959"] })
    }

    func testUpgradeAcceptsBundleID() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        let http = StubHTTP()
        stubLookup(http, "com.tinyspeck.slackmacgap", version: "4.51.191", trackId: 803453959)
        let p = StubProcess()
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp], masBinary: "/tmp/mas-stub")
        try await m.upgrade(PackageRef(name: "com.tinyspeck.slackmacgap"))
        XCTAssertTrue(p.calls.contains { $0.0 == "/tmp/mas-stub" && $0.1 == ["upgrade", "803453959"] })
    }

    func testUpgradeOpensAppStorePageWhenMasAbsent() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        let http = StubHTTP()
        stubLookup(http, "com.tinyspeck.slackmacgap", version: "4.51.191", trackId: 803453959)
        let p = StubProcess()
        let m = manager(http, p)  // masBinary: "" forces the fallback path
        try await m.upgrade(PackageRef(name: "Slack"))
        XCTAssertTrue(p.calls.contains { $0.0 == "/usr/bin/open" && $0.1 == ["macappstore://apps.apple.com/app/id803453959"] })
    }

    func testUpgradeCoalescesRepeatedOpens() async throws {
        try makeApp(tmp, "One.app", bundleID: "com.one.app", version: "1.0.0")
        try makeApp(tmp, "Two.app", bundleID: "com.two.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.one.app", version: "2.0.0", trackId: 111)
        stubLookup(http, "com.two.app", version: "2.0.0", trackId: 222)
        let p = StubProcess()
        let m = manager(http, p)
        try await m.upgrade(PackageRef(name: "One"))
        try await m.upgrade(PackageRef(name: "Two"))  // within the 10 s window → skipped
        let opens = p.calls.filter { $0.0 == "/usr/bin/open" }
        XCTAssertEqual(opens.count, 1)
        XCTAssertEqual(opens.first?.1.first, "macappstore://apps.apple.com/app/id111")
    }

    func testUpgradeThrowsForUnknownApp() async {
        let m = manager()
        do { try await m.upgrade(PackageRef(name: "Nope")); XCTFail("expected throw") }
        catch { }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppStoreManagerTests`
Expected: FAIL on the mas/open tests — the placeholder `upgrade` throws for everything.

- [ ] **Step 3: Implement** — replace the placeholder `upgrade(_:)` in `AppStoreManager.swift`:

```swift
    // MARK: - Upgrade (hybrid mas / App Store page)

    /// updateAll calls upgrade() once per outdated app; without mas that would
    /// open the App Store N times. Skip further opens within this window —
    /// the store (or its updates pane) is already up.
    private static let openCoalesceInterval: TimeInterval = 10
    private let stateLock = NSLock()
    nonisolated(unsafe) private var lastOpenedAppStoreAt: Date?

    /// A bundle ID is dotted with no spaces ("com.tinyspeck.slackmacgap");
    /// display names never look like that ("Amazon Kindle").
    private func looksLikeBundleID(_ s: String) -> Bool {
        s.contains(".") && !s.contains(" ")
    }

    public func upgrade(_ package: PackageRef) async throws {
        let apps = scanInstalledApps()
        let app = looksLikeBundleID(package.name)
            ? apps.first { $0.bundleID == package.name }
            : apps.first { $0.name == package.name }
        guard let app else { throw GimmeError.notFoundInManagers(name: package.name, searched: [.appstore]) }
        guard let store = await lookup(bundleID: app.bundleID)?.results.first, store.trackId > 0 else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.appstore])
        }

        // Preferred path: mas drives the real upgrade. masBinaryOverride == ""
        // means "force absent" so tests are hermetic on machines that have mas.
        let masPath: String?
        if masBinaryOverride == "" { masPath = nil }
        else { masPath = masBinaryOverride ?? BinaryResolver.resolve("mas") }
        if let masPath {
            let res = try await process.run(masPath, args: ["upgrade", String(store.trackId)], env: nil, stream: nil)
            guard res.exitCode == 0 else {
                throw GimmeError.operationFailed(manager: .appstore, op: "upgrade", underlying: res.stderr)
            }
            return
        }

        // Fallback: land the App Store on the app's page; the user clicks
        // Update. Coalesced so Update-All opens the store at most once.
        let now = Date()
        stateLock.lock(); let last = lastOpenedAppStoreAt; stateLock.unlock()
        if let last, now.timeIntervalSince(last) < Self.openCoalesceInterval { return }
        stateLock.lock(); lastOpenedAppStoreAt = now; stateLock.unlock()
        let res = try await process.run("/usr/bin/open",
            args: ["macappstore://apps.apple.com/app/id\(store.trackId)"], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .appstore, op: "upgrade", underlying: res.stderr)
        }
    }
```

- [ ] **Step 4: Run tests to verify green**

Run: `swift test --filter AppStoreManagerTests`
Expected: PASS (14 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/GimmeCore/managers/AppStoreManager.swift Tests/GimmeTests/managers/AppStoreManagerTests.swift
git commit -m "feat: AppStoreManager hybrid upgrade via mas or App Store page with coalescing"
```

---

### Task 5: Full suite, docs, and live verification

**Files:**
- Modify: `README.md` (Supported managers table)

**Interfaces:**
- Consumes: the finished adapter from Tasks 2–4 (already wired into `defaultRegistry()` in Task 2).
- Produces: shipping state — docs updated, whole suite green, verified against the real machine.

- [ ] **Step 1: Run the whole suite**

Run: `swift test`
Expected: PASS, zero failures — proves no existing test depends on manager counts or touches the real `/Applications` through `defaultRegistry()` (tests all inject stub registries).

- [ ] **Step 2: README — add a row to the "Supported managers" table** (after the `ubi` row):

```markdown
| **App Store** | receipt scan + iTunes Lookup API | updates only (list/outdated/upgrade); `mas` used for upgrades when installed, else opens the App Store page |
```

(Match the table's existing column layout — check the header row first and adjust the cell text to fit it.)

- [ ] **Step 3: Build everything and verify live on this machine**

```bash
swift build -c release
cp .build/release/gimme /tmp/gimme-ascheck
/tmp/gimme-ascheck outdated
/tmp/gimme-ascheck list | grep -A3 appstore || true
```

Expected: `outdated` includes `appstore:` rows — Slack should show `4.51.180 → 4.51.191` today. The binary runs from `/tmp` because Little Snitch blocks HTTP for binaries launched straight from `.build/` (known machine quirk). If Slack is listed but "outdated" is empty, check the cache dir (`~/.cache/gimme`) for the lookup file and re-run with a cleared cache.

Also verify the GUI compiles and shows the section: `swift build` already compiles GimmeUI; optionally `scripts/package-mac.sh` + launch to eyeball the Updates list.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: list App Store updates adapter in supported managers"
```

---

## Plan self-review notes

- Spec coverage: §3 identity → Task 1; §4.1 scan → Task 2; §4.2 lookup/compare/cache → Task 3; §5 upgrade+coalescing → Task 4; §6 wiring/CLI/GUI → Tasks 2 & 5; §7 testing → every task + Task 5 step 1. Out-of-scope items (§8) are intentionally absent.
- Type consistency: `MASApp`, `LookupResponse`, `lookup(bundleID:)`, `isOlder(_:than:)` names are identical across tasks; the initializer is fixed in Task 2 and only consumed afterward.
- No placeholders: every step carries complete code or exact commands.
