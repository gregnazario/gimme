import XCTest
@testable import GimmeCore

final class NpmManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient, @unchecked Sendable {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        var stubs: [String: ProcessResult] = [:]
        func run(_ e: String, args: [String], env: [String: String]?, stream: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            // Match on first arg (the subcommand) for list/version; exact args otherwise.
            if args.first == "ls" { return stubs["ls"] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "") }
            if args == ["--version"] { return stubs["--version"] ?? ProcessResult(exitCode: 0, stdout: "11.0.0\n", stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func npm(_ http: HTTPClient? = nil, _ p: StubProcess) -> NpmManager {
        NpmManager(http: http ?? StubHTTP(), process: p, binary: "/tmp/npm-stub")
    }

    func testIDAndCapabilities() {
        let m = npm(nil, StubProcess())
        XCTAssertEqual(m.id, .npm)
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]))
    }

    func testSearchQueriesNpm() async throws {
        let http = StubHTTP()
        http.byURL["https://registry.npmjs.org/-/v1/search?text=esbuild&size=25"] = Data(#"""
        {"objects":[{"package":{"name":"esbuild","description":"Bundler","version":"0.21.0"}}]}
        """#.utf8)
        let m = npm(http, StubProcess())
        let hits = try await m.search("esbuild")
        XCTAssertEqual(hits.first?.name, "esbuild")
        XCTAssertEqual(hits.first?.latestVersion, "0.21.0")
    }

    func testInstallCallsNpmInstallGlobal() async throws {
        let p = StubProcess()
        let m = npm(nil, p)
        _ = try await m.install(PackageRef(name: "esbuild"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "-g", "esbuild"] })
    }

    func testInstallHandlesScopedName() async throws {
        let p = StubProcess()
        let m = npm(nil, p)
        _ = try await m.install(PackageRef(name: "@babel/core"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "-g", "@babel/core"] })
    }

    func testUninstallCallsNpmUninstallGlobal() async throws {
        let p = StubProcess()
        let m = npm(nil, p)
        try await m.uninstall(PackageRef(name: "esbuild"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["uninstall", "-g", "esbuild"] })
    }

    func testListParsesNpmLsJson() async throws {
        let p = StubProcess()
        // Real shape of `npm ls -g --depth=0 --json`:
        p.stubs["ls"] = ProcessResult(exitCode: 0, stdout: #"""
        {"dependencies":{"esbuild":{"version":"0.21.0"},"typescript":{"version":"5.4.0"}}}
        """#, stderr: "")
        let m = npm(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertTrue(pkgs.contains { $0.name == "esbuild" && $0.version == "0.21.0" })
        XCTAssertTrue(pkgs.contains { $0.name == "typescript" && $0.version == "5.4.0" })
    }

    func testListHandlesEmptyAndMissingDependencies() async throws {
        let p = StubProcess()
        // No dependencies key (npm emits this when nothing is installed globally).
        p.stubs["ls"] = ProcessResult(exitCode: 0, stdout: #"{"name":"","dependencies":{}}"#, stderr: "")
        let m = npm(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs, [])
    }

    func testVersion() async throws {
        let p = StubProcess()
        p.stubs["--version"] = ProcessResult(exitCode: 0, stdout: "11.17.0\n", stderr: "")
        let m = npm(nil, p)
        let v = await m.version()
        XCTAssertEqual(v, "11.17.0")
    }

    // MARK: - outdated

    private func lsOnePackage() -> StubProcess {
        let p = StubProcess()
        p.stubs["ls"] = ProcessResult(exitCode: 0, stdout: #"{"dependencies":{"typescript":{"version":"5.4.0"}}}"#, stderr: "")
        return p
    }

    func testOutdatedUsesDistTagsEndpoint() async throws {
        let http = StubHTTP()
        // Only the dist-tags URL is stubbed: the old full-packument request
        // (megabytes per package) is deliberately absent — against it this
        // stub decodes nothing and outdated() reports [].
        http.byURL["https://registry.npmjs.org/-/package/typescript/dist-tags"] = Data(#"{"latest":"5.5.4"}"#.utf8)
        let m = npm(http, lsOnePackage())
        let out = try await m.outdated()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "typescript")
        XCTAssertEqual(out.first?.installedVersion, "5.4.0")
        XCTAssertEqual(out.first?.latestVersion, "5.5.4")
    }

    func testOutdatedServedFromCacheWithinTTL() async throws {
        let http = StubHTTP()
        http.byURL["https://registry.npmjs.org/-/package/typescript/dist-tags"] = Data(#"{"latest":"5.5.4"}"#.utf8)
        let cache = Cache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let m = NpmManager(http: http, process: lsOnePackage(), binary: "/tmp/npm-stub", indexCache: cache)
        _ = try await m.outdated()
        // Second run with a stub-less client (any request decodes Data() →
        // nil → skipped): the cached latest version must still be served.
        let m2 = NpmManager(http: StubHTTP(), process: lsOnePackage(), binary: "/tmp/npm-stub", indexCache: cache)
        let out = try await m2.outdated()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.latestVersion, "5.5.4")
    }

    func testOutdatedForceRefreshBypassesResponseCache() async throws {
        let http = StubHTTP()
        http.byURL["https://registry.npmjs.org/-/package/typescript/dist-tags"] = Data(#"{"latest":"5.5.4"}"#.utf8)
        let cache = Cache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let m = NpmManager(http: http, process: lsOnePackage(), binary: "/tmp/npm-stub", indexCache: cache)
        _ = try await m.outdated()  // caches 5.5.4
        http.byURL["https://registry.npmjs.org/-/package/typescript/dist-tags"] = Data(#"{"latest":"5.6.0"}"#.utf8)
        // Normal pass: still the cached value.
        let cached = try await m.outdated()
        XCTAssertEqual(cached.first?.latestVersion, "5.5.4")
        // Force pass: re-asks the registry and overwrites the cache.
        let forced = try await m.outdated(forceRefresh: true)
        XCTAssertEqual(forced.first?.latestVersion, "5.6.0")
    }

    func testListInstalledSpawnedOnceWithinMemoWindow() async throws {
        // The GUI runs `list` and `outdated` concurrently; the subprocess
        // behind listInstalled should spawn once, not twice.
        let p = lsOnePackage()
        let m = npm(nil, p)
        _ = try await m.listInstalled()
        _ = try await m.listInstalled()
        XCTAssertEqual(p.calls.filter { $0.1.first == "ls" }.count, 1)
    }

    func testMutatingOpsInvalidateListMemo() async throws {
        let p = lsOnePackage()
        let m = npm(nil, p)
        _ = try await m.listInstalled()  // memoized
        p.stubs["ls"] = ProcessResult(exitCode: 0, stdout: #"{"dependencies":{"typescript":{"version":"5.5.0"},"esbuild":{"version":"0.21.0"}}}"#, stderr: "")
        _ = try? await m.upgrade(PackageRef(name: "typescript"))  // clears memo
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
    }
}
