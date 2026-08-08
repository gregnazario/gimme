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
