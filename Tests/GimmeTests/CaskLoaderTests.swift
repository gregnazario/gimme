import XCTest
@testable import GimmeCore

final class CaskLoaderTests: XCTestCase {
    private let sampleCask = """
    cask "visual-studio-code" do
      arch arm: "arm64", intel: "x64"

      on_arm do
        version "1.92.0"
        sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1111111111111111bbbbbbbbbbbbbbbb"
      end
      on_intel do
        version "1.92.0"
        sha256 "cccccccccccccccccccccccccccccccc2222222222222222dddddddddddddddd"
      end

      url "https://update.code.visualstudio.com/#{version}/darwin-#{arch}/stable"
      name "Microsoft Visual Studio Code"
      desc "Code editing. Redefined."
      homepage "https://code.visualstudio.com/"

      app "Visual Studio Code.app"
    end
    """

    private let simpleCask = """
    cask "demo-app" do
      version "2.1.0"
      sha256 "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
      url "https://example.com/Demo-2.1.0.dmg"
      name "Demo Application"
      homepage "https://example.com"
      app "Demo.app"
    end
    """

    func testParseSimpleCask() throws {
        let c = try XCTUnwrap(CaskLoader.parse(simpleCask))
        XCTAssertEqual(c.name, "demo-app")
        XCTAssertEqual(c.version, "2.1.0")
        XCTAssertEqual(c.url, "https://example.com/Demo-2.1.0.dmg")
        XCTAssertEqual(c.sha256, "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890")
        XCTAssertEqual(c.appName, "Demo.app")
        XCTAssertEqual(c.displayName, "Demo Application")
    }

    func testParseArchSpecificCaskArm() throws {
        let c = try XCTUnwrap(CaskLoader.parse(sampleCask, host: Host(os: "macos", arch: "arm64", macosVersion: "14.0")))
        XCTAssertEqual(c.name, "visual-studio-code")
        XCTAssertEqual(c.version, "1.92.0")
        XCTAssertEqual(c.sha256, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1111111111111111bbbbbbbbbbbbbbbb")
    }

    func testParseArchSpecificCaskIntel() throws {
        let c = try XCTUnwrap(CaskLoader.parse(sampleCask, host: Host(os: "macos", arch: "x86_64", macosVersion: "14.0")))
        XCTAssertEqual(c.sha256, "cccccccccccccccccccccccccccccccc2222222222222222dddddddddddddddd")
    }

    func testVersionInterpolation() throws {
        let c = try XCTUnwrap(CaskLoader.parse(sampleCask))
        XCTAssertTrue(c.url.contains("1.92.0"), "URL should have interpolated version: \(c.url)")
    }

    func testParseInvalidReturnsNil() {
        XCTAssertNil(CaskLoader.parse("not a cask"))
        XCTAssertNil(CaskLoader.parse(""))
    }

    func testParseMissingSha256() {
        let ruby = """
        cask "foo" do
          version "1.0"
          url "https://example.com/foo.dmg"
        end
        """
        XCTAssertNil(CaskLoader.parse(ruby))
    }

    func testLoadCasksDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try simpleCask.write(to: tmp.appendingPathComponent("demo-app.rb"), atomically: true, encoding: .utf8)
        try sampleCask.write(to: tmp.appendingPathComponent("vscode.rb"), atomically: true, encoding: .utf8)

        let casks = CaskLoader.loadCasks(at: tmp)
        XCTAssertEqual(casks.count, 2)
        let names = Set(casks.map(\.name))
        XCTAssertTrue(names.contains("demo-app"))
        XCTAssertTrue(names.contains("visual-studio-code"))
    }
}
