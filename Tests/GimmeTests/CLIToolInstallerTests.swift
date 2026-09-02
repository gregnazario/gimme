import XCTest
@testable import GimmeCore

/// `CLIToolInstaller` — installs/updates the gimme CLI from GitHub releases
/// into a user bin dir (GUI menu-bar command). All seams are stubbed: no real
/// network, no machine paths (see AGENTS.md test-isolation rules).
final class CLIToolInstallerTests: XCTestCase {
    /// Delegates tar invocations and real executables to a ProcessRunner so
    /// fixture scripts genuinely run; declines anything not executable (like
    /// a broken/non-executable installed binary would).
    class TarAndVersionStub: ProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        private let real = ProcessRunner()
        func run(_ e: String, args: [String], env: [String: String]?, stream: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if e.hasSuffix("/tar") { return try await real.run(e, args: args, env: env, stream: stream) }
            if args.first == "--version" {
                guard FileManager.default.isExecutableFile(atPath: e) else {
                    return ProcessResult(exitCode: 126, stdout: "", stderr: "not executable")
                }
                return try await real.run(e, args: args, env: env, stream: stream)
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    final class StubHTTP: HTTPClient, @unchecked Sendable {
        var byURL: [String: Data] = [:]
        /// Set when the installer must not reach the network at all.
        private(set) var requestCount = 0
        func data(for url: URL) async throws -> Data {
            requestCount += 1
            return byURL[url.absoluteString] ?? Data()
        }
    }

    var tmp: URL!
    var http: StubHTTP!
    var process: TarAndVersionStub!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clitool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        http = StubHTTP()
        process = TarAndVersionStub()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixtures

    /// A real tar.gz containing a runnable `gimme` that prints its version.
    /// The entry carries the execute bit, like a real release artifact — the
    /// downloaded binary is executed for version verification.
    private func makeCLIFixture(version: String) async throws -> Data {
        let src = tmp.appendingPathComponent("fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let script = "#!/bin/sh\necho \"gimme \(version)\"\n"
        let bin = src.appendingPathComponent("gimme")
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let tarPath = tmp.appendingPathComponent("gimme-darwin-arm64.tar.gz")
        _ = try await ProcessRunner().run("/usr/bin/tar",
            args: ["-czf", tarPath.path, "-C", src.path, "gimme"], env: nil, stream: nil)
        return try Data(contentsOf: tarPath)
    }

    private func stubLatestRelease(fixtureVersion: String) async throws {
        let fixture = try await makeCLIFixture(version: fixtureVersion)
        http.byURL["https://api.github.com/repos/gregnazario/gimme/releases/latest"] = Data(#"""
        {"tag_name":"v2.4.0","assets":[{"name":"gimme-darwin-arm64.tar.gz","browser_download_url":"https://example.com/gimme-darwin-arm64.tar.gz"}]}
        """#.utf8)
        http.byURL["https://example.com/gimme-darwin-arm64.tar.gz"] = fixture
    }

    private func sut(installDir: URL? = nil, locate: (@Sendable () -> String?)? = nil) -> CLIToolInstaller {
        CLIToolInstaller(http: http, process: process,
                         installDir: installDir ?? tmp.appendingPathComponent("bin"),
                         locate: locate ?? { nil })
    }

    // MARK: - installedVersion parsing

    func testInstalledVersionParsesGimmePrefix() async throws {
        let bin = tmp.appendingPathComponent("gimme")
        try "#!/bin/sh\necho \"gimme 2.3.2\"\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        // Real process runner so the script itself is executed.
        let installer = CLIToolInstaller(http: http, process: ProcessRunner(),
                                         installDir: tmp.appendingPathComponent("bin"), locate: { nil })
        let version = await installer.installedVersion(at: bin.path)
        XCTAssertEqual(version, "2.3.2")
    }

    func testInstalledVersionNilForUnreadableBinary() async throws {
        let bin = tmp.appendingPathComponent("gimme")
        try "not executable".write(to: bin, atomically: true, encoding: .utf8)
        let installer = CLIToolInstaller(http: http, process: ProcessRunner(),
                                         installDir: tmp.appendingPathComponent("bin"), locate: { nil })
        let version = await installer.installedVersion(at: bin.path)
        XCTAssertNil(version)
    }

    // MARK: - install / update / up-to-date

    func testFreshInstallCreatesDirWritesBinary() async throws {
        try await stubLatestRelease(fixtureVersion: "2.4.0")
        let dir = tmp.appendingPathComponent("nested/bin")

        let outcome = try await sut(installDir: dir).installOrUpdate()

        XCTAssertEqual(outcome, .installed(version: "2.4.0"))
        let installed = dir.appendingPathComponent("gimme")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path), "binary written inside the install dir")
        let run = try await ProcessRunner().run(installed.path, args: ["--version"], env: nil, stream: nil)
        XCTAssertEqual(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "gimme 2.4.0")
    }

    func testExistingOlderBinaryIsUpdatedInPlace() async throws {
        try await stubLatestRelease(fixtureVersion: "2.4.0")
        let dir = tmp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = dir.appendingPathComponent("gimme")
        try "#!/bin/sh\necho \"gimme 2.3.0\"\n".write(to: existing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)

        let outcome = try await sut(locate: { existing.path }).installOrUpdate()

        XCTAssertEqual(outcome, .updated(from: "2.3.0", to: "2.4.0"))
        let run = try await ProcessRunner().run(existing.path, args: ["--version"], env: nil, stream: nil)
        XCTAssertEqual(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "gimme 2.4.0", "replaced in place")
    }

    func testUpToDateSkipsDownload() async throws {
        try await stubLatestRelease(fixtureVersion: "2.4.0")
        let existing = tmp.appendingPathComponent("bin/gimme")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Located binary already reports the latest release version.
        try "#!/bin/sh\necho \"gimme 2.4.0\"\n".write(to: existing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)

        let outcome = try await sut(locate: { existing.path }).installOrUpdate()

        XCTAssertEqual(outcome, .upToDate(version: "2.4.0"))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "#!/bin/sh\necho \"gimme 2.4.0\"\n", "binary untouched")
        XCTAssertFalse(process.calls.contains { $0.1.contains("gimme-darwin-arm64.tar.gz") }, "no tarball extracted")
        // Only the release lookup hit the network; no asset download.
        XCTAssertEqual(http.requestCount, 1)
    }

    func testNetworkFailureThrows() async {
        // No release JSON stubbed → latestRelease() returns nil → network error.
        do {
            _ = try await sut().installOrUpdate()
            XCTFail("expected network error")
        } catch let e as GimmeError {
            XCTAssertTrue(e.message.contains("could not check"))
        } catch { XCTFail("expected GimmeError, got \(error)") }
    }

    // MARK: - PATH guidance

    func testIsOnPATH() {
        let home = NSHomeDirectory()
        XCTAssertTrue(CLIToolInstaller.isOnPATH("\(home)/.local/bin",
                                               pathEnv: "/usr/bin:\(home)/.local/bin:/opt/homebrew/bin"))
        XCTAssertFalse(CLIToolInstaller.isOnPATH("\(home)/.local/bin", pathEnv: "/usr/bin:/bin"))
    }
}
