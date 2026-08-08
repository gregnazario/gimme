import XCTest
@testable import GimmeCore

final class GoManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func testCapabilitiesOmitOutdated() {
        let m = GoManager(http: StubHTTP(), process: StubProcess())
        XCTAssertFalse(m.capabilities.contains(.outdated))
        XCTAssertFalse(m.capabilities.contains(.search))  // no fuzzy search
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
