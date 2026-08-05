import XCTest
@testable import GimmeCore

final class StateStoreTests: XCTestCase {
    var paths: GimmePaths!
    var store: StateStore!
    var cellar: Cellar!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        store = StateStore(paths: paths)
        cellar = Cellar(paths: paths)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.prefix)
        super.tearDown()
    }

    func testRecordAndSetActive() throws {
        try store.recordInstalled("git", version: "2.40.0")
        try store.recordInstalled("git", version: "2.39.0")
        try store.setActive("git", version: "2.40.0")

        let entries = store.loadInstalled()
        XCTAssertEqual(entries["git"]?.installed, ["2.40.0", "2.39.0"])
        XCTAssertEqual(entries["git"]?.active, "2.40.0")
    }

    func testRemoveInstalledClearsActiveWhenRemoved() throws {
        try store.recordInstalled("git", version: "2.40.0")
        try store.setActive("git", version: "2.40.0")
        try store.removeInstalled("git", version: "2.40.0")
        let entries = store.loadInstalled()
        XCTAssertNil(entries["git"])  // entry removed when no versions left
    }

    func testRebuildFromCellar() throws {
        // Install two versions into the cellar directly.
        for v in ["2.39.0", "2.40.0"] {
            let staged = paths.staging.appendingPathComponent("s-\(v)")
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try cellar.commit(staged: staged, tool: "git", version: v)
            let receipt = Receipt(
                formula: "git", tap: "core", version: v, installedAt: "now",
                asset: .init(url: "u", sha256: "abc"))
            try receipt.write(into: cellar.prefix(for: "git", version: v))
        }

        // No installed.json yet -> rebuild.
        try store.rebuild(from: cellar)
        let entries = store.loadInstalled()
        XCTAssertEqual(entries["git"]?.installed.sorted(), ["2.39.0", "2.40.0"])
        XCTAssertEqual(entries["git"]?.active, "2.40.0")  // highest
    }

    func testPinUnpin() throws {
        try store.pin("git", version: "2.40.0")
        XCTAssertEqual(store.loadPinned()["git"], "2.40.0")
        try store.unpin("git")
        XCTAssertNil(store.loadPinned()["git"])
    }

    func testLoadPinnedMissingFile() {
        let s = StateStore(paths: paths)
        XCTAssertTrue(s.loadPinned().isEmpty)
    }

    func testLoadInstalledMissingFile() {
        let s = StateStore(paths: paths)
        XCTAssertTrue(s.loadInstalled().isEmpty)
    }
}
