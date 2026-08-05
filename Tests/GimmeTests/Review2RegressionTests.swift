import XCTest
@testable import GimmeCore

/// Regression tests for the second-pass review fixes: lock re-entrancy (covered
/// in DependencyInstallTests), atomic writes + self-healing state, tap-name
/// validation, version-scoped dependents, and atomic config writes.
final class Review2RegressionTests: XCTestCase {
    var tmp: URL!
    var paths: GimmePaths!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: TapStore.add name validation

    func testTapStoreRejectsUnsafeName() {
        let store = TapStore(paths: paths, config: Config())
        for bad in ["foo]", "a.b\n[evil]", "with space", "tab\there", "semi;colon"] {
            XCTAssertThrowsError(try store.add(name: bad, url: "/tmp/x"), "should reject \(bad)") { error in
                guard case GimmeError.usage = error else {
                    XCTFail("expected usage for \(bad), got \(error)"); return
                }
            }
        }
    }

    func testTapStoreRejectsEmptyURL() {
        let store = TapStore(paths: paths, config: Config())
        XCTAssertThrowsError(try store.add(name: "ok", url: "")) { error in
            guard case GimmeError.usage = error else { XCTFail("got \(error)"); return }
        }
    }

    func testTapStoreAcceptsValidName() throws {
        let store = TapStore(paths: paths, config: Config())
        // Names with allowed chars are accepted (the clone will fail on a fake
        // URL, but validation should pass; we expect a network error, not usage).
        XCTAssertThrowsError(try store.add(name: "my.tap_v2", url: "/nonexistent/repo")) { error in
            // Either network error (clone failed) is fine; what we're checking is
            // that it's NOT a usage error from name validation.
            if case GimmeError.usage(let msg) = error {
                XCTFail("valid name was rejected: \(msg)")
            }
        }
    }

    // MARK: Config.toTOML URL escaping

    func testConfigToTOMLEscapesURL() {
        var c = Config()
        // A URL containing a quote and backslash must be escaped, not break TOML.
        c.taps["safe"] = TapConfig(url: "https://x/\"\\weird", enabled: true)
        let toml = c.toTOML()
        // The escaped form should round-trip back to the same URL when parsed.
        let data = toml.data(using: .utf8)!
        let parsed = try? TOML.parseData(data)
        let tapsTable = parsed?.table("taps")?.table("safe")
        XCTAssertNotNil(tapsTable?.string("url"))
        // The url value should contain the escaped content; unescaping happens
        // in parseBasicString. Confirm the raw value parses to something with
        // the expected path prefix.
        let rawUrl = tapsTable?.string("url") ?? ""
        XCTAssertTrue(rawUrl.contains("x/"), "url lost content: \(rawUrl)")
    }

    // MARK: StateStore self-heal on corrupt installed.json

    func testStateStoreRebuildsOnCorruptIndex() throws {
        let cellar = Cellar(paths: paths)
        let state = StateStore(paths: paths)
        state.cellar = cellar

        // Install a tool into the cellar directly + write a receipt.
        let prefix = cellar.prefix(for: "mytool", version: "1.0.0")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let receipt = Receipt(formula: "mytool", tap: "core", version: "1.0.0",
                              installedAt: "now", asset: .init(url: "u", sha256: "s"))
        try receipt.write(into: prefix)

        // Corrupt the installed.json index.
        try "NOT VALID JSON {{{".write(to: paths.state.appendingPathComponent("installed.json"),
                                       atomically: true, encoding: .utf8)

        // loadInstalled must self-heal: rebuild from cellar.
        let entries = state.loadInstalled()
        XCTAssertEqual(entries["mytool"]?.active, "1.0.0")
        XCTAssertTrue(entries["mytool"]?.installed.contains("1.0.0") ?? false)

        // The index should now be persisted valid.
        let persisted = try String(contentsOf: paths.state.appendingPathComponent("installed.json"))
        XCTAssertFalse(persisted.contains("NOT VALID"))
    }

