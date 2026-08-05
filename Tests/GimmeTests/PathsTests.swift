import XCTest
@testable import GimmeCore

final class PathsTests: XCTestCase {
    func testPathsLayout() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let p = GimmePaths(prefix: tmp)
        XCTAssertEqual(p.bin,       tmp.appendingPathComponent("bin"))
        XCTAssertEqual(p.cellar,    tmp.appendingPathComponent("cellar"))
        XCTAssertEqual(p.cache,     tmp.appendingPathComponent("cache"))
        XCTAssertEqual(p.taps,      tmp.appendingPathComponent("taps"))
        XCTAssertEqual(p.staging,   tmp.appendingPathComponent("staging"))
        XCTAssertEqual(p.state,     tmp.appendingPathComponent("state"))
        XCTAssertEqual(p.logs,      tmp.appendingPathComponent("logs"))
        XCTAssertEqual(p.configFile, tmp.appendingPathComponent("config.toml"))
    }

    func testEnsureDirectories() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let p = GimmePaths(prefix: tmp)
        try p.ensureDirectories()
        let fm = FileManager.default
        for d in [p.bin, p.cellar, p.cache, p.taps, p.staging, p.state, p.logs] {
            XCTAssertTrue(fm.fileExists(atPath: d.path), "missing \(d.path)")
        }
    }

    func testDefaultUserPrefixEndsWithGimme() {
        XCTAssertTrue(GimmePaths.defaultUserPrefix.path.hasSuffix("/.gimme"))
    }
}
