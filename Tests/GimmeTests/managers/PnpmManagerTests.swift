import XCTest
@testable import GimmeCore

final class PnpmManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var stubs: [String: ProcessResult] = [:]
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.first == "list" { return stubs["list"] ?? ProcessResult(exitCode: 0, stdout: "[]", stderr: "") }
            if args == ["--version"] { return stubs["--version"] ?? ProcessResult(exitCode: 0, stdout: "10.0.0\n", stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func pnpm(_ http: HTTPClient? = nil, _ p: StubProcess) -> PnpmManager {
        PnpmManager(http: http ?? StubHTTP(), process: p, binary: "/tmp/pnpm-stub")
    }

    func testIDAndCapabilities() {
        let m = pnpm(nil, StubProcess())
        XCTAssertEqual(m.id, .pnpm)
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]))
    }

    func testSearchQueriesNpm() async throws {
        let http = StubHTTP()
        http.byURL["https://registry.npmjs.org/-/v1/search?text=esbuild&size=25"] = Data(#"""
        {"objects":[{"package":{"name":"esbuild","description":"Bundler","version":"0.21.0"}}]}
        """#.utf8)
        let m = pnpm(http, StubProcess())
        let hits = try await m.search("esbuild")
        XCTAssertEqual(hits.first?.name, "esbuild")
        XCTAssertEqual(hits.first?.manager, .pnpm)
    }

    func testInstallCallsPnpmAddGlobal() async throws {
        let p = StubProcess()
        let m = pnpm(nil, p)
        _ = try await m.install(PackageRef(name: "esbuild"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["add", "-g", "esbuild"] })
    }

    func testInstallHandlesScopedName() async throws {
        let p = StubProcess()
        let m = pnpm(nil, p)
        _ = try await m.install(PackageRef(name: "@babel/core"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["add", "-g", "@babel/core"] })
    }

    func testUninstallCallsPnpmRemoveGlobal() async throws {
        let p = StubProcess()
        let m = pnpm(nil, p)
        try await m.uninstall(PackageRef(name: "esbuild"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["remove", "-g", "esbuild"] })
    }

    func testListParsesPnpmListJson() async throws {
        let p = StubProcess()
        // Real shape of `pnpm list -g --json`: array with one entry whose
        // "dependencies" maps name -> { version }.
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: #"""
        [{"name":"<global>","dependencies":{"esbuild":{"version":"0.21.0"},"typescript":{"version":"5.4.0"}}}]
        """#, stderr: "")
        let m = pnpm(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertTrue(pkgs.contains { $0.name == "esbuild" && $0.version == "0.21.0" })
        XCTAssertTrue(pkgs.contains { $0.name == "typescript" && $0.version == "5.4.0" })
    }

    func testListHandlesEmpty() async throws {
        let p = StubProcess()
        // pnpm emits `[]` when nothing is installed globally.
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: "[]", stderr: "")
        let m = pnpm(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs, [])
    }

    func testVersion() async throws {
        let p = StubProcess()
        p.stubs["--version"] = ProcessResult(exitCode: 0, stdout: "10.33.2\n", stderr: "")
        let m = pnpm(nil, p)
        let v = await m.version()
        XCTAssertEqual(v, "10.33.2")
    }
}
