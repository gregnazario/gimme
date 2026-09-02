import XCTest
@testable import GimmeCore

final class ComposerManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient, @unchecked Sendable {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        var stubs: [String: ProcessResult] = [:]
        func run(_ e: String, args: [String], env: [String: String]?, stream: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.first == "global" && args.count > 1 && args[1] == "show" {
                return stubs["show"] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
            if args == ["--version"] { return stubs["--version"] ?? ProcessResult(exitCode: 0, stdout: "Composer version 2.7.0\n", stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func composer(_ http: HTTPClient? = nil, _ p: StubProcess) -> ComposerManager {
        // Pass a binary override so isAvailable() is true in tests (the real
        // composer may not be installed on the dev machine).
        ComposerManager(http: http ?? StubHTTP(), process: p, binary: "/tmp/composer-stub")
    }

    func testIDAndCapabilities() {
        let m = composer(nil, StubProcess())
        XCTAssertEqual(m.id, .composer)
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]))
    }

    func testSearchQueriesPackagist() async throws {
        let http = StubHTTP()
        // Packagist search: { results: [{ name, description, version }] }
        http.byURL["https://packagist.org/search.json?q=monolog"] = Data(#"""
        {"results":[{"name":"monolog/monolog","description":"Logging","version":"3.5.0"}]}
        """#.utf8)
        let m = composer(http, StubProcess())
        let hits = try await m.search("monolog")
        XCTAssertEqual(hits.first?.name, "monolog/monolog")
        XCTAssertEqual(hits.first?.latestVersion, "3.5.0")
        XCTAssertEqual(hits.first?.manager, .composer)
    }

    func testInstallCallsComposerGlobalRequire() async throws {
        let p = StubProcess()
        let m = composer(nil, p)
        _ = try await m.install(PackageRef(name: "monolog/monolog"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["global", "require", "monolog/monolog"] })
    }

    func testInstallWithVersionAppendsToName() async throws {
        let p = StubProcess()
        let m = composer(nil, p)
        _ = try await m.install(PackageRef(name: "monolog/monolog"), options: InstallOptions(version: "3.0.0"))
        // Composer requires versions as "name:version".
        XCTAssertTrue(p.calls.contains { $0.1 == ["global", "require", "monolog/monolog:3.0.0"] })
    }

    func testUninstallCallsComposerGlobalRemove() async throws {
        let p = StubProcess()
        let m = composer(nil, p)
        try await m.uninstall(PackageRef(name: "monolog/monolog"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["global", "remove", "monolog/monolog"] })
    }

    func testListParsesComposerGlobalShow() async throws {
        let p = StubProcess()
        // `composer global show` lists "vendor/name version" per line.
        p.stubs["show"] = ProcessResult(exitCode: 0, stdout: """
        monolog/monolog 3.5.0 PSR-3 logging
        squizlabs/php_codesniffer 3.9.0 PHP_CodeSniffer
        """, stderr: "")
        let m = composer(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertTrue(pkgs.contains { $0.name == "monolog/monolog" && $0.version == "3.5.0" })
        XCTAssertTrue(pkgs.contains { $0.name == "squizlabs/php_codesniffer" && $0.version == "3.9.0" })
    }

    func testVersion() async throws {
        let p = StubProcess()
        p.stubs["--version"] = ProcessResult(exitCode: 0, stdout: "Composer version 2.7.6\n", stderr: "")
        let m = composer(nil, p)
        let v = await m.version()
        XCTAssertEqual(v, "Composer version 2.7.6")
    }
}
