import XCTest
@testable import GimmeCore

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = Config.defaults
        XCTAssertTrue(c.behavior.autoUpdateCheck)
        XCTAssertFalse(c.behavior.pruneOldVersions)
        XCTAssertEqual(c.cache.maxAgeHours, 1)
        XCTAssertTrue(c.taps.isEmpty)
    }

    func testMissingFileReturnsDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        XCTAssertEqual(Config.loadOrCreate(at: path), .defaults)
    }

    func testRoundTrip() throws {
        var c = Config()
        c.behavior.autoUpdateCheck = false
        c.cache.maxAgeHours = 6
        c.taps["extra"] = TapConfig(url: "https://example.com/tap.git", enabled: true)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try c.toTOML().write(to: path, atomically: true, encoding: .utf8)

        let loaded = Config.loadOrCreate(at: path)
        XCTAssertEqual(loaded.behavior.autoUpdateCheck, false)
        XCTAssertEqual(loaded.cache.maxAgeHours, 6)
        XCTAssertEqual(loaded.taps["extra"]?.url, "https://example.com/tap.git")
    }
}
