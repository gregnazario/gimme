import XCTest
@testable import GimmeCore

final class PreferencesTests: XCTestCase {
    func testEmptyByDefault() {
        let p = Preferences()
        XCTAssertNil(p.remembered(for: "rg"))
    }

    func testRememberAndRecall() {
        var p = Preferences()
        p.remember("ripgrep", .cargo)
        XCTAssertEqual(p.remembered(for: "ripgrep"), .cargo)
    }

    func testForgetOne() {
        var p = Preferences()
        p.remember("rg", .cargo)
        p.remember("bat", .homebrew)
        p.forget("rg")
        XCTAssertNil(p.remembered(for: "rg"))
        XCTAssertEqual(p.remembered(for: "bat"), .homebrew)
    }

    func testForgetAll() {
        var p = Preferences()
        p.remember("rg", .cargo)
        p.remember("bat", .homebrew)
        p.forgetAll()
        XCTAssertNil(p.remembered(for: "rg"))
        XCTAssertNil(p.remembered(for: "bat"))
    }

    func testRoundTrip() throws {
        var p = Preferences()
        p.remember("ripgrep", .cargo)
        p.remember("github.com/spf13/cobra", .go)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("preferences.toml")
        try p.save(at: file)

        let loaded = Preferences.load(at: file)
        XCTAssertEqual(loaded.remembered(for: "ripgrep"), .cargo)
        XCTAssertEqual(loaded.remembered(for: "github.com/spf13/cobra"), .go)
    }

    func testLoadMissingFileReturnsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent("preferences.toml")
        let p = Preferences.load(at: file)
        XCTAssertNil(p.remembered(for: "anything"))
    }
}
