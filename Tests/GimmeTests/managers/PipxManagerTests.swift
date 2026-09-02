import XCTest
@testable import GimmeCore

final class PipxManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient, @unchecked Sendable {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        var stubs: [String: ProcessResult] = [:]
        func run(_ e: String, args: [String], env: [String: String]?, stream: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.first == "list" { return stubs["list"] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "") }
            if args == ["--version"] { return stubs["--version"] ?? ProcessResult(exitCode: 0, stdout: "1.16.0\n", stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func pipx(_ http: HTTPClient? = nil, _ p: StubProcess) -> PipxManager {
        PipxManager(http: http ?? StubHTTP(), process: p, binary: "/tmp/pipx-stub")
    }

    func testIDAndCapabilities() {
        let m = pipx(nil, StubProcess())
        XCTAssertEqual(m.id, .pipx)
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]))
    }

    func testSearchQueriesPyPI() async throws {
        let http = StubHTTP()
        http.byURL["https://pypi.org/pypi/black/json"] = Data(#"""
        {"info":{"name":"black","summary":"Code formatter","version":"26.1.0"}}
        """#.utf8)
        let m = pipx(http, StubProcess())
        let hits = try await m.search("black")
        XCTAssertEqual(hits.first?.name, "black")
        XCTAssertEqual(hits.first?.latestVersion, "26.1.0")
        XCTAssertEqual(hits.first?.manager, .pipx)
    }

    func testInstallCallsPipxInstall() async throws {
        let p = StubProcess()
        let m = pipx(nil, p)
        _ = try await m.install(PackageRef(name: "black"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "black"] })
    }

    func testInstallWithVersion() async throws {
        let p = StubProcess()
        let m = pipx(nil, p)
        _ = try await m.install(PackageRef(name: "black"), options: InstallOptions(version: "24.0.0"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "black==24.0.0"] })
    }

    func testUninstallCallsPipxUninstall() async throws {
        let p = StubProcess()
        let m = pipx(nil, p)
        try await m.uninstall(PackageRef(name: "black"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["uninstall", "black"] })
    }

    func testListParsesPipxListJson() async throws {
        let p = StubProcess()
        // Real shape: { venvs: { name: { metadata: { main_package: { package_version } } } } }
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: #"""
        {"pipx_spec_version":"0.1","venvs":{"black":{"metadata":{"main_package":{"package_version":"26.1.0"}}},"httpie":{"metadata":{"main_package":{"package_version":"3.2.0"}}}}}
        """#, stderr: "")
        let m = pipx(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertTrue(pkgs.contains { $0.name == "black" && $0.version == "26.1.0" })
        XCTAssertTrue(pkgs.contains { $0.name == "httpie" && $0.version == "3.2.0" })
    }

    func testListHandlesEmpty() async throws {
        let p = StubProcess()
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: #"{"venvs":{}}"#, stderr: "")
        let m = pipx(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs, [])
    }

    func testVersion() async throws {
        let p = StubProcess()
        p.stubs["--version"] = ProcessResult(exitCode: 0, stdout: "1.16.0\n", stderr: "")
        let m = pipx(nil, p)
        let v = await m.version()
        XCTAssertEqual(v, "1.16.0")
    }

    // MARK: - outdated

    func testOutdatedServedFromCacheWithinTTL() async throws {
        let p = StubProcess()
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: #"{"venvs":{"httpie":{"metadata":{"main_package":{"package_version":"3.2.0"}}}}}"#, stderr: "")
        let http = StubHTTP()
        http.byURL["https://pypi.org/pypi/httpie/json"] = Data(#"{"info":{"name":"httpie","version":"3.3.0"}}"#.utf8)
        let cache = Cache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let m = PipxManager(http: http, process: p, binary: "/tmp/pipx-stub", indexCache: cache)
        _ = try await m.outdated()
        // Second run with a stub-less client: the cached latest version must
        // still be served with zero network requests.
        let m2 = PipxManager(http: StubHTTP(), process: p, binary: "/tmp/pipx-stub", indexCache: cache)
        let out = try await m2.outdated()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "httpie")
        XCTAssertEqual(out.first?.latestVersion, "3.3.0")
    }
}
