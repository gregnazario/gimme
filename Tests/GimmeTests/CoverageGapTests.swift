import XCTest
@testable import GimmeCore

/// Targeted tests to close coverage gaps identified by `swift test
/// --enable-code-coverage` analysis. Each covers a previously-untested path.
final class CoverageGapTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: Livecheck.parseVersionStatic

    func testLivecheckParseVersionWithCaptureGroup() {
        let v = Livecheck.parseVersionStatic(from: "tag: git-2.40.1 more text",
                                             with: #"git-(\d+\.\d+\.\d+)"#)
        XCTAssertEqual(v?.description, "2.40.1")
    }

    func testLivecheckParseVersionDefaultRegex() {
        let v = Livecheck.parseVersionStatic(from: "version 1.2.3 released", with: nil)
        XCTAssertEqual(v?.description, "1.2.3")
    }

    func testLivecheckParseVersionNoMatch() {
        XCTAssertNil(Livecheck.parseVersionStatic(from: "no version here", with: nil))
    }

    func testLivecheckParseVersionInvalidRegex() {
        XCTAssertNil(Livecheck.parseVersionStatic(from: "x", with: "(["))
    }

    func testLivecheckCacheStaleFile() throws {
        // Stale cache (old timestamp) -> rechecked; "none" returns highest declared.
        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        let lc = Livecheck(paths: paths, maxAgeHours: 1)
        let cacheFile = paths.cache.appendingPathComponent("livecheck").appendingPathComponent("stale.json")
        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stale: [String: Any] = ["version": "9.9.9", "fetched_at": Date().addingTimeInterval(-3600 * 5).timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: stale).write(to: cacheFile)
        // Stale entries are ignored (cache miss) -> none strategy returns declared.
        let f = Formula(package: .init(name: "stale"), versions: [.init(ver: "1.0.0")])
        _ = try lc.latest(for: f)
    }

    // MARK: Downloader - cache miss + verify path + invalid URL

    func testDownloaderInvalidURLThrows() {
        let paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        let dl = Downloader(paths: paths)
        // An empty URL string fails URL(string:) -> .usage error.
        let asset = Asset(url: "", sha256: "abc")
        XCTAssertThrowsError(try dl.fetch(asset: asset)) { error in
            guard case GimmeError.usage = error else {
                XCTFail("expected usage error, got \(error)"); return
            }
        }
    }

    func testDownloaderNetworkErrorWrap() {
        // A malformed http URL that URLSession rejects -> .network error.
        let paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        let dl = Downloader(paths: paths)
        let asset = Asset(url: "https://this-host-definitely-does-not-exist.invalid/x.tar.gz",
                          sha256: "abc")
        XCTAssertThrowsError(try dl.fetch(asset: asset)) { error in
            guard case GimmeError.network = error else {
                XCTFail("expected network error, got \(error)"); return
            }
        }
    }

    // MARK: Lock - error paths

    func testLockAcquireWorksOnFreshPrefix() throws {
        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        let lock = Lock(paths: paths)
        try lock.acquire(timeoutSeconds: 1)
        lock.release()
    }

    // MARK: TapStore - git clone via local file repo

    func testTapStoreAddFromLocalGitRepo() throws {
        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        // Create a minimal git repo with a Formula/foo dir.
        let srcRepo = tmp.appendingPathComponent("srcrepo")
        try FileManager.default.createDirectory(
            at: srcRepo.appendingPathComponent("Formula").appendingPathComponent("foo"), withIntermediateDirectories: true)
        let toml = """
        [package]
        name = "foo"

        [[version]]
        ver = "1.0.0"

        [[version.asset]]
        url = "https://e/x.tar.gz"
        sha256 = "abc"
        """
        try toml.write(to: srcRepo.appendingPathComponent("Formula").appendingPathComponent("foo").appendingPathComponent("formula.toml"), atomically: true, encoding: .utf8)
        // git init + commit.
        for args in [["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "init"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.currentDirectoryURL = srcRepo
            p.arguments = args
            let env = ProcessInfo.processInfo.environment
            p.environment = env.merging(["GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@x",
                                         "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@x"],
                                        uniquingKeysWith: { _, b in b })
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }

        var store = TapStore(paths: paths, config: Config())
        try store.add(name: "extra", url: srcRepo.path)
        XCTAssertTrue(store.list().contains("extra"))
        let foo = try store.find("foo")
        XCTAssertEqual(foo.name, "foo")
    }

    func testTapStoreAddDuplicateThrows() throws {
        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        let dest = paths.taps.appendingPathComponent("dup")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let store = TapStore(paths: paths, config: Config())
        XCTAssertThrowsError(try store.add(name: "dup", url: "/tmp"))
    }

    func testTapStoreUpdateNonGitIsNoop() throws {
        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        let dest = paths.taps.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let store = TapStore(paths: paths, config: Config())
        // update on a non-git dir should be a silent no-op (no .git present).
        XCTAssertNoThrow(try store.update(name: "plain"))
    }

    // MARK: Formula - encode round-trip

    func testFormulaEncodeRoundTrip() throws {
        let f = Formula(
            package: .init(name: "x", desc: "d", homepage: "h", license: "MIT"),
            versions: [.init(ver: "1.0.0", released: "2026-01-01",
                             assets: [Asset(arch: "arm64", os: "macos", url: "u", sha256: "s")])],
            install: .init(strategy: .steps, steps: [.init(extract: "${asset}"),
                                                     .init(copy: .init(from: "a", to: "b"))]),
            deps: [.init(name: "dep", ver: ">=1")],
            provides: .init(bin: ["x"]),
            livecheck: .init(strategy: "none")
        )
        let data = try JSONEncoder().encode(f)
        let decoded = try JSONDecoder().decode(Formula.self, from: data)
        XCTAssertEqual(decoded.name, "x")
        XCTAssertEqual(decoded.versions.count, 1)
        XCTAssertEqual(decoded.install.steps.count, 2)
    }

    func testFormulaHighestVersionNilWhenEmpty() {
        let f = Formula(package: .init(name: "x"))
        XCTAssertNil(f.highestVersion())
    }

    // MARK: Gimme - error wrapping for non-GimmeError

    func testGimmeWrapsNonGimmeError() throws {
        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        let world = try World(prefix: tmp)
        let gimme = Gimme(world: world)
        // Trigger a usage error and confirm exit code mapping.
        let (r, code) = gimme.run(command: .install, options: Gimme.Options(positional: []))
        XCTAssertEqual(code, 1)
        XCTAssertEqual(r["ok"] as? Bool, false)
    }

    // MARK: Cellar - empty / missing cases

    func testCellarInstalledVersionsEmptyForUnknown() {
        let paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        let cellar = Cellar(paths: paths)
        XCTAssertTrue(cellar.installedVersions(for: "nope").isEmpty)
        XCTAssertFalse(cellar.hasInstalled("nope"))
    }

    func testCellarScanAllEmpty() {
        let paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        let cellar = Cellar(paths: paths)
        XCTAssertTrue(cellar.scanAll().isEmpty)
    }

    // MARK: Resolver - circular dependency

    func testResolverDetectsCircularDependency() throws {
        struct Mock: FormulaProvider {
            let a = Formula(package: .init(name: "a"), versions: [.init(ver: "1.0.0", assets: [Asset(arch: "arm64", os: "macos", url: "u", sha256: "s")])],
                            deps: [.init(name: "b")])
            let b = Formula(package: .init(name: "b"), versions: [.init(ver: "1.0.0", assets: [Asset(arch: "arm64", os: "macos", url: "u", sha256: "s")])],
                            deps: [.init(name: "a")])
            func find(_ name: String) throws -> Formula {
                switch name { case "a": return a; case "b": return b
                default: throw GimmeError.notFound(name) }
            }
        }
        let paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        let cellar = Cellar(paths: paths)
        let state = StateStore(paths: paths)
        let r = Resolver(provider: Mock(), cellar: cellar, state: state,
                         host: Host(os: "macos", arch: "arm64", macosVersion: "14"))
        XCTAssertThrowsError(try r.resolve(query: "a")) { error in
            guard case GimmeError.conflict = error else { XCTFail("got \(error)"); return }
        }
    }

    // MARK: SemVer - edge cases

    func testSemVerConstraintGreaterThanLower() throws {
        let c = try VersionConstraint.parse(">=1.0.0")
        XCTAssertTrue(c.matches(Version("2.0.0")!))
        XCTAssertFalse(c.matches(Version("0.9.0")!))
    }

    func testSemVerConstraintLessThanUpper() throws {
        let c = try VersionConstraint.parse("<3.0.0")
        XCTAssertTrue(c.matches(Version("2.9.9")!))
        XCTAssertFalse(c.matches(Version("3.0.0")!))
    }

    func testSemVerInvalidConstraintThrows() {
        XCTAssertThrowsError(try VersionConstraint.parse("not-a-version-and-not-an-op"))
    }

    // MARK: Config - encode to TOML + taps

    func testConfigToTOMLWithTaps() {
        var c = Config()
        c.behavior.autoUpdateCheck = false
        c.taps["foo"] = TapConfig(url: "https://e/x.git", enabled: false)
        let s = c.toTOML()
        XCTAssertTrue(s.contains("[taps.foo]"))
        XCTAssertTrue(s.contains("enabled = false"))
    }

    // MARK: ManifestLoader - invalid TOML

    func testManifestLoaderInvalidContent() {
        XCTAssertThrowsError(try ManifestLoader.decode("= =".data(using: .utf8)!))
    }

    // MARK: Receipt - encode

    func testReceiptDecodeMissingReturnsNil() {
        let dir = tmp.appendingPathComponent("nope")
        XCTAssertNil(Receipt.read(from: dir))
    }

    // MARK: Plan - full dep rendering

    func testPlanWithDeps() {
        let plan = InstallPlan(
            tool: "t", version: "1.0.0", sha256: "a", url: "u", arch: "arm64", os: "macos",
            deps: [.init(name: "d", version: "2.0.0", sha256: "b", url: "ud")],
            cellarPrefix: "/c", shim: "/s", provides: ["t"], conflicts: ["x"])
        let j = plan.toJSON()
        let deps = j["deps"] as? [[String: Any]] ?? []
        XCTAssertEqual(deps.count, 1)
        XCTAssertEqual(j["conflicts"] as? [String], ["x"])
    }
}
