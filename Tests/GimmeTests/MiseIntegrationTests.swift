import XCTest
@testable import GimmeCore

final class MiseIntegrationTests: XCTestCase {
    var tmp: URL!
    var world: World!
    var integration: MiseIntegration!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            world = try World(prefix: tmp)
            try setUpTinyToolTap()
            integration = MiseIntegration(world: world, cwd: tmp)
        } catch { XCTFail("setup: \(error)") }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// Build a local tap with `tinytool` backed by a real tarball.
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

    func testNoConfigReturnsEmpty() {
        let r = integration.run(dryRun: false)
        XCTAssertTrue(r.outcomes.isEmpty)
        XCTAssertNil(r.source)
    }

    func testInstallsFromToolVersions() throws {
        try "tinytool 1.0.0\nerlang ref:master\n".write(
            to: tmp.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        // No mise/asdf on the spoofed PATH -> tinytool installs.
        let det = MiseDetector(paths: world.paths,
                               environment: ["PATH": "/usr/bin:/bin", "MISE_DATA_DIR": "/nonexistent"])
        integration = MiseIntegration(world: world, detector: det, cwd: tmp)

        let r = integration.run(dryRun: false)
        XCTAssertEqual(r.source, ".tool-versions")
        XCTAssertEqual(r.outcomes.count, 2)
        let tiny = r.outcomes.first { $0.tool == "tinytool" }
        XCTAssertEqual(tiny?.status, .installed)
        XCTAssertEqual(tiny?.version, "1.0.0")
        let erl = r.outcomes.first { $0.tool == "erlang" }
        XCTAssertEqual(erl?.status, .skippedUnsupported)
    }

    func testSkipsMiseManagedTool() throws {
        try "tinytool 1.0.0\n".write(
            to: tmp.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        // Spoof a mise-managed tinytool: put it on PATH under MISE_DATA_DIR/shims.
        let dataDir = tmp.appendingPathComponent("mise-data")
        let shims = dataDir.appendingPathComponent("shims")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        let real = tmp.appendingPathComponent("reals")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "x".write(to: real.appendingPathComponent("tinytool"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.appendingPathComponent("tinytool").path)
        try FileManager.default.createSymbolicLink(
            at: shims.appendingPathComponent("tinytool"),
            withDestinationURL: real.appendingPathComponent("tinytool"))
        let det = MiseDetector(paths: world.paths,
                               environment: ["PATH": "\(shims.path):/usr/bin:/bin",
                                             "MISE_DATA_DIR": dataDir.path])
        integration = MiseIntegration(world: world, detector: det, cwd: tmp)

        let r = integration.run(dryRun: false)
        let tiny = r.outcomes.first { $0.tool == "tinytool" }
        XCTAssertEqual(tiny?.status, .skippedManaged)
        XCTAssertEqual(tiny?.manager, .mise)
        XCTAssertFalse(world.cellar.hasInstalled("tinytool"))
    }

    func testDryRunDoesNotInstall() throws {
        try "tinytool 1.0.0\n".write(
            to: tmp.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        let det = MiseDetector(paths: world.paths,
                               environment: ["PATH": "/usr/bin:/bin", "MISE_DATA_DIR": "/nonexistent"])
        integration = MiseIntegration(world: world, detector: det, cwd: tmp)

        let r = integration.run(dryRun: true)
        let tiny = r.outcomes.first { $0.tool == "tinytool" }
        XCTAssertEqual(tiny?.status, .alreadyCurrent)  // planned, not installed
        XCTAssertFalse(world.cellar.hasInstalled("tinytool"))
    }

    func testFailureBecomesFailedOutcome() throws {
        // Request a tool with no formula in any tap.
        try "nosuchtool 1.0.0\n".write(
            to: tmp.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        let det = MiseDetector(paths: world.paths,
                               environment: ["PATH": "/usr/bin:/bin", "MISE_DATA_DIR": "/nonexistent"])
        integration = MiseIntegration(world: world, detector: det, cwd: tmp)

        let r = integration.run(dryRun: false)
        let outcome = r.outcomes.first { $0.tool == "nosuchtool" }
        XCTAssertEqual(outcome?.status, .failed)
        XCTAssertEqual(outcome?.error?.category, .NOT_FOUND)
        XCTAssertTrue(r.anyFailed)
        XCTAssertFalse(r.ok)  // nothing installed
    }

    func testSummaryCounts() throws {
        try "tinytool 1.0.0\nerlang ref:master\nnosuch 1.0\n".write(
            to: tmp.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        let det = MiseDetector(paths: world.paths,
                               environment: ["PATH": "/usr/bin:/bin", "MISE_DATA_DIR": "/nonexistent"])
        integration = MiseIntegration(world: world, detector: det, cwd: tmp)

        let r = integration.run(dryRun: false)
        let s = r.summary
        XCTAssertEqual(s.installed, 1)  // tinytool
        XCTAssertEqual(s.skipped, 1)    // erlang unsupported
        XCTAssertEqual(s.failed, 1)     // nosuch
    }

    func testJSONShape() throws {
        try "tinytool 1.0.0\n".write(
            to: tmp.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        let det = MiseDetector(paths: world.paths,
                               environment: ["PATH": "/usr/bin:/bin", "MISE_DATA_DIR": "/nonexistent"])
        integration = MiseIntegration(world: world, detector: det, cwd: tmp)
        let r = integration.run(dryRun: false)
        let j = r.toJSON()
        XCTAssertEqual(j["cmd"] as? String, "install-from-mise")
        XCTAssertEqual(j["schema_version"] as? Int, Schema.version)
        XCTAssertEqual(j["source"] as? String, ".tool-versions")
        let tools = j["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["status"] as? String, "installed")
        let summary = j["summary"] as? [String: Int] ?? [:]
        XCTAssertEqual(summary["installed"], 1)
    }

    func testExitCodeMapping() throws {
        try "tinytool 1.0.0\n".write(
            to: tmp.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        let det = MiseDetector(paths: world.paths,
                               environment: ["PATH": "/usr/bin:/bin", "MISE_DATA_DIR": "/nonexistent"])
        integration = MiseIntegration(world: world, detector: det, cwd: tmp)
        let r = integration.run(dryRun: false)
        // ok=true, anyFailed=false -> exit 0.
        XCTAssertTrue(r.ok)
        XCTAssertFalse(r.anyFailed)
    }
}
