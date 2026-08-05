import XCTest
@testable import GimmeCore

final class GimmeErrorTests: XCTestCase {
    func testCategoryMapping() {
        XCTAssertEqual(GimmeError.usage("x").category, .USAGE)
        XCTAssertEqual(GimmeError.notFound("x").category, .NOT_FOUND)
        XCTAssertEqual(GimmeError.install("x").category, .INSTALL)
        XCTAssertEqual(GimmeError.network("x").category, .NETWORK)
        XCTAssertEqual(GimmeError.checksumMismatch(expected: "a", actual: "b").category, .CHECKSUM)
        XCTAssertEqual(GimmeError.permission("x").category, .PERMISSION)
        XCTAssertEqual(GimmeError.conflict("x").category, .CONFLICT)
        XCTAssertEqual(GimmeError.lock("x").category, .LOCK)
        XCTAssertEqual(GimmeError.unknown("x").category, .UNKNOWN)
    }

    func testExitCodes() {
        XCTAssertEqual(ErrorCategory.USAGE.exitCode, 1)
        XCTAssertEqual(ErrorCategory.NOT_FOUND.exitCode, 1)
        XCTAssertEqual(ErrorCategory.INSTALL.exitCode, 2)
        XCTAssertEqual(ErrorCategory.NETWORK.exitCode, 2)
        XCTAssertEqual(ErrorCategory.CHECKSUM.exitCode, 2)
        XCTAssertEqual(ErrorCategory.PERMISSION.exitCode, 2)
        XCTAssertEqual(ErrorCategory.CONFLICT.exitCode, 3)
        XCTAssertEqual(ErrorCategory.LOCK.exitCode, 4)
        XCTAssertEqual(ErrorCategory.UNKNOWN.exitCode, 70)
    }

    func testRecoverableAndSuggested() {
        XCTAssertFalse(GimmeError.checksumMismatch(expected: "a", actual: "b").recoverable)
        XCTAssertEqual(GimmeError.checksumMismatch(expected: "a", actual: "b").suggested,
                       "gimme uninstall <tool> && gimme install <tool>")
        XCTAssertTrue(GimmeError.network("timeout").recoverable)
        XCTAssertNotNil(GimmeError.network("x").suggested)
        XCTAssertNil(GimmeError.usage("bad").suggested)
    }

    func testChecksumMismatchDetails() {
        let e = GimmeError.checksumMismatch(expected: "aaa", actual: "bbb")
        let j = e.toJSON()
        XCTAssertEqual(j["ok"] as? Bool, false)
        let err = j["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? String, "CHECKSUM")
        XCTAssertEqual(err?["recoverable"] as? Bool, false)
        let details = err?["details"] as? [String: String]
        XCTAssertEqual(details?["expected"], "aaa")
        XCTAssertEqual(details?["actual"], "bbb")
    }

    func testMessageForNonDetailed() {
        XCTAssertEqual(GimmeError.usage("bad args").message, "bad args")
        XCTAssertEqual(GimmeError.network("down").message, "down")
    }
}
