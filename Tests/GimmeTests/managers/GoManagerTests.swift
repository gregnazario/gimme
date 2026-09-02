import XCTest
@testable import GimmeCore

final class GoManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient, @unchecked Sendable {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        func run(_ e: String, args: [String], env: [String: String]?, stream: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func testCapabilities() {
        let m = GoManager(http: StubHTTP(), process: StubProcess())
        XCTAssertFalse(m.capabilities.contains(.outdated), "Go has no reliable outdated")
        // Go advertises .search even though it's exact-existence only (via the
        // module proxy). Without it, the resolver skips Go for search/info.
        XCTAssertTrue(m.capabilities.contains(.search))
    }

    func testSearchExactOnly() async throws {
        let http = StubHTTP()
        http.byURL["https://proxy.golang.org/github.com/spf13/cobra/@latest"] = Data(#"{"Version":"v1.8.0"}"#.utf8)
        let m = GoManager(http: http, process: StubProcess())
        let hits = try await m.search("github.com/spf13/cobra")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.latestVersion, "v1.8.0")
    }

    func testSearchMissReturnsEmpty() async throws {
        let http = StubHTTP()
        http.byURL["https://proxy.golang.org/nope/@latest"] = Data()  // empty / would error
        let m = GoManager(http: http, process: StubProcess())
        let hits = try await m.search("nope")
        XCTAssertEqual(hits, [])
    }

    func testInstallCallsGoInstall() async throws {
        let p = StubProcess()
        let m = GoManager(http: StubHTTP(), process: p, goBinary: "/usr/local/go/bin/go")
        _ = try await m.install(PackageRef(name: "github.com/spf13/cobra"), options: InstallOptions())
        XCTAssertEqual(p.calls.last?.0, "/usr/local/go/bin/go")
        XCTAssertEqual(p.calls.last?.1, ["install", "github.com/spf13/cobra@latest"])
    }
}
