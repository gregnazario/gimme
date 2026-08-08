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

    func testHintNotFound() async {
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
