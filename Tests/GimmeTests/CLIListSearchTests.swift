import XCTest
@testable import GimmeCore

final class CLIListSearchTests: XCTestCase {
    private func makeGimme(tmp: URL, managers: [any PackageManager]) -> Gimme {
        Gimme(registry: Registry(managers: managers), preferences: Preferences(),
              config: .defaults, cache: Cache(directory: tmp.appendingPathComponent("cache")),
              preferencesFile: tmp.appendingPathComponent("preferences.toml"))
    }

    func testListMergesAllManagers() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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

final class CLIUpdateDoctorTests: XCTestCase {
    private func makeGimme(tmp: URL, managers: [any PackageManager]) -> Gimme {
        Gimme(registry: Registry(managers: managers), preferences: Preferences(),
              config: .defaults, cache: Cache(directory: tmp.appendingPathComponent("cache")),
              preferencesFile: tmp.appendingPathComponent("preferences.toml"))
    }

    final class UpdatableCls: PackageManager, @unchecked Sendable {
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

    func testUpdateUpgradesAllOutdatedPerManager() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let brew = UpdatableCls(id: .homebrew, outdatedList: [OutdatedPackage(name: "rg", installedVersion: "1", latestVersion: "2", manager: .homebrew)])
        let gimme = makeGimme(tmp: tmp, managers: [brew])
        let summary = try await gimme.updateAll()
        XCTAssertEqual(summary.succeeded, ["homebrew:rg"])
        XCTAssertTrue(brew.upgraded.contains("rg"))
    }

    func testUpdatePartialFailureRecorded() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        final class FailingUpgradable: PackageManager, @unchecked Sendable {
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
        XCTAssertTrue(summary.failed.contains { $0.id == "homebrew:rg" })
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
