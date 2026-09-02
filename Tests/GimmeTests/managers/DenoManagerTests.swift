import XCTest
@testable import GimmeCore

final class DenoManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient, @unchecked Sendable {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        var stubs: [String: ProcessResult] = [:]
        func run(_ e: String, args: [String], env: [String: String]?, stream: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args == ["--version"] { return stubs["--version"] ?? ProcessResult(exitCode: 0, stdout: "deno 2.9.3\n", stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func deno(_ http: HTTPClient? = nil, _ p: StubProcess) -> DenoManager {
        DenoManager(http: http ?? StubHTTP(), process: p, binary: "/tmp/deno-stub")
    }

    func testIDAndCapabilities() {
        let m = deno(nil, StubProcess())
        XCTAssertEqual(m.id, .deno)
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .list, .search, .info, .bootstrap]))
    }

    func testSearchQueriesJSR() async throws {
        let http = StubHTTP()
        http.byURL["https://jsr.io/api/packages?search=file-server"] = Data(#"""
        {"items":[{"scope":"std","name":"http","description":"HTTP utilities","latestVersion":"1.0.0","githubRepository":{"owner":"denoland","name":"deno"}}]}
        """#.utf8)
        let m = deno(http, StubProcess())
        let hits = try await m.search("file-server")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.name, "@std/http")
        XCTAssertEqual(hits.first?.latestVersion, "1.0.0")
        XCTAssertEqual(hits.first?.manager, .deno)
    }

    func testInstallCallsDenoInstallGlobal() async throws {
        let p = StubProcess()
        let m = deno(nil, p)
        _ = try await m.install(PackageRef(name: "jsr:@std/http"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "-g", "jsr:@std/http"] })
    }

    func testInstallHandlesNpmPrefix() async throws {
        let p = StubProcess()
        let m = deno(nil, p)
        _ = try await m.install(PackageRef(name: "npm:esbuild"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "-g", "npm:esbuild"] })
    }

    func testUninstallRemovesBinary() async throws {
        // Deno has no uninstall command; we remove the binary from the bin dir.
        // The on-disk binary name is the last path segment of the package spec,
        // so "@std/http" -> "http".
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bin = tmp.appendingPathComponent("http")
        try Data().write(to: bin)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.path))
        let m = DenoManager(http: StubHTTP(), process: StubProcess(), binary: "/tmp/deno-stub", denoBinDir: tmp.path)
        try await m.uninstall(PackageRef(name: "@std/http"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.path),
                       "uninstall should remove the derived binary name")
    }

    func testVersion() async throws {
        let p = StubProcess()
        p.stubs["--version"] = ProcessResult(exitCode: 0, stdout: "deno 2.9.3 (long term support)\nv8 14.9.207.2\n", stderr: "")
        let m = deno(nil, p)
        let v = await m.version()
        XCTAssertEqual(v, "deno 2.9.3 (long term support)")
    }
}
