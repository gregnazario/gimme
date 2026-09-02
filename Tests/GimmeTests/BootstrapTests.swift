import XCTest
@testable import GimmeCore

final class BootstrapTests: XCTestCase {
    /// A manager that is initially unavailable and succeeds on bootstrap.
    final class FakeManager: PackageManager, @unchecked Sendable {
        let id: ManagerID = .cargo
        let displayName = "Fake"
        let icon = "circle"
        let capabilities: Set<Capability> = [.install, .bootstrap]
        private var available = false
        var bootstrapCalled = false
        func isAvailable() -> Bool { available }
        func bootstrap() async throws { bootstrapCalled = true; available = true }
        func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
            InstallResult(package: InstalledPackage(name: package.name, version: "1", manager: id, installedAt: nil))
        }
        func uninstall(_ package: PackageRef) async throws {}
        func upgrade(_ package: PackageRef) async throws {}
        func listInstalled() async throws -> [InstalledPackage] { [] }
        func outdated() async throws -> [OutdatedPackage] { [] }
        func search(_ query: String) async throws -> [SearchHit] { [] }
        func info(_ package: PackageRef) async throws -> PackageInfo {
            PackageInfo(name: package.name, manager: id, latestVersion: "1", summary: "", homepage: nil, license: nil, installedVersion: nil, location: nil)
        }
    }

    func testBootstrapWhenDeclinedThrows() async throws {
        let m = FakeManager()
        do {
            try await Bootstrap.run(m, confirm: { _ in false })
            XCTFail("expected throw")
        } catch GimmeError.managerUnavailable(let id) {
            XCTAssertEqual(id, .cargo)
            XCTAssertFalse(m.bootstrapCalled)
        }
    }

    func testBootstrapWhenConfirmedRunsAndSucceeds() async throws {
        let m = FakeManager()
        try await Bootstrap.run(m, confirm: { _ in true })
        XCTAssertTrue(m.bootstrapCalled)
    }

    func testBootstrapSkipsWhenAlreadyAvailable() async throws {
        let m = FakeManager()
        try await Bootstrap.run(m, confirm: { _ in true })
        m.bootstrapCalled = false
        // Second run: manager is now available, so confirm must not even be asked.
        try await Bootstrap.run(m, confirm: { _ in
            XCTFail("confirm should not be called when manager is available")
            return false
        })
        XCTAssertFalse(m.bootstrapCalled)
    }
}

/// The bootstrap scripts install pkg files AS ROOT — they must download into
/// a private mktemp dir and verify a pinned SHA256 before `sudo installer`
/// (audit 2026-08-24: the old scripts used a predictable /tmp path with no
/// verification, letting a local user swap the pkg that root then installs).
final class BootstrapScriptHardeningTests: XCTestCase {
    struct StubNoHTTP: HTTPClient {
        func data(for url: URL) async throws -> Data { Data() }
    }
    final class RecordingProcess: ProcessRunning, @unchecked Sendable {
        var scripts: [String] = []
        var envs: [[String: String]?] = []
        func run(_ e: String, args: [String], env: [String: String]?, stream: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
            if args.first == "-c" { scripts.append(args[1]) }
            envs.append(env)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("askpass-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// GUI bootstraps must pass SUDO_ASKPASS (sudo prefers the terminal when
    /// one exists, so CLI behavior is unchanged) pointing at a 0700 helper.
    private func assertAskpassWired(_ p: RecordingProcess) throws {
        let askpass = try XCTUnwrap(p.envs.first??["SUDO_ASKPASS"])
        XCTAssertTrue(askpass.hasPrefix(tmp.path), "helper written to the injected path, not the real user cache")
        let perms = try FileManager.default.attributesOfItem(atPath: askpass)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
        let script = try String(contentsOf: URL(fileURLWithPath: askpass), encoding: .utf8)
        XCTAssertTrue(script.contains("osascript"))
        XCTAssertTrue(script.contains("with hidden answer"))
    }

    private func assertHardened(_ script: String, pkg: String, sha: String) {
        XCTAssertTrue(script.contains("mktemp -d"), "private temp dir, not a predictable path")
        XCTAssertTrue(script.contains("shasum -a 256 -c"), "checksum verified")
        XCTAssertTrue(script.contains(sha), "pinned SHA256 embedded")
        XCTAssertTrue(script.contains("set -e"), "checksum failure aborts before sudo")
        // The check must run BEFORE the root install.
        XCTAssertLessThan(script.range(of: "shasum")!.lowerBound,
                          script.range(of: "sudo installer")!.lowerBound)
        XCTAssertFalse(script.contains("-o /tmp/\(pkg)"), "no predictable /tmp download path")
    }

    func testGoBootstrapScriptHardened() async throws {
        let p = RecordingProcess()
        try await GoManager(http: StubNoHTTP(), process: p, goBinary: "/tmp/go-stub",
                            askpassURL: tmp.appendingPathComponent("askpass/sudo-askpass.sh")).bootstrap()
        XCTAssertEqual(p.scripts.count, 1)
        assertHardened(p.scripts[0], pkg: "go.pkg",
            sha: "d73ae741ed449ea842238f76f4b02935277eb867689f84ace0640965b2caf700")
        try assertAskpassWired(p)
    }

    func testNpmBootstrapScriptHardened() async throws {
        let p = RecordingProcess()
        try await NpmManager(http: StubNoHTTP(), process: p, binary: "/tmp/npm-stub",
                             askpassURL: tmp.appendingPathComponent("askpass/sudo-askpass.sh")).bootstrap()
        XCTAssertEqual(p.scripts.count, 1)
        assertHardened(p.scripts[0], pkg: "node.pkg",
            sha: "2a7aa14f78d7b764d1552898bf1181da34d3ce40696742c137b8c3ab4079d078")
        try assertAskpassWired(p)
    }
}
