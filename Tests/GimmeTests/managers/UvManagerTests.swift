import XCTest
@testable import GimmeCore

final class UvManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var stubs: [String: String] = [:]
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            let out = stubs[args.first ?? ""] ?? ""
            return ProcessResult(exitCode: 0, stdout: out, stderr: "")
        }
    }

    private func uv(_ http: HTTPClient? = nil, _ p: StubProcess) -> UvManager {
        UvManager(http: http ?? StubHTTP(), process: p, uvBinary: "/opt/uv/bin/uv")
    }

    func testCapabilitiesFull() {
        let m = uv(nil, StubProcess())
        XCTAssertTrue(m.capabilities.isSuperset(of: [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]))
    }

    func testSearchQueriesPyPI() async throws {
        let http = StubHTTP()
        http.byURL["https://pypi.org/pypi/httpie/json"] = Data(#"""
        {"info":{"name":"httpie","summary":"CLI HTTP client","home_page":"https://httpie.org","license":"BSD","version":"3.2.0"}}
        """#.utf8)
        let m = uv(http, StubProcess())
        let hits = try await m.search("httpie")
        XCTAssertEqual(hits.first?.name, "httpie")
        XCTAssertEqual(hits.first?.latestVersion, "3.2.0")
    }

    func testInstallCallsUvToolInstall() async throws {
        let p = StubProcess()
        let m = uv(nil, p)
        _ = try await m.install(PackageRef(name: "httpie"), options: InstallOptions())
        XCTAssertEqual(p.calls.last?.1, ["tool", "install", "httpie"])
    }

    func testListParsesUvToolList() async throws {
        let p = StubProcess()
        // Current `uv tool list` prints one block per tool: a "name vX.Y.Z"
        // line followed by "- executable" bullets.
        p.stubs["tool"] = """
        pycowsay v0.0.0.2
        - pycowsay
        httpie v3.2.3
        - http
        - https
        """
        let m = uv(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertTrue(pkgs.contains { $0.name == "pycowsay" && $0.version == "0.0.0.2" })
        XCTAssertTrue(pkgs.contains { $0.name == "httpie" && $0.version == "3.2.3" })
    }

    func testListStillUnderstandsLegacyFormat() async throws {
        let p = StubProcess()
        // Older uv printed "name (executable: bin)" without versions.
        p.stubs["tool"] = """
        httpie (executable: http)
        yt-dlp (executable: yt-dlp)
        """
        let m = uv(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(Set(pkgs.map { $0.name }), ["httpie", "yt-dlp"])
    }

    func testOutdatedComparesVersionsWithoutVPrefix() async throws {
        let p = StubProcess()
        p.stubs["tool"] = """
        pycowsay v0.0.0.2
        - pycowsay
        httpie v3.2.3
        """
        let http = StubHTTP()
        http.byURL["https://pypi.org/pypi/pycowsay/json"] = Data(#"""
        {"info":{"name":"pycowsay","version":"0.0.0.2"}}
        """#.utf8)
        http.byURL["https://pypi.org/pypi/httpie/json"] = Data(#"""
        {"info":{"name":"httpie","version":"3.3.0"}}
        """#.utf8)
        let m = uv(http, p)
        let outdated = try await m.outdated()
        // Current-on-PyPI tool (v0.0.0.2 == 0.0.0.2) must NOT be flagged;
        // only the genuinely stale one appears.
        XCTAssertEqual(outdated.count, 1)
        XCTAssertEqual(outdated.first?.name, "httpie")
        XCTAssertEqual(outdated.first?.installedVersion, "3.2.3")
        XCTAssertEqual(outdated.first?.latestVersion, "3.3.0")
    }

    func testOutdatedServedFromCacheWithinTTL() async throws {
        let p = StubProcess()
        p.stubs["tool"] = "httpie v3.2.3\n- http\n"
        let http = StubHTTP()
        http.byURL["https://pypi.org/pypi/httpie/json"] = Data(#"{"info":{"name":"httpie","version":"3.3.0"}}"#.utf8)
        let cache = Cache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let m = UvManager(http: http, process: p, uvBinary: "/opt/uv/bin/uv", indexCache: cache)
        _ = try await m.outdated()
        // Second run with a stub-less client: the cached latest version must
        // still be served with zero network requests.
        let m2 = UvManager(http: StubHTTP(), process: p, uvBinary: "/opt/uv/bin/uv", indexCache: cache)
        let out = try await m2.outdated()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "httpie")
        XCTAssertEqual(out.first?.latestVersion, "3.3.0")
    }
}
