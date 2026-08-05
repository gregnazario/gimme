import XCTest
@testable import GimmeCore

/// In-process CLI tests: drive `Gimme.run` directly against a temp prefix
/// with a local tap + real tarball. Fast, deterministic, no subprocess.
final class CLIIntegrationTests: XCTestCase {
    var tmp: URL!
    var world: World!
    var gimme: Gimme!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            world = try World(prefix: tmp)
            gimme = Gimme(world: world)
            try setUpLocalTap()
        } catch {
            XCTFail("setup failed: \(error)")
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func setUpLocalTap() throws {
        let build = tmp.appendingPathComponent("build")
        let binDir = build.appendingPathComponent("payload").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try "#!/bin/sh\necho tiny".write(to: binDir.appendingPathComponent("tinytool"), atomically: true, encoding: .utf8)
        let archive = tmp.appendingPathComponent("tarballs").appendingPathComponent("tinytool-1.0.0.tar.gz")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["czf", archive.path, "-C", build.path, "payload"]
        try tar.run(); tar.waitUntilExit()
        let sha = Downloader.sha256(of: archive)

        let tapDir = world.paths.taps.appendingPathComponent("core").appendingPathComponent("tinytool")
        try FileManager.default.createDirectory(at: tapDir, withIntermediateDirectories: true)
        let toml = """
        [package]
        name = "tinytool"
        desc = "A tiny test tool"

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

    func run(_ command: Gimme.Command, _ positional: [String], json: Bool = true,
             dryRun: Bool = false, force: Bool = false, all: Bool = false) -> (result: [String: Any], exitCode: Int32) {
        return gimme.run(command: command, options: Gimme.Options(
            json: json, dryRun: dryRun, force: force, all: all, positional: positional))
    }

    // MARK: install

    func testInstallSuccess() throws {
        let (r, code) = run(.install, ["tinytool"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["cmd"] as? String, "install")
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["tool"] as? String, "tinytool")
        XCTAssertEqual(r["version"] as? String, "1.0.0")
        XCTAssertEqual(r["schema_version"] as? Int, 1)
    }

    func testInstallDryRun() throws {
        let (r, code) = run(.install, ["tinytool"], dryRun: true)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["cmd"] as? String, "plan")
        XCTAssertEqual(r["tool"] as? String, "tinytool")
        // Nothing actually installed.
        XCTAssertFalse(world.cellar.hasInstalled("tinytool"))
    }

    func testInstallUnknownTool() {
        let (r, code) = run(.install, ["doesnotexist"])
        XCTAssertEqual(code, 1)
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? String, "NOT_FOUND")
    }

    // MARK: shortcut

    func testShortcutInstallsWhenMissing() throws {
        let (r, code) = run(.shortcut, ["tinytool"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["tool"] as? String, "tinytool")
        XCTAssertTrue(world.cellar.hasInstalled("tinytool"))
    }

    func testShortcutNoopWhenCurrent() throws {
        _ = run(.install, ["tinytool"])
        let (r, code) = run(.shortcut, ["tinytool"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["action"] as? String, "noop")
    }

    func testShortcutNoopWhenPinned() throws {
        _ = run(.install, ["tinytool"])
        try world.state.pin("tinytool", version: "1.0.0")
        let (r, code) = run(.shortcut, ["tinytool"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["action"] as? String, "noop")
        XCTAssertTrue((r["message"] as? String ?? "").contains("pinned"))
    }

    // MARK: list

    func testListEmpty() {
        let (r, code) = run(.list, [])
        XCTAssertEqual(code, 0)
        let tools = r["tools"] as? [[String: Any]] ?? [["dummy": "x"]]
        XCTAssertTrue(tools.isEmpty)
    }

    func testListAfterInstall() throws {
        _ = run(.install, ["tinytool"])
        let (r, _) = run(.list, [])
        let tools = r["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "tinytool")
    }

    func testListAllIncludesNotInstalled() {
        let (r, _) = run(.list, [], all: true)
        // The local tap's tinytool shows even though not installed.
        let tools = r["tools"] as? [[String: Any]] ?? []
        XCTAssertTrue(tools.contains { $0["name"] as? String == "tinytool" })
    }

    // MARK: uninstall

    func testUninstall() throws {
        _ = run(.install, ["tinytool"])
        let (r, code) = run(.uninstall, ["tinytool"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertFalse(world.cellar.hasInstalled("tinytool"))
    }

    // MARK: search / info

    func testSearch() {
        let (r, _) = run(.search, ["tiny"])
        let results = r["results"] as? [[String: Any]] ?? []
        XCTAssertTrue(results.contains { $0["name"] as? String == "tinytool" })
    }

    func testInfo() {
        let (r, code) = run(.info, ["tinytool"])
        XCTAssertEqual(code, 0)
        let f = r["formula"] as? [String: Any]
        XCTAssertEqual(f?["name"] as? String, "tinytool")
        XCTAssertEqual(r["versions"] as? [String], ["1.0.0"])
    }

    // MARK: introspect

    func testIntrospect() {
        let (r, code) = run(.introspect, [])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["cmd"] as? String, "introspect")
        XCTAssertEqual(r["schema_version"] as? Int, 1)
        let cmds = r["commands"] as? [[String: Any]] ?? []
        XCTAssertGreaterThan(cmds.count, 10)
    }

    func testIntrospectScoped() {
        let (r, _) = run(.introspect, ["install"])
        let cmds = r["commands"] as? [[String: Any]] ?? []
        XCTAssertEqual(cmds.count, 1)
    }

    // MARK: pin / unpin

    func testPinUnpin() throws {
        _ = run(.install, ["tinytool"])
        let (pinR, _) = run(.pin, ["tinytool"])
        XCTAssertEqual(pinR["pinned"] as? String, "1.0.0")
        XCTAssertEqual(world.state.loadPinned()["tinytool"], "1.0.0")

        let (unpinR, _) = run(.unpin, ["tinytool"])
        XCTAssertEqual(unpinR["ok"] as? Bool, true)
        XCTAssertNil(world.state.loadPinned()["tinytool"])
    }

    // MARK: use

    func testUse() throws {
        _ = run(.install, ["tinytool"])
        let v2 = world.cellar.prefix(for: "tinytool", version: "2.0.0")
        try FileManager.default.createDirectory(at: v2.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try world.state.recordInstalled("tinytool", version: "2.0.0")

        let (r, code) = run(.use, ["tinytool", "2.0.0"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["active"] as? String, "2.0.0")
    }

    // MARK: doctor

    func testDoctor() {
        let (r, code) = run(.doctor, [])
        XCTAssertEqual(code, 0)
        let checks = r["checks"] as? [[String: Any]] ?? []
        let names = checks.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("writable"))
        XCTAssertTrue(names.contains("receipts"))
    }

    // MARK: config

    func testConfigGet() {
        let (r, code) = run(.config, ["get", "cache.maxAgeHours"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["value"] as? Int, 1)
    }

    func testConfigSet() throws {
        let (r, code) = run(.config, ["set", "cache.maxAgeHours", "5"])
        XCTAssertEqual(code, 0)
        // Re-read config from disk.
        let cfg = Config.loadOrCreate(at: world.paths.configFile)
        XCTAssertEqual(cfg.cache.maxAgeHours, 5)
    }

    // MARK: error rendering

    func testErrorJSONShape() {
        let (r, code) = run(.install, [])
        XCTAssertEqual(code, 1)
        XCTAssertEqual(r["ok"] as? Bool, false)
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? String, "USAGE")
        XCTAssertNotNil(err?["message"])
    }
}
