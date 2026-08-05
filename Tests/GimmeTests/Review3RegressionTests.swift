import XCTest
@testable import GimmeCore

/// Regression tests for the third-pass review fixes: tap-remove path traversal,
/// shim command injection / unsafe-name validation, and atomic pinned.json writes.
final class Review3RegressionTests: XCTestCase {
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

    // MARK: C1 — TapStore.remove path traversal

    func testTapRemoveRejectsTraversal() throws {
        // Set up a real dir OUTSIDE the taps dir that remove must NOT touch.
        let victim = tmp.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try "important".write(to: victim.appendingPathComponent("secret"), atomically: true, encoding: .utf8)

        // Make taps/ so a `..`-relative path would resolve at the victim.
        // (taps is at tmp/taps; "../../victim" from there = tmp/../victim which
        // is outside tmp; to make the test deterministic, plant a symlink-free
        // layout where taps/<x> exists and remove("../../<x>") would escape.)
        let store = TapStore(paths: paths, config: Config())

        for bad in ["../../victim", "..", "../", "foo/../bar"] {
            XCTAssertThrowsError(try store.remove(name: bad), "should reject \(bad)") { error in
                guard case GimmeError.usage = error else {
                    XCTFail("expected usage for \(bad), got \(error)"); return
                }
            }
        }
        // The victim must be untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.appendingPathComponent("secret").path))
    }

    func testTapRemoveAcceptsValidName() throws {
        // Create a tap dir directly (skip git clone) then remove it.
        let name = "valid-tap"
        let dest = paths.taps.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let store = TapStore(paths: paths, config: Config())
        try store.remove(name: name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: C2 — unsafe-name rejection (shim injection / path escape)

    func testNameSafetyRejectsUnsafe() {
        let bad: [String] = ["..", "../x", "a/b", "a\\b", "a;b", "a b", "a$b",
                             "a\"b", "a'b", "a`b`", "a#b", "a\nb"]
        for b in bad {
            XCTAssertFalse(NameSafety.isSafe(b), "should reject \(b)")
        }
    }

    func testNameSafetyAcceptsSafe() {
        for ok in ["git", "git-receive-pack", "node", "python3", "tool.v2", "pkg_1", "go+tools"] {
            XCTAssertTrue(NameSafety.isSafe(ok), "should accept \(ok)")
        }
    }

    func testManifestLoaderRejectsUnsafeBin() {
        let f = Formula(
            package: .init(name: "ok"),
            versions: [.init(ver: "1.0.0", assets: [Asset(url: "u", sha256: "abc")])],
            install: .init(),
            provides: .init(bin: ["evil;rm -rf ~"]))
        XCTAssertThrowsError(try ManifestLoader.validate(f)) { error in
            guard case GimmeError.usage = error else { XCTFail("got \(error)"); return }
        }
    }

    func testManifestLoaderRejectsUnsafeVersion() {
        let f = Formula(
            package: .init(name: "ok"),
            versions: [.init(ver: "1.0.0/../x", assets: [Asset(url: "u", sha256: "abc")])])
        XCTAssertThrowsError(try ManifestLoader.validate(f)) { error in
            guard case GimmeError.usage = error else { XCTFail("got \(error)"); return }
        }
    }

    func testManifestLoaderRejectsUnsafePackageName() {
        let f = Formula(
            package: .init(name: "evil;rm"),
            versions: [.init(ver: "1.0.0", assets: [Asset(url: "u", sha256: "abc")])])
        XCTAssertThrowsError(try ManifestLoader.validate(f)) { error in
            guard case GimmeError.usage = error else { XCTFail("got \(error)"); return }
        }
    }

    func testShimManagerRejectsUnsafeBin() throws {
        let shims = ShimManager(paths: paths)
        XCTAssertThrowsError(
            try shims.activate(tool: "ok", version: "1.0.0", bins: ["evil;rm -rf ~"])) { error in
            guard case GimmeError.usage = error else { XCTFail("got \(error)"); return }
        }
        // No shim written.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bin.appendingPathComponent("evil;rm -rf ~").path))
    }

    func testShimScriptContainsNoInjectionForSafeNames() throws {
        // A well-named tool/version/bin produces a shim with no shell injection.
        let shims = ShimManager(paths: paths)
        try shims.activate(tool: "node", version: "20.10.0", bins: ["node", "npm"])
        let nodeShim = try String(contentsOf: shims.shimPath(for: "node"))
        XCTAssertTrue(nodeShim.contains("cellar/node/20.10.0/bin/node"))
        // No shell metacharacters from interpolation beyond the safe path.
        XCTAssertFalse(nodeShim.contains(";"))
        XCTAssertFalse(nodeShim.contains("`"))
    }

    // MARK: I1 — atomic pinned.json writes + corrupt-file signal

    func testPinnedJsonWrittenAtomically() throws {
        let state = StateStore(paths: paths)
        try state.pin("git", version: "2.40.0")
        // The file must be valid JSON (atomic write succeeded).
        let data = try Data(contentsOf: paths.state.appendingPathComponent("pinned.json"))
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(decoded["git"], "2.40.0")
    }

    func testCorruptPinnedJsonReturnsEmpty() throws {
        // Documents current behavior: a corrupt pinned.json falls back to [:].
        // (Self-heal for pinned.json is not implemented because pins are user
        // intent that can't be reconstructed from the cellar; atomic writes
        // are the prevention. This test pins the behavior.)
        try "BROKEN{{{".write(to: paths.state.appendingPathComponent("pinned.json"),
                             atomically: true, encoding: .utf8)
        let state = StateStore(paths: paths)
        XCTAssertTrue(state.loadPinned().isEmpty)
    }
}
