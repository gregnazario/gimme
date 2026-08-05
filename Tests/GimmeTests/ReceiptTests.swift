import XCTest
@testable import GimmeCore

final class ReceiptTests: XCTestCase {
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

    func testRoundTrip() throws {
        let r = Receipt(
            formula: "git", tap: "core", version: "2.40.0",
            installedAt: "2026-08-03T12:00:00Z",
            asset: .init(url: "https://e/x.tar.gz", sha256: "abc", arch: "arm64", os: "macos"),
            deps: [Receipt.DepRef(name: "gettext", version: ">=0.21", resolved: "0.21.1")],
            source: "download"
        )
        try r.write(into: tmp)
        let read = try XCTUnwrap(Receipt.read(from: tmp))
        XCTAssertEqual(read, r)
    }

    func testReadMissingReturnsNil() {
        XCTAssertNil(Receipt.read(from: tmp))
    }
}
