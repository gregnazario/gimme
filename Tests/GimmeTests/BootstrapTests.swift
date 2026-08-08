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
        try await Bootstrap.run(m, confirm: { _ in true })
        m.bootstrapCalled = false
        // Second run: manager is now available, so confirm must not even be asked.
        try await Bootstrap.run(m, confirm: { _ in
            XCTFail("confirm should not be called when manager is available")
            return false
        })
        XCTAssertFalse(m.bootstrapCalled)
    }
}
