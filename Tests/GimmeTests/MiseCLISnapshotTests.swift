import XCTest
@testable import GimmeCore

/// In-process CLI tests for mise interop via Gimme.run, against a temp prefix
/// + a local tap + a `.tool-versions` in a temp cwd.
final class MiseCLISnapshotTests: XCTestCase {
    var tmp: URL!
    var world: World!
    var gimme: Gimme!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            world = try World(prefix: tmp)
            gimme = Gimme(world: world)
            try setUpTinyToolTap()
        } catch { XCTFail("setup: \(error)") }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func setUpTinyToolTap() throws {
        let build = tmp.appendingPathComponent("build")
        let binDir = build.appendingPathComponent("payload").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try "#!/bin/sh\necho hi".write(to: binDir.appendingPathComponent("tinytool"), atomically: true, encoding: .utf8)
        let archive = tmp.appendingPathComponent("tarballs").appendingPathComponent("tinytool-1.0.0.tar.gz")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        t.arguments = ["czf", archive.path, "-C", build.path, "payload"]
        try t.run(); t.waitUntilExit()
        let sha = Downloader.sha256(of: archive)
        let tapDir = world.paths.taps.appendingPathComponent("core").appendingPathComponent("tinytool")
        try FileManager.default.createDirectory(at: tapDir, withIntermediateDirectories: true)
        let toml = """
        [package]
        name = "tinytool"
        [[version]]
        ver = "1.0.0"
        [[version.asset]]
        os = "macos"
        arch = "arm64"
        url = "\(URL(fileURLWithPath: archive.path).absoluteString)"
        sha256 = "\(sha)"
        [install]
        strategy = "steps"
        [[install.step]]
        extract = "${asset}"
        [[install.step]]
        copy = { from = "payload/bin", to = "${prefix}/bin" }
        [[provides]]
        bin = ["tinytool"]
        [livecheck]
        strategy = "none"
        """
        try toml.write(to: tapDir.appendingPathComponent("formula.toml"), atomically: true, encoding: .utf8)
    }

    /// gimme.run helper with a controlled cwd + mise-free env.
    private func runInstall(cwd: URL, positional: [String], fromMise: Bool = false,
                            noMise: Bool = false, dryRun: Bool = false) -> (result: [String: Any], exitCode: Int32) {
        return gimme.run(command: .install, options: Gimme.Options(
            json: true, dryRun: dryRun, positional: positional,
            fromMise: fromMise, noMise: noMise, cwd: cwd))
    }

    func testAutoDetectInstallsFromToolVersions() throws {
        let project = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "tinytool 1.0.0\n".write(to: project.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)

        let (r, code) = runInstall(cwd: project, positional: [])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["cmd"] as? String, "install-from-mise")
        let tools = r["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["tool"] as? String, "tinytool")
        XCTAssertEqual(tools[0]["status"] as? String, "installed")
    }

    func testNoMiseOptsOutOfAutoDetect() throws {
        let project = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "tinytool 1.0.0\n".write(to: project.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)

        let (r, code) = runInstall(cwd: project, positional: [], noMise: true)
        // No positional + noMise -> usage error (no single-install path).
        XCTAssertEqual(code, 1)
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? String, "USAGE")
    }

    func testPositionalArgBypassesConfig() throws {
        let project = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "tinytool 1.0.0\n".write(to: project.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)

        // Explicit positional install -> single-install path, not batch.
        let (r, code) = runInstall(cwd: project, positional: ["tinytool"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["cmd"] as? String, "install")
    }

    func testFromMiseForcesBatchEvenWithPositional() throws {
        let project = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "tinytool 1.0.0\n".write(to: project.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)

        // --from-mise forces batch mode even though a positional is present.
        let (r, code) = runInstall(cwd: project, positional: ["ignored"], fromMise: true)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["cmd"] as? String, "install-from-mise")
    }

    func testNoConfigNoArgsFallsToUsage() throws {
        let project = tmp.appendingPathComponent("proj-empty")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // No `.tool-versions`, no positional -> usage error.
        let (r, code) = runInstall(cwd: project, positional: [])
        XCTAssertEqual(code, 1)
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? String, "USAGE")
    }

    func testFromMiseWithNoConfigStillErrorsCleanly() throws {
        let project = tmp.appendingPathComponent("proj-empty2")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // --from-mise but no config -> empty batch with ok=false (nothing installed).
        let (r, code) = runInstall(cwd: project, positional: [], fromMise: true)
        // Empty batch: ok is false (no installed), anyFailed false -> exit 1 by spec
        // ("ok false only if every tool failed" — empty has none installed).
        XCTAssertEqual(code, 1)
    }

    func testDryRunPlansBatch() throws {
        let project = tmp.appendingPathComponent("proj-dry")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "tinytool 1.0.0\n".write(to: project.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)

        let (r, code) = runInstall(cwd: project, positional: [], dryRun: true)
        XCTAssertEqual(code, 0)
        let tools = r["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["status"] as? String, "already_current")
        XCTAssertFalse(world.cellar.hasInstalled("tinytool"))
    }
}
