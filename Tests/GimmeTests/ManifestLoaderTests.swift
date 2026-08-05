import XCTest
@testable import GimmeCore

final class ManifestLoaderTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func testLoadMissingFileThrows() {
        XCTAssertThrowsError(try ManifestLoader.load(directory: tmp)) { error in
            guard case GimmeError.usage = error else {
                XCTFail("expected .usage, got \(error)"); return
            }
        }
    }

    func testRoundTripViaDecode() throws {
        let toml = """
        [package]
        name = "x"

        [[version]]
        ver = "1.2.3"

        [[version.asset]]
        url = "https://e/x.tar.gz"
        sha256 = "deadbeef"

        [install]
        strategy = "steps"
        """
        let f = try ManifestLoader.decode(toml.data(using: .utf8)!)
        XCTAssertEqual(f.name, "x")
        XCTAssertEqual(f.versions.first?.ver, "1.2.3")
        XCTAssertEqual(f.versions.first?.assets.first?.sha256, "deadbeef")
    }

    func testInvalidTomlThrowsUsage() {
        XCTAssertThrowsError(try ManifestLoader.decode("= = =".data(using: .utf8)!))
    }

    func testValidatePassesGoodFormula() throws {
        let f = Formula(
            package: .init(name: "x"),
            versions: [.init(ver: "1.0.0", assets: [Asset(url: "u", sha256: "abc")])]
        )
        try ManifestLoader.validate(f)  // should not throw
    }
}
