import XCTest
@testable import GimmeCore

final class GemManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var stubs: [String: ProcessResult] = [:]
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.first == "list" { return stubs["list"] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "") }
            if args == ["--version"] { return stubs["--version"] ?? ProcessResult(exitCode: 0, stdout: "4.0.0\n", stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func gem(_ http: HTTPClient? = nil, _ p: StubProcess) -> GemManager {
        // Pass a binary override so isAvailable() is true in tests (the real
        // gem may not be installed on the dev machine).
        GemManager(http: http ?? StubHTTP(), process: p, binary: "/tmp/gem-stub")
    }

    func testIDAndCapabilities() {
        let m = gem(nil, StubProcess())
        XCTAssertEqual(m.id, .gem)
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]))
    }

    func testSearchQueriesRubygems() async throws {
        let http = StubHTTP()
        // rubygems.org search API: { gems: [{ name, version, info, project_uri }] }
        http.byURL["https://rubygems.org/api/v1/search.json?query=rails"] = Data(#"""
        [{"name":"rails","version":"7.1.0","info":"Full-stack web framework","project_uri":"https://rubygems.org/gems/rails"}]
        """#.utf8)
        let m = gem(http, StubProcess())
        let hits = try await m.search("rails")
        XCTAssertEqual(hits.first?.name, "rails")
        XCTAssertEqual(hits.first?.latestVersion, "7.1.0")
        XCTAssertEqual(hits.first?.manager, .gem)
    }

    func testInstallCallsGemInstall() async throws {
        let p = StubProcess()
        let m = gem(nil, p)
        _ = try await m.install(PackageRef(name: "rails"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "rails"] })
    }

    func testInstallWithVersionPassesFlag() async throws {
        let p = StubProcess()
        let m = gem(nil, p)
        _ = try await m.install(PackageRef(name: "rails"), options: InstallOptions(version: "6.1.0"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "rails", "--version", "6.1.0"] })
    }

    func testUninstallCallsGemUninstall() async throws {
        let p = StubProcess()
        let m = gem(nil, p)
        try await m.uninstall(PackageRef(name: "rails"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["uninstall", "-x", "-a", "rails"] })
    }

    func testListParsesGemList() async throws {
        let p = StubProcess()
        // `gem list` output: "name (version)" possibly comma-separated versions.
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: """
        bundler (2.5.0)
        rake (13.0.6, 12.0.0)
        rails (7.1.0)
        *** Local Gems ***
        """, stderr: "")
        let m = gem(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 3)
        XCTAssertTrue(pkgs.contains { $0.name == "bundler" && $0.version == "2.5.0" })
        XCTAssertTrue(pkgs.contains { $0.name == "rake" && $0.version == "13.0.6" })  // first version wins
        XCTAssertTrue(pkgs.contains { $0.name == "rails" && $0.version == "7.1.0" })
    }

    func testListStripsPlatformSuffix() async throws {
        let p = StubProcess()
        // Platform-specific gems list the platform after the version
        // ("1.17.4 arm64-darwin"); comparing against rubygems.org's plain
        // version would flag them as outdated forever.
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: """
        ffi (1.17.4 arm64-darwin, 1.17.3 arm64-darwin)
        google-protobuf (4.35.1 arm64-darwin, 4.33.2)
        rdoc (8.0.0, 7.0.4)
        """, stderr: "")
        let m = gem(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 3)
        XCTAssertTrue(pkgs.contains { $0.name == "ffi" && $0.version == "1.17.4" })
        XCTAssertTrue(pkgs.contains { $0.name == "google-protobuf" && $0.version == "4.35.1" })
        XCTAssertTrue(pkgs.contains { $0.name == "rdoc" && $0.version == "8.0.0" })
    }

    func testVersion() async throws {
        let p = StubProcess()
        p.stubs["--version"] = ProcessResult(exitCode: 0, stdout: "4.0.16\n", stderr: "")
        let m = gem(nil, p)
        let v = await m.version()
        XCTAssertEqual(v, "4.0.16")
    }
}
