import XCTest
@testable import GimmeCore

final class CellarTests: XCTestCase {
    var paths: GimmePaths!
    var cellar: Cellar!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        cellar = Cellar(paths: paths)
        try? paths.ensureDirectories()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.prefix)
        super.tearDown()
    }

    func testPrefixPath() {
        let p = cellar.prefix(for: "git", version: "2.40.0")
        XCTAssertTrue(p.path.hasSuffix("cellar/git/2.40.0"))
    }

    func testCommitMovesStaged() throws {
        let staged = paths.staging.appendingPathComponent("staged-git")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try "binary".write(to: staged.appendingPathComponent("git"), atomically: true, encoding: .utf8)

        try cellar.commit(staged: staged, tool: "git", version: "2.40.0")

        let target = cellar.prefix(for: "git", version: "2.40.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(cellar.installedVersions(for: "git"), ["2.40.0"])
        XCTAssertTrue(cellar.hasInstalled("git"))
    }

    func testCommitOverwritesExisting() throws {
        let staged1 = paths.staging.appendingPathComponent("s1")
        let staged2 = paths.staging.appendingPathComponent("s2")
        try FileManager.default.createDirectory(at: staged1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged2, withIntermediateDirectories: true)
        try "v1".write(to: staged1.appendingPathComponent("bin"), atomically: true, encoding: .utf8)
        try "v2".write(to: staged2.appendingPathComponent("bin"), atomically: true, encoding: .utf8)

        try cellar.commit(staged: staged1, tool: "x", version: "1.0.0")
        try cellar.commit(staged: staged2, tool: "x", version: "1.0.0")

        let content = try String(contentsOf: cellar.prefix(for: "x", version: "1.0.0").appendingPathComponent("bin"))
        XCTAssertEqual(content, "v2")
    }

    func testRemoveDeletes() throws {
        let staged = paths.staging.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try cellar.commit(staged: staged, tool: "x", version: "1.0.0")
        try cellar.remove(tool: "x", version: "1.0.0")
        XCTAssertFalse(cellar.hasInstalled("x"))
    }

    func testScanAllListsAll() throws {
        for v in ["1.0.0", "2.0.0"] {
            let staged = paths.staging.appendingPathComponent("s-\(v)")
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try cellar.commit(staged: staged, tool: "x", version: v)
        }
        let scan = cellar.scanAll()
        // One triple per (tool, version) -> 2 triples for one tool with two versions.
        XCTAssertEqual(scan.count, 2)
        XCTAssertTrue(scan.allSatisfy { $0.tool == "x" })
        XCTAssertEqual(Set(scan.map { $0.version }), ["1.0.0", "2.0.0"])
    }

    func testInstalledVersionsSortedDescending() throws {
        for v in ["1.0.0", "2.0.0", "1.5.0"] {
            let staged = paths.staging.appendingPathComponent("s-\(v)")
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try cellar.commit(staged: staged, tool: "x", version: v)
        }
        XCTAssertEqual(cellar.installedVersions(for: "x"), ["2.0.0", "1.5.0", "1.0.0"])
    }

    func testReceiptRoundTripThroughCellar() throws {
        let staged = paths.staging.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try cellar.commit(staged: staged, tool: "git", version: "2.40.0")

        let receipt = Receipt(
            formula: "git", tap: "core", version: "2.40.0",
            installedAt: "2026-08-03T12:00:00Z",
            asset: .init(url: "u", sha256: "abc"))
        try receipt.write(into: cellar.prefix(for: "git", version: "2.40.0"))

        let read = try XCTUnwrap(cellar.receipt(for: "git", version: "2.40.0"))
        XCTAssertEqual(read.formula, "git")
    }
}
