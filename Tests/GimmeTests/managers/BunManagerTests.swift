import XCTest
@testable import GimmeCore

final class BunManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var lsOutput = ""
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.contains("ls") { return ProcessResult(exitCode: 0, stdout: lsOutput, stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func bun(_ http: HTTPClient? = nil, _ p: StubProcess) -> BunManager {
        BunManager(http: http ?? StubHTTP(), process: p, bunBinary: "/Users/x/.bun/bin/bun")
    }

    func testSearchQueriesNpm() async throws {
        let http = StubHTTP()
        http.byURL["https://registry.npmjs.org/-/v1/search?size=25&q=esbuild"] = Data(#"""
        {"objects":[{"package":{"name":"esbuild","description":"Bundler","version":"0.21.0"}}]}
        """#.utf8)
        let m = bun(http, StubProcess())
        let hits = try await m.search("esbuild")
        XCTAssertEqual(hits.first?.name, "esbuild")
        XCTAssertEqual(hits.first?.latestVersion, "0.21.0")
    }

    func testInstallCallsBunInstallGlobal() async throws {
        let p = StubProcess()
        let m = bun(nil, p)
        _ = try await m.install(PackageRef(name: "esbuild"), options: InstallOptions())
        XCTAssertEqual(p.calls.last?.1, ["install", "-g", "esbuild"])
    }

    func testInstallHandlesScopedName() async throws {
        let p = StubProcess()
        let m = bun(nil, p)
        _ = try await m.install(PackageRef(name: "@babel/core"), options: InstallOptions())
        XCTAssertEqual(p.calls.last?.1, ["install", "-g", "@babel/core"])
    }

    func testUninstallCallsBunRemoveGlobal() async throws {
        let p = StubProcess()
        let m = bun(nil, p)
        try await m.uninstall(PackageRef(name: "esbuild"))
        XCTAssertEqual(p.calls.last?.1, ["remove", "-g", "esbuild"])
    }

    func testListParsesBunPmLs() async throws {
        let p = StubProcess()
        p.lsOutput = """
        esbuild@0.21.0
        typescript@5.4.0
        """
        let m = bun(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertEqual(pkgs.first?.name, "esbuild")
        XCTAssertEqual(pkgs.first?.version, "0.21.0")
    }
}
