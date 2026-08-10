import XCTest
@testable import GimmeCore

final class YarnManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var stubs: [String: ProcessResult] = [:]
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            // yarn classic: "yarn global <cmd>"; match on "global list".
            if args.first == "global" && args.count > 1 && args[1] == "list" {
                return stubs["list"] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
            if args == ["--version"] { return stubs["--version"] ?? ProcessResult(exitCode: 0, stdout: "1.22.0\n", stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func yarn(_ http: HTTPClient? = nil, _ p: StubProcess) -> YarnManager {
        // Pass a binary override so isAvailable() is true in tests (the real
        // yarn may not be installed on the dev machine).
        YarnManager(http: http ?? StubHTTP(), process: p, binary: "/tmp/yarn-stub")
    }

    func testIDAndCapabilities() {
        let m = yarn(nil, StubProcess())
        XCTAssertEqual(m.id, .yarn)
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]))
    }

    func testSearchQueriesNpm() async throws {
        let http = StubHTTP()
        http.byURL["https://registry.npmjs.org/-/v1/search?size=25&q=esbuild"] = Data(#"""
        {"objects":[{"package":{"name":"esbuild","description":"Bundler","version":"0.21.0"}}]}
        """#.utf8)
        let m = yarn(http, StubProcess())
        let hits = try await m.search("esbuild")
        XCTAssertEqual(hits.first?.name, "esbuild")
        XCTAssertEqual(hits.first?.manager, .yarn)
    }

    func testInstallCallsYarnGlobalAdd() async throws {
        let p = StubProcess()
        let m = yarn(nil, p)
        _ = try await m.install(PackageRef(name: "esbuild"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["global", "add", "esbuild"] })
    }

    func testInstallHandlesScopedName() async throws {
        let p = StubProcess()
        let m = yarn(nil, p)
        _ = try await m.install(PackageRef(name: "@babel/core"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["global", "add", "@babel/core"] })
    }

    func testUninstallCallsYarnGlobalRemove() async throws {
        let p = StubProcess()
        let m = yarn(nil, p)
        try await m.uninstall(PackageRef(name: "esbuild"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["global", "remove", "esbuild"] })
    }

    func testListParsesYarnGlobalListText() async throws {
        let p = StubProcess()
        // `yarn global list` human output (no --json in v1): one line per pkg,
        // indented, "info \"name@version\" has binaries:\"binary\"".
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: """
        yarn global v1.22.22
        info "esbuild@0.21.0" has binaries:"esbuild"
        info "typescript@5.4.0" has binaries:"tsc, tsserver"
        Done in 0.05s.
        """, stderr: "")
        let m = yarn(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertTrue(pkgs.contains { $0.name == "esbuild" && $0.version == "0.21.0" })
        XCTAssertTrue(pkgs.contains { $0.name == "typescript" && $0.version == "5.4.0" })
    }

    func testVersion() async throws {
        let p = StubProcess()
        p.stubs["--version"] = ProcessResult(exitCode: 0, stdout: "1.22.22\n", stderr: "")
        let m = yarn(nil, p)
        let v = await m.version()
        XCTAssertEqual(v, "1.22.22")
    }
}
