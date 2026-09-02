import XCTest
@testable import GimmeCore

final class CargoManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient, @unchecked Sendable {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        var listOutput = ""
        func run(_ e: String, args: [String], env: [String: String]?, stream: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.first == "install" && args.contains("--list") {
                return ProcessResult(exitCode: 0, stdout: listOutput, stderr: "")
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func cargo(_ http: HTTPClient? = nil, _ p: StubProcess) -> CargoManager {
        CargoManager(http: http ?? StubHTTP(), process: p, cargoBinary: "/Users/x/.cargo/bin/cargo")
    }

    func testSearchQueriesCratesIO() async throws {
        let http = StubHTTP()
        http.byURL["https://crates.io/api/v1/crates?q=ripgrep"] = Data(#"""
        {"crates":[{"name":"ripgrep","description":"Search tool","max_version":"14.1.0","homepage":"https://github.com"}]}
        """#.utf8)
        let m = cargo(http, StubProcess())
        let hits = try await m.search("ripgrep")
        XCTAssertEqual(hits.first?.name, "ripgrep")
        XCTAssertEqual(hits.first?.latestVersion, "14.1.0")
    }

    override func setUp() {
        super.setUp()
        // Reset so each test controls binstall availability explicitly.
        CargoManager.setBinstallAvailableForTesting(nil)
        BinaryResolver.clearCache()
    }

    func testInstallPrefersBinstallWhenAvailable() async throws {
        CargoManager.setBinstallAvailableForTesting(true)
        let p = StubProcess()
        let m = cargo(nil, p)
        _ = try await m.install(PackageRef(name: "ripgrep"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["binstall", "-y", "ripgrep"] },
                      "expected cargo binstall when cargo-binstall is available")
    }

    func testInstallWithVersionUsesBinstallSpec() async throws {
        CargoManager.setBinstallAvailableForTesting(true)
        let p = StubProcess()
        let m = cargo(nil, p)
        _ = try await m.install(PackageRef(name: "ripgrep"), options: InstallOptions(version: "14.0.0"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["binstall", "-y", "ripgrep@14.0.0"] })
    }

    func testInstallFallsBackToCargoInstallWhenBinstallAbsent() async throws {
        CargoManager.setBinstallAvailableForTesting(false)
        let p = StubProcess()
        let m = cargo(nil, p)
        _ = try await m.install(PackageRef(name: "ripgrep"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "ripgrep"] },
                      "expected cargo install fallback when cargo-binstall absent")
    }

    func testUpgradeUsesBinstallForceWhenAvailable() async throws {
        CargoManager.setBinstallAvailableForTesting(true)
        let p = StubProcess()
        let m = cargo(nil, p)
        try await m.upgrade(PackageRef(name: "rg"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["binstall", "-y", "--force", "rg"] })
    }

    func testUpgradeFallsBackToForceReinstall() async throws {
        CargoManager.setBinstallAvailableForTesting(false)
        let p = StubProcess()
        let m = cargo(nil, p)
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
        let m = cargo(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertEqual(pkgs.first?.name, "ripgrep")
        XCTAssertEqual(pkgs.first?.version, "14.1.0")
    }

    // MARK: - outdated

    func testOutdatedServedFromCacheWithinTTL() async throws {
        let p = StubProcess()
        p.listOutput = "ripgrep v14.1.0:\n    rg\n"
        let http = StubHTTP()
        http.byURL["https://crates.io/api/v1/crates/ripgrep"] = Data(#"{"crate":{"name":"ripgrep","max_version":"14.1.1"}}"#.utf8)
        let cache = Cache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let m = CargoManager(http: http, process: p, cargoBinary: "/Users/x/.cargo/bin/cargo", indexCache: cache)
        _ = try await m.outdated()
        // Second run with a stub-less client: the cached latest version must
        // still be served with zero network requests.
        let m2 = CargoManager(http: StubHTTP(), process: p, cargoBinary: "/Users/x/.cargo/bin/cargo", indexCache: cache)
        let out = try await m2.outdated()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "ripgrep")
        XCTAssertEqual(out.first?.latestVersion, "14.1.1")
    }
}
