import XCTest
@testable import GimmeCore

final class PathsTests: XCTestCase {
    func testDefaultUserLocations() {
        let p = GimmePaths.defaultUser
        XCTAssertTrue(p.configDir.path.hasSuffix("/.config/gimme"))
        XCTAssertTrue(p.cacheDir.path.hasSuffix("/.cache/gimme"))
        XCTAssertTrue(p.configFile.path.hasSuffix("/.config/gimme/config.toml"))
        XCTAssertTrue(p.preferencesFile.path.hasSuffix("/.config/gimme/preferences.toml"))
    }

    func testEnsureDirectoriesCreates() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let p = GimmePaths(configDir: tmp.appendingPathComponent("cfg"), cacheDir: tmp.appendingPathComponent("cache"))
        try p.ensureDirectories()
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.configDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.cacheDir.path))
    }
}
