import XCTest
@testable import GimmeCore

/// Additional edge-case tests covering Gimme.swift dispatch branches and
/// Installer dependents-check / error paths that aren't exercised elsewhere.
final class ExtraCoverageTests: XCTestCase {
    var tmp: URL!
    var world: World!
    var gimme: Gimme!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            world = try World(prefix: tmp)
            gimme = Gimme(world: world)
            try setUpTinyTool()
        } catch { XCTFail("setup: \(error)") }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func setUpTinyTool() throws {
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
        let dir = world.paths.taps.appendingPathComponent("core").appendingPathComponent("tinytool")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        try toml.write(to: dir.appendingPathComponent("formula.toml"), atomically: true, encoding: .utf8)
    }

    private func run(_ c: Gimme.Command, _ pos: [String], force: Bool = false, all: Bool = false,
                     check: Bool = false, dryRun: Bool = false) -> (result: [String: Any], exitCode: Int32) {
        return gimme.run(command: c, options: Gimme.Options(
            json: true, dryRun: dryRun, force: force, all: all, check: check, positional: pos))
    }

    // MARK: Gimme dispatch errors

    func testUpdateRequiresArgOrAll() {
        let (_, code) = run(.update, [])
        XCTAssertEqual(code, 1)  // usage
    }

    func testUpdateAllWithNoTools() {
        let (r, code) = run(.update, [], all: true)
        XCTAssertEqual(code, 0)
        XCTAssertEqual((r["updated"] as? [Any])?.count, 0)
    }

    func testUpdateCheckCallsOutdated() {
        let (r, code) = run(.update, ["tinytool"], check: true)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["cmd"] as? String, "outdated")
    }

    func testUpdateSpecificTool() {
        let (r, code) = run(.update, ["tinytool"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(r["cmd"] as? String, "update")
    }

    func testUninstallMissing() {
        let (_, code) = run(.uninstall, ["nope"])
        XCTAssertEqual(code, 1)  // not_found
    }

    func testUseRequiresBothArgs() {
        let (_, code) = run(.use, ["tinytool"])
        XCTAssertEqual(code, 1)
    }

    func testUseUnknownVersion() {
        _ = run(.install, ["tinytool"])
        let (_, code) = run(.use, ["tinytool", "9.9.9"])
        XCTAssertEqual(code, 1)  // not_found
    }

    func testPinMissing() {
        let (_, code) = run(.pin, ["nope"])
        XCTAssertEqual(code, 1)
    }

    func testUnpinNoArg() {
        let (_, code) = run(.unpin, [])
        XCTAssertEqual(code, 1)
    }

    func testSearchNoArg() {
        let (_, code) = run(.search, [])
        XCTAssertEqual(code, 1)
    }

    func testInfoNoArg() {
        let (_, code) = run(.info, [])
        XCTAssertEqual(code, 1)
    }

    func testTapList() {
        let (r, code) = run(.tap, ["list"])
        XCTAssertEqual(code, 0)
        XCTAssertNotNil(r["taps"])
    }

    func testTapUnknownAction() {
        let (_, code) = run(.tap, ["weird"])
        XCTAssertEqual(code, 1)
    }

    func testConfigUnknownAction() {
        let (_, code) = run(.config, ["weird", "k"])
        XCTAssertEqual(code, 1)
    }

    func testConfigSetUnknownKey() {
        let (_, code) = run(.config, ["set", "unknown.key", "v"])
        XCTAssertEqual(code, 1)
    }

    func testConfigGetNoKeyReturnsAll() {
        let (r, code) = run(.config, ["get"])
        XCTAssertEqual(code, 0)
        XCTAssertNotNil(r["value"])
    }

    // MARK: Shortcut messages

    func testShortcutCurrentMessage() {
        _ = run(.install, ["tinytool"])
        let (r, _) = run(.shortcut, ["tinytool"])
        XCTAssertEqual(r["action"] as? String, "noop")
        XCTAssertTrue((r["message"] as? String ?? "").contains("current"))
    }

    // MARK: List filtering

    func testListQueryFilter() {
        _ = run(.install, ["tinytool"])
        let (r, _) = run(.list, [], all: false)
        let tools = r["tools"] as? [[String: Any]] ?? []
        XCTAssertTrue(tools.contains { ($0["name"] as? String) == "tinytool" })
    }

    func testListLimit() {
        _ = run(.install, ["tinytool"])
        let (r, _) = gimme.run(command: .list, options: Gimme.Options(
            json: true, limit: 0, positional: []))
        let tools = r["tools"] as? [[String: Any]] ?? []
        XCTAssertTrue(tools.count <= 0 || tools.isEmpty)
    }

    // MARK: Doctor failure path

    func testDoctorReportsPath() {
        let (r, _) = run(.doctor, [])
        let checks = r["checks"] as? [[String: Any]] ?? []
        let pathCheck = checks.first { $0["name"] as? String == "path" }
        XCTAssertNotNil(pathCheck)
    }

    // MARK: Installer dependents check + force

    func testUninstallRefusedWhenDependedOn() throws {
        // Manually create a receipt claiming "parent" depends on tinytool.
        _ = run(.install, ["tinytool"])
        let parentPrefix = world.cellar.prefix(for: "parent", version: "1.0.0")
        try FileManager.default.createDirectory(at: parentPrefix, withIntermediateDirectories: true)
        let receipt = Receipt(
            formula: "parent", tap: "core", version: "1.0.0", installedAt: "now",
            asset: .init(url: "u", sha256: "s"),
            deps: [Receipt.DepRef(name: "tinytool", version: "1.0.0", resolved: "1.0.0")])
        try receipt.write(into: parentPrefix)
        try world.state.recordInstalled("parent", version: "1.0.0")

        // Refuse without --force.
        let (_, refusedCode) = run(.uninstall, ["tinytool"])
        XCTAssertEqual(refusedCode, 3)  // conflict

        // --force removes it.
        let (_, forcedCode) = run(.uninstall, ["tinytool"], force: true)
        XCTAssertEqual(forcedCode, 0)
    }

    // MARK: Tap add/remove via in-process

    func testTapAddRemove() throws {
        // Build a minimal git repo, then add/remove it as a tap.
        let repo = tmp.appendingPathComponent("myrepo")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("Formula").appendingPathComponent("bar"), withIntermediateDirectories: true)
        try """
        [package]
        name = "bar"
        [[version]]
        ver = "1.0.0"
        [[version.asset]]
        url = "https://e/x.tar.gz"
        sha256 = "abc"
        """.write(to: repo.appendingPathComponent("Formula").appendingPathComponent("bar").appendingPathComponent("formula.toml"), atomically: true, encoding: .utf8)
        for args in [["init","-q"], ["add","-A"], ["commit","-q","-m","x"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.currentDirectoryURL = repo; p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(
                ["GIT_AUTHOR_NAME":"t","GIT_AUTHOR_EMAIL":"t@x","GIT_COMMITTER_NAME":"t","GIT_COMMITTER_EMAIL":"t@x"],
                uniquingKeysWith: {_,b in b})
            try p.run(); p.waitUntilExit()
        }
        let (addR, addCode) = run(.tap, ["add", "my", repo.path])
        XCTAssertEqual(addCode, 0)
        XCTAssertEqual(addR["added"] as? String, "my")

        let (rmR, rmCode) = run(.tap, ["remove", "my"])
        XCTAssertEqual(rmCode, 0)
        XCTAssertEqual(rmR["removed"] as? String, "my")
    }
}
