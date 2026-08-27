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

    func testSearchUsesBrewCli() async throws {
        // Primary path: `brew search` (local, instant). Names only; enrichment
        // from a warm cached index is separate.
        let p = StubProcess()
        p.stubs["search"] = ProcessResult(exitCode: 0, stdout: """
        ripgrep
        ripgrep-all
        """, stderr: "")
        let m = brewManager(process: p)
        let hits = try await m.search("ripgrep")
        XCTAssertEqual(hits.map { $0.name }, ["ripgrep", "ripgrep-all"])
        XCTAssertEqual(p.calls.last?.1, ["search", "ripgrep"])
    }

    func testSearchFallsBackToApiWhenCliFails() async throws {
        // CLI errors (exit 1) → API fallback with rich metadata.
        let http = StubHTTP()
        let payload = #"""
        [{"name":"ripgrep","desc":"Search tool","versions":{"stable":"14.1.0"}},
         {"name":"bat","desc":"Cat clone","versions":{"stable":"0.24.0"}}]
        """#
        http.dataByURL["https://formulae.brew.sh/api/formula.json"] = Data(payload.utf8)
        let p = StubProcess()
        p.stubs["search"] = ProcessResult(exitCode: 1, stdout: "", stderr: "boom")
        let m = HomebrewManager(http: http, process: p, brewBinary: "/opt/homebrew/bin/brew")
        let hits = try await m.search("ripgrep")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.name, "ripgrep")
        XCTAssertEqual(hits.first?.latestVersion, "14.1.0")
    }

    func testApiSearchIncludesCasksBestEffort() async throws {
        let http = StubHTTP()
        http.dataByURL["https://formulae.brew.sh/api/formula.json"] = Data(#"[]"#.utf8)
        http.dataByURL["https://formulae.brew.sh/api/cask.json"] = Data(#"""
        [{"token":"firefox","desc":"Web browser","version":"125.0"}]
        """#.utf8)
        let p = StubProcess()
        p.stubs["search"] = ProcessResult(exitCode: 1, stdout: "", stderr: "cli down")
        let m = HomebrewManager(http: http, process: p, brewBinary: "/opt/homebrew/bin/brew")
        let hits = try await m.search("fire")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.name, "firefox")
        XCTAssertEqual(hits.first?.latestVersion, "125.0")
    }

    func testApiSearchSurvivesCaskIndexFailure() async throws {
        let http = StubHTTP()
        // Formula index fine; cask URL unstubbed → empty data → best-effort [].
        http.dataByURL["https://formulae.brew.sh/api/formula.json"] = Data(#"""
        [{"name":"ripgrep","desc":"Search tool","versions":{"stable":"14.1.0"}}]
        """#.utf8)
        let p = StubProcess()
        p.stubs["search"] = ProcessResult(exitCode: 1, stdout: "", stderr: "cli down")
        let m = HomebrewManager(http: http, process: p, brewBinary: "/opt/homebrew/bin/brew")
        let hits = try await m.search("ripgrep")
        XCTAssertEqual(hits.count, 1, "formula hits must survive cask-index failure")
        XCTAssertEqual(hits.first?.name, "ripgrep")
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

    // MARK: - list memoization

    private func listJSON(_ names: [String]) -> String {
        let formulae = names.map { #"{"name":"\#($0)","versions":["1.0"]}"# }.joined(separator: ",")
        return #"{"formulae":[\#(formulae)],"casks":[]}"#
    }

    func testListInstalledSpawnedOnceWithinMemoWindow() async throws {
        // The GUI runs `list` and `outdated` concurrently; the expensive brew
        // list subprocess (~0.6 s) should spawn once, not twice.
        let p = StubProcess()
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: listJSON(["rg"]), stderr: "")
        let m = brewManager(process: p)
        _ = try await m.listInstalled()
        _ = try await m.listInstalled()
        XCTAssertEqual(p.calls.filter { $0.1.first == "list" }.count, 1)
    }

    func testMutatingOpsInvalidateListMemo() async throws {
        let p = StubProcess()
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: listJSON(["rg"]), stderr: "")
        let m = brewManager(process: p)
        _ = try await m.listInstalled()  // memoized
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: listJSON(["rg", "bat"]), stderr: "")
        _ = try? await m.upgrade(PackageRef(name: "rg"))  // clears memo
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
    }
}
