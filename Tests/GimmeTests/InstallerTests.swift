import XCTest
@testable import GimmeCore

/// Builds a self-contained install scenario: a temp prefix, a local tap with
/// a "tinytool" formula whose asset is a real local tarball, then runs the
/// full Installer pipeline against it.
final class InstallerTests: XCTestCase {
    var tmp: URL!
    var paths: GimmePaths!
    var config: Config!
    var tapStore: TapStore!
    var downloader: Downloader!
    var stager: Stager!
    var cellar: Cellar!
    var shims: ShimManager!
    var state: StateStore!
    var lock: Lock!
    var installer: Installer!
    let host = Host(os: "macos", arch: "arm64", macosVersion: "14.0")

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        config = Config()
        tapStore = TapStore(paths: paths, config: config)
        downloader = Downloader(paths: paths)
        stager = Stager(paths: paths, host: host)
        cellar = Cellar(paths: paths)
        shims = ShimManager(paths: paths)
        state = StateStore(paths: paths)
        lock = Lock(paths: paths)
        installer = Installer(paths: paths, host: host, tapStore: tapStore,
                              downloader: downloader, stager: stager, cellar: cellar,
                              shims: shims, state: state, lock: lock)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// Create a local tap with a `tinytool` formula backed by a real tarball.
    private func setUpTinyToolTap(strategy: Strategy = .steps) throws {
        // 1. Build the tarball: payload/bin/tinytool
        let build = tmp.appendingPathComponent("build")
        let binDir = build.appendingPathComponent("payload").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try "#!/bin/sh\necho tiny".write(to: binDir.appendingPathComponent("tinytool"), atomically: true, encoding: .utf8)
        let archive = tmp.appendingPathComponent("tarballs").appendingPathComponent("tinytool-1.0.0.tar.gz")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tarTask = Process()
        tarTask.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarTask.arguments = ["czf", archive.path, "-C", build.path, "payload"]
        try tarTask.run(); tarTask.waitUntilExit()

        let sha = Downloader.sha256(of: archive)

        // 2. Create the tap dir + formula.toml.
        let tapDir = paths.taps.appendingPathComponent("core").appendingPathComponent("tinytool")
        try FileManager.default.createDirectory(at: tapDir, withIntermediateDirectories: true)

        let toml: String
        if strategy == .steps {
            toml = """
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
        } else {
            // lua strategy: copy the hello install.lua approach
            toml = """
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
            strategy = "lua"
            script = "install.lua"

            [[provides]]
            bin = ["tinytool"]

            [livecheck]
            strategy = "none"
            """
            let lua = """
            function install(ctx)
              local asset = ctx:download()
              local dir = ctx:extract(asset)
              ctx:install_dir(dir .. "/payload")
              ctx:set_provides({"tinytool"})
            end
            """
            try lua.write(to: tapDir.appendingPathComponent("install.lua"), atomically: true, encoding: .utf8)
        }
        try toml.write(to: tapDir.appendingPathComponent("formula.toml"), atomically: true, encoding: .utf8)
    }

    func testPlanDryRun() throws {
        try setUpTinyToolTap()
        let plan = try installer.plan(query: "tinytool")
        XCTAssertEqual(plan.tool, "tinytool")
        XCTAssertEqual(plan.version, "1.0.0")
        XCTAssertFalse(plan.sha256.isEmpty)
        XCTAssertEqual(plan.provides, ["tinytool"])
        XCTAssertTrue(plan.cellarPrefix.hasSuffix("cellar/tinytool/1.0.0"))
        XCTAssertEqual(plan.shim.hasSuffix("bin/tinytool"), true)
    }

    func testFullInstallStepsStrategy() throws {
        try setUpTinyToolTap(strategy: .steps)
        let result = try installer.install(query: "tinytool")
        XCTAssertEqual(result.tool, "tinytool")
        XCTAssertEqual(result.version, "1.0.0")

        // Cellar has the prefix with bin/tinytool.
        let prefix = cellar.prefix(for: "tinytool", version: "1.0.0")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefix.appendingPathComponent("bin").appendingPathComponent("tinytool").path))

        // Receipt exists.
        XCTAssertNotNil(cellar.receipt(for: "tinytool", version: "1.0.0"))

        // Shim exists + executable.
        let shim = shims.shimPath(for: "tinytool")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shim.path))

        // State records it.
        let installed = state.loadInstalled()
        XCTAssertEqual(installed["tinytool"]?.active, "1.0.0")
        XCTAssertTrue(installed["tinytool"]?.installed.contains("1.0.0") ?? false)
    }

    func testFullInstallLuaStrategy() throws {
        try setUpTinyToolTap(strategy: .lua)
        let result = try installer.install(query: "tinytool")
        XCTAssertEqual(result.tool, "tinytool")
        let prefix = cellar.prefix(for: "tinytool", version: "1.0.0")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefix.appendingPathComponent("bin").appendingPathComponent("tinytool").path))
    }

    func testAtomicityOnBadChecksum() throws {
        try setUpTinyToolTap()
        // Tamper: rewrite formula.toml with a wrong sha; install must throw and
        // leave the cellar/state untouched.
        let tapDir = paths.taps.appendingPathComponent("core").appendingPathComponent("tinytool")
        let toml = try String(contentsOf: tapDir.appendingPathComponent("formula.toml"))
        let tampered = toml.replacingOccurrences(of: "sha256 = \"\(findSha(in: toml))\"",
                                                  with: "sha256 = \"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\"")
        try tampered.write(to: tapDir.appendingPathComponent("formula.toml"), atomically: true, encoding: .utf8)

        // With brew delegation enabled, a bad checksum falls back to brew install.
        // tinytool doesn't exist in brew, so we get an install error.
        XCTAssertThrowsError(try installer.install(query: "tinytool")) { error in
            // Should be an install error (brew failed) or checksum mismatch
            // (if brew isn't available in CI).
            guard case GimmeError.install = error else {
                XCTFail("expected install error from brew delegation, got \(error)"); return
            }
        }
        // Cellar should be empty for tinytool.
        XCTAssertFalse(cellar.hasInstalled("tinytool"))
        XCTAssertTrue(state.loadInstalled()["tinytool"] == nil)
    }

    func testUninstall() throws {
        try setUpTinyToolTap()
        _ = try installer.install(query: "tinytool")
        try installer.uninstall(tool: "tinytool")
        XCTAssertFalse(cellar.hasInstalled("tinytool"))
        XCTAssertNil(state.loadInstalled()["tinytool"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: shims.shimPath(for: "tinytool").path))
    }

    func testSwitchActive() throws {
        try setUpTinyToolTap()
        // Install 1.0.0.
        _ = try installer.install(query: "tinytool")
        // Manually add a second version dir to the cellar so we can switch.
        let v2 = cellar.prefix(for: "tinytool", version: "2.0.0")
        try FileManager.default.createDirectory(at: v2.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try "x".write(to: v2.appendingPathComponent("bin").appendingPathComponent("tinytool"), atomically: true, encoding: .utf8)
        try state.recordInstalled("tinytool", version: "2.0.0")

        try installer.switchActive(tool: "tinytool", version: "2.0.0")
        XCTAssertEqual(state.loadInstalled()["tinytool"]?.active, "2.0.0")
        let shimContent = try String(contentsOf: shims.shimPath(for: "tinytool"))
        XCTAssertTrue(shimContent.contains("2.0.0"))
    }

    private func findSha(in toml: String) -> String {
        guard let range = toml.range(of: "sha256 = \"") else { return "" }
        let after = toml[range.upperBound...]
        if let end = after.firstIndex(of: "\"") {
            return String(after[..<end])
        }
        return ""
    }
}
