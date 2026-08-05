import XCTest
@testable import GimmeCore

final class ShimManagerTests: XCTestCase {
    var paths: GimmePaths!
    var shims: ShimManager!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        shims = ShimManager(paths: paths)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.prefix)
        super.tearDown()
    }

    func testActivateWritesExecutableShim() throws {
        try shims.activate(tool: "git", version: "2.40.0", bins: ["git", "git-receive-pack"])
        let shim = shims.shimPath(for: "git")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shim.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: shim.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        XCTAssertEqual(perms & 0o111, 0o111)  // executable bit set

        let content = try String(contentsOf: shim)
        XCTAssertTrue(content.contains("cellar/git/2.40.0/bin/git"))
    }

    func testDeactivateRemovesShims() throws {
        try shims.activate(tool: "git", version: "2.40.0", bins: ["git"])
        try shims.deactivate(bins: ["git"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: shims.shimPath(for: "git").path))
    }

    func testReactivateOverwrites() throws {
        try shims.activate(tool: "git", version: "2.39.0", bins: ["git"])
        try shims.activate(tool: "git", version: "2.40.0", bins: ["git"])
        let content = try String(contentsOf: shims.shimPath(for: "git"))
        XCTAssertTrue(content.contains("2.40.0"))
        XCTAssertFalse(content.contains("2.39.0"))
    }
}
