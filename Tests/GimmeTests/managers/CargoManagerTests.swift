import XCTest
@testable import GimmeCore

final class CargoManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var listOutput = ""
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.first == "install" && args.contains("--list") {
                return ProcessResult(exitCode: 0, stdout: listOutput, stderr: "")
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func cargo(_ http: HTTPClient? = nil, _ p: StubProcess) -> CargoManager {
        CargoManager(http: http ?? StubHTTP(), process: p, cargoBinary: "/Users/x/.cargo/bin/cargo")
    }

    func testSearchQueriesCratesIO() async throws {
        let http = StubHTTP()
        http.byURL["https://crates.io/api/v1/crates?q=ripgrep"] = Data(#"""
        {"crates":[{"name":"ripgrep","description":"Search tool","max_version":"14.1.0","homepage":"https://github.com"}]}
        """#.utf8)
        let m = cargo(http, StubProcess())
        let hits = try await m.search("ripgrep")
        XCTAssertEqual(hits.first?.name, "ripgrep")
        XCTAssertEqual(hits.first?.latestVersion, "14.1.0")
    }

    func testInstallCallsCargoInstall() async throws {
        let p = StubProcess()
        let m = cargo(nil, p)
        _ = try await m.install(PackageRef(name: "ripgrep"), options: InstallOptions())
        // install() also calls `install --list` to fetch the version afterward.
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "ripgrep"] })
    }

    func testUpgradeCallsForceReinstall() async throws {
        let p = StubProcess()
        let m = cargo(nil, p)
        try await m.upgrade(PackageRef(name: "rg"))
        XCTAssertEqual(p.calls.last?.1, ["install", "rg", "--force"])
    }

    func testListParsesCargoInstallList() async throws {
        let p = StubProcess()
        p.listOutput = """
        ripgrep v14.1.0:
            rg
        bat v0.24.1:
            bat
        """
        let m = cargo(nil, p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertEqual(pkgs.first?.name, "ripgrep")
        XCTAssertEqual(pkgs.first?.version, "14.1.0")
    }
}
