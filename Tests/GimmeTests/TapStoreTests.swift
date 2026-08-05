import XCTest
@testable import GimmeCore

final class TapStoreTests: XCTestCase {
    var paths: GimmePaths!
    var config: Config!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        config = Config()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.prefix)
        super.tearDown()
    }

    /// Symlink the in-repo test fixtures into a tap named "core".
    private func linkFixturesAsCore() throws {
        let dest = paths.taps.appendingPathComponent("core")
        try FileManager.default.createSymbolicLink(
            at: dest, withDestinationURL: FixturePaths.coreTap())
    }

    func testFindFormula() throws {
        try linkFixturesAsCore()
        let store = TapStore(paths: paths, config: config)
        let hello = try store.find("hello")
        XCTAssertEqual(hello.name, "hello")
    }

    func testFindMissingThrows() throws {
        try linkFixturesAsCore()
        let store = TapStore(paths: paths, config: config)
        XCTAssertThrowsError(try store.find("does-not-exist"))
    }

    func testAllFormulae() throws {
        try linkFixturesAsCore()
        let store = TapStore(paths: paths, config: config)
        let all = store.allFormulae()
        let names = Set(all.map { $0.name })
        XCTAssertTrue(names.contains("hello"))
        XCTAssertTrue(names.contains("git"))
    }

    func testList() throws {
        try linkFixturesAsCore()
        let store = TapStore(paths: paths, config: config)
        XCTAssertEqual(store.list(), ["core"])
    }

    func testEnabledTapDirsPicksUpOnDiskTaps() throws {
        try linkFixturesAsCore()
        let store = TapStore(paths: paths, config: config)
        let dirs = store.enabledTapDirs()
        XCTAssertEqual(dirs.count, 1)
        XCTAssertEqual(dirs[0].lastPathComponent, "core")
    }

    func testRemove() throws {
        try linkFixturesAsCore()
        var store = TapStore(paths: paths, config: config)
        try store.remove(name: "core")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.taps.appendingPathComponent("core").path))
    }
}
