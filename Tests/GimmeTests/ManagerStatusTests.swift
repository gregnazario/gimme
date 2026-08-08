import XCTest
@testable import GimmeCore

final class ManagerStatusTests: XCTestCase {
    /// A manager that reports a fixed version when available.
    final class VersionedStub: PackageManager {
        let id: ManagerID; let available: Bool; let reportedVersion: String?
        init(id: ManagerID, available: Bool, version: String? = nil) {
            self.id = id; self.available = available; self.reportedVersion = version
        }
        let displayName = "Stub"; let icon = "circle"; let capabilities: Set<Capability> = [.install]
        func isAvailable() -> Bool { available }
        func bootstrap() async throws {}
        func version() async -> String? { reportedVersion }
        func install(_ p: PackageRef, options: InstallOptions) async throws -> InstallResult { fatalError() }
        func uninstall(_ p: PackageRef) async throws {}
        func upgrade(_ p: PackageRef) async throws {}
        func listInstalled() async throws -> [InstalledPackage] { [] }
        func outdated() async throws -> [OutdatedPackage] { [] }
        func search(_ q: String) async throws -> [SearchHit] { [] }
        func info(_ p: PackageRef) async throws -> PackageInfo { fatalError() }
    }

    private func gimme(_ managers: [any PackageManager], config: Config = .defaults) -> Gimme {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Gimme(registry: Registry(managers: managers), preferences: Preferences(), config: config,
                     cache: Cache(directory: tmp.appendingPathComponent("cache")),
                     preferencesFile: tmp.appendingPathComponent("preferences.toml"))
    }

    func testStatusesReportsAvailableAndVersion() async {
        let g = gimme([
            VersionedStub(id: .homebrew, available: true, version: "Homebrew 6.0.15"),
            VersionedStub(id: .cargo, available: false)
        ])
        let statuses = await g.statuses()
        XCTAssertEqual(statuses.count, 2)
        let brew = statuses.first { $0.id == .homebrew }!
        XCTAssertTrue(brew.available)
        XCTAssertEqual(brew.version, "Homebrew 6.0.15")
        XCTAssertTrue(brew.enabled)
        let cargo = statuses.first { $0.id == .cargo }!
        XCTAssertFalse(cargo.available)
        XCTAssertNil(cargo.version)
    }

    func testStatusesMarksDisabled() async {
        var cfg = Config.defaults
        cfg.disabled = ["go"]
        let g = gimme([VersionedStub(id: .homebrew, available: true),
                       VersionedStub(id: .go, available: true)], config: cfg)
        let statuses = await g.statuses()
        let go = statuses.first { $0.id == .go }!
        XCTAssertTrue(go.available)
        XCTAssertFalse(go.enabled)
    }

    func testStatusesOrderedByPriority() async {
        let g = gimme([
            VersionedStub(id: .bun, available: true),
            VersionedStub(id: .homebrew, available: true),
            VersionedStub(id: .cargo, available: true)
        ])
        let statuses = await g.statuses()
        // Default priority: homebrew, go, uv, cargo, bun
        XCTAssertEqual(statuses.map(\.id), [.homebrew, .cargo, .bun])
    }
}
