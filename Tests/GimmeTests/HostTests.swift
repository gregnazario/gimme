import XCTest
@testable import GimmeCore

final class HostTests: XCTestCase {
    func testCurrentHost() {
        let h = Host.current
        XCTAssertEqual(h.os, "macos")
        XCTAssertTrue(h.arch == "arm64" || h.arch == "x86_64")
        XCTAssertFalse(h.macosVersion.isEmpty)
    }

    func testHostEquality() {
        let a = Host(os: "macos", arch: "arm64", macosVersion: "14.0")
        let b = Host(os: "macos", arch: "arm64", macosVersion: "14.0")
        XCTAssertEqual(a, b)
    }
}
