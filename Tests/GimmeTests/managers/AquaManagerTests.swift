import XCTest
@testable import GimmeCore

final class AquaManagerTests: XCTestCase {
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var stubs: [String: ProcessResult] = [:]
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.first == "list" { return stubs["list"] ?? ProcessResult(exitCode: 0, stdout: "", stderr: "") }
            if args == ["--version"] { return stubs["--version"] ?? ProcessResult(exitCode: 0, stdout: "aqua version 2.0.0\n", stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func aqua(_ p: StubProcess) -> AquaManager {
        AquaManager(process: p, binary: "/tmp/aqua-stub")
    }

    func testIDAndCapabilities() {
        let m = aqua(StubProcess())
        XCTAssertEqual(m.id, .aqua)
        XCTAssertTrue(m.capabilities.contains(.install))
        XCTAssertFalse(m.capabilities.contains(.outdated))   // not supported
        XCTAssertFalse(m.capabilities.contains(.search))      // exact-existence only
    }

    func testInstallCallsAquaInstall() async throws {
        let p = StubProcess()
        let m = aqua(p)
        _ = try await m.install(PackageRef(name: "BurntSushi/ripgrep"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1 == ["install", "BurntSushi/ripgrep"] })
    }

    func testUninstallCallsAquaRm() async throws {
        let p = StubProcess()
        let m = aqua(p)
        try await m.uninstall(PackageRef(name: "BurntSushi/ripgrep"))
        XCTAssertTrue(p.calls.contains { $0.1 == ["rm", "BurntSushi/ripgrep"] })
    }

    func testListParsesAquaList() async throws {
        let p = StubProcess()
        // `aqua list` output: "owner/repo@version" lines, or "owner/repo".
        p.stubs["list"] = ProcessResult(exitCode: 0, stdout: """
        BurntSushi/ripgrep
        sharkdp/bat@0.24.0
        """, stderr: "")
        let m = aqua(p)
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertTrue(pkgs.contains { $0.name == "BurntSushi/ripgrep" })
        XCTAssertTrue(pkgs.contains { $0.name == "sharkdp/bat" && $0.version == "0.24.0" })
    }

    func testVersion() async throws {
        let p = StubProcess()
        p.stubs["--version"] = ProcessResult(exitCode: 0, stdout: "aqua version 2.46.0\n", stderr: "")
        let m = aqua(p)
        let v = await m.version()
        XCTAssertEqual(v, "aqua version 2.46.0")
    }
}
