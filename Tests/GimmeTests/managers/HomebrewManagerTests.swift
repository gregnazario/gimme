import XCTest
@testable import GimmeCore

final class HomebrewManagerTests: XCTestCase {
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
        var dataByURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data {
            dataByURL[url.absoluteString] ?? Data()
        }
    }

    private func brewManager(http: HTTPClient? = nil, process: StubProcess) -> HomebrewManager {
        HomebrewManager(http: http ?? StubHTTP(), process: process, brewBinary: "/opt/homebrew/bin/brew")
    }

    func testIDAndCapabilities() {
        let m = brewManager(process: StubProcess())
        XCTAssertEqual(m.id, .homebrew)
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]))
    }

    func testSearchFiltersFormulaJSON() async throws {
        let http = StubHTTP()
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

    func testInstallCallsBrewInstall() async throws {
        let p = StubProcess()
        let m = brewManager(process: p)
        let result = try await m.install(PackageRef(name: "ripgrep"), options: InstallOptions())
        // install() also calls list to fetch the installed version afterward.
        XCTAssertTrue(p.calls.contains { $0.0 == "/opt/homebrew/bin/brew" && $0.1 == ["install", "ripgrep"] })
        XCTAssertEqual(result.package.name, "ripgrep")
    }

    func testUninstallCallsBrewUninstall() async throws {
        let p = StubProcess()
        let m = brewManager(process: p)
        try await m.uninstall(PackageRef(name: "rg"))
        XCTAssertEqual(p.calls.last?.1, ["uninstall", "rg"])
    }

    func testUpgradeCallsBrewUpgrade() async throws {
        let p = StubProcess()
        let m = brewManager(process: p)
        try await m.upgrade(PackageRef(name: "rg"))
        XCTAssertEqual(p.calls.last?.1, ["upgrade", "rg"])
    }

    func testListParsesBrewListJSON() async throws {
        let p = StubProcess()
        // Real shape from `brew list --json --versions`: formulae use "name",
        // casks use "token" for the identifier.
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: #"""
        {"formulae":[{"name":"ripgrep","versions":["14.1.0"],"linked_version":"14.1.0"}],
         "casks":[{"token":"firefox","versions":["125.0"]}]}
        """#, stderr: "")
        let m = brewManager(process: p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertTrue(pkgs.contains { $0.name == "ripgrep" && $0.version == "14.1.0" })
        XCTAssertTrue(pkgs.contains { $0.name == "firefox" && $0.version == "125.0" })
        XCTAssertTrue(pkgs.allSatisfy { $0.manager == .homebrew })
    }

    func testOutdatedParsesBrewOutdatedJSON() async throws {
        let p = StubProcess()
        p.stubs["outdated"] = ProcessResult(exitCode: 0, stdout: #"""
        {"formulae":[{"name":"ripgrep","installed_versions":["13.0.0"],"current_version":"14.1.0"}],
         "casks":[]}
        """#, stderr: "")
        let m = brewManager(process: p)
        let outdated = try await m.outdated()
        XCTAssertEqual(outdated.count, 1)
        XCTAssertEqual(outdated.first?.installedVersion, "13.0.0")
        XCTAssertEqual(outdated.first?.latestVersion, "14.1.0")
    }
}