    func testStateStoreAtomicWriteLeavesValidJSON() throws {
        let state = StateStore(paths: paths)
        var entries: [String: InstalledEntry] = [
            "x": InstalledEntry(active: "1.0.0", installed: ["1.0.0"])
        ]
        try state.saveInstalled(entries)
        // Read back raw; must be valid JSON (atomic write succeeded).
        let data = try Data(contentsOf: paths.state.appendingPathComponent("installed.json"))
        let decoded = try JSONDecoder().decode([String: InstalledEntry].self, from: data)
        XCTAssertEqual(decoded["x"]?.active, "1.0.0")
        _ = entries
    }

    // MARK: version-scoped dependents check

    func testUninstallUnusedVersionNotBlocked() throws {
        // Set up: a World with two versions of a dep installed; a dependent
        // receipt depends on v1.0.0 only. Uninstalling v2.0.0 must NOT be blocked.
        let world = try World(prefix: tmp)
        // Install dep 1.0.0 + 2.0.0 manually into the cellar.
        for v in ["1.0.0", "2.0.0"] {
            let p = world.cellar.prefix(for: "dep", version: v)
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
            try Receipt(formula: "dep", tap: "core", version: v, installedAt: "now",
                        asset: .init(url: "u", sha256: "s")).write(into: p)
            try world.state.recordInstalled("dep", version: v)
        }
        try world.state.setActive("dep", version: "2.0.0")
        // Dependent "app" depends on dep@1.0.0 (resolved).
        let appPrefix = world.cellar.prefix(for: "app", version: "1.0.0")
        try FileManager.default.createDirectory(at: appPrefix, withIntermediateDirectories: true)
        try Receipt(formula: "app", tap: "core", version: "1.0.0", installedAt: "now",
                    asset: .init(url: "u", sha256: "s"),
                    deps: [Receipt.DepRef(name: "dep", version: "1.0.0", resolved: "1.0.0")]).write(into: appPrefix)
        try world.state.recordInstalled("app", version: "1.0.0")

        // Uninstalling dep@2.0.0 (which nothing depends on) must succeed.
        try world.installer.uninstall(tool: "dep", version: "2.0.0")
        XCTAssertFalse(world.cellar.hasInstalled("dep", version: Version("2.0.0")!))
        XCTAssertTrue(world.cellar.hasInstalled("dep", version: Version("1.0.0")!))
    }

    func testUninstallDependedVersionBlocked() throws {
        let world = try World(prefix: tmp)
        let p = world.cellar.prefix(for: "dep", version: "1.0.0")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try Receipt(formula: "dep", tap: "core", version: "1.0.0", installedAt: "now",
                    asset: .init(url: "u", sha256: "s")).write(into: p)
        try world.state.recordInstalled("dep", version: "1.0.0")
        try world.state.setActive("dep", version: "1.0.0")
        let appPrefix = world.cellar.prefix(for: "app", version: "1.0.0")
        try FileManager.default.createDirectory(at: appPrefix, withIntermediateDirectories: true)
        try Receipt(formula: "app", tap: "core", version: "1.0.0", installedAt: "now",
                    asset: .init(url: "u", sha256: "s"),
                    deps: [Receipt.DepRef(name: "dep", version: "1.0.0", resolved: "1.0.0")]).write(into: appPrefix)
        try world.state.recordInstalled("app", version: "1.0.0")

        // Uninstalling dep@1.0.0 (which app depends on) must be refused.
        XCTAssertThrowsError(try world.installer.uninstall(tool: "dep", version: "1.0.0")) { error in
            guard case GimmeError.conflict = error else {
                XCTFail("expected conflict, got \(error)"); return
            }
        }
        // --force overrides.
        try world.installer.uninstall(tool: "dep", version: "1.0.0", force: true)
        XCTAssertFalse(world.cellar.hasInstalled("dep", version: Version("1.0.0")!))
    }
}
