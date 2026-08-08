import XCTest
@testable import GimmeCore

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
