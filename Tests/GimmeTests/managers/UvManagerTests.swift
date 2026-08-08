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
        p.stubs["tool"] = """
        httpie (executable: http)
        yt-dlp (executable: yt-dlp)
        """
        let m = uv(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(Set(pkgs.map { $0.name }), ["httpie", "yt-dlp"])
    }
}
