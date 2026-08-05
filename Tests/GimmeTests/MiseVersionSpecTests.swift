import XCTest
@testable import GimmeCore

final class MiseVersionSpecTests: XCTestCase {
    func testExactFullVersion() {
        let s = MiseVersionSpec.parse("20.0.0")
        XCTAssertEqual(s.kind, .exact(Version("20.0.0")!))
        XCTAssertEqual(s.toGimmeQuery(tool: "node"), "node@20.0.0")
    }

    func testExactMinorVersion() {
        // "20.3" parses as exact (Version fills patch=0).
        let s = MiseVersionSpec.parse("20.3")
        XCTAssertEqual(s.kind, .exact(Version("20.3.0")!))
        XCTAssertEqual(s.toGimmeQuery(tool: "node"), "node@20.3.0")
    }

    func testFuzzyMajor() {
        let s = MiseVersionSpec.parse("20")
        XCTAssertEqual(s.kind, .fuzzyMajor(20))
        XCTAssertEqual(s.toGimmeQuery(tool: "node"), "node@20")
    }

    func testLatest() {
        let s = MiseVersionSpec.parse("latest")
        XCTAssertEqual(s.kind, .latest)
        XCTAssertEqual(s.toGimmeQuery(tool: "rg"), "rg")
    }

    func testLatestCaseInsensitive() {
        XCTAssertEqual(MiseVersionSpec.parse("LATEST").kind, .latest)
        XCTAssertEqual(MiseVersionSpec.parse("Latest").kind, .latest)
    }

    func testAliasLTS() {
        let s = MiseVersionSpec.parse("lts")
        XCTAssertEqual(s.kind, .alias("lts"))
        // Alias resolves to "newest available" (best-effort) -> bare tool query.
        XCTAssertEqual(s.toGimmeQuery(tool: "node"), "node")
    }

    func testAliasStable() {
        let s = MiseVersionSpec.parse("stable")
        XCTAssertEqual(s.kind, .alias("stable"))
        XCTAssertEqual(s.toGimmeQuery(tool: "deno"), "deno")
    }

    func testPrefixFull() {
        let s = MiseVersionSpec.parse("prefix:1.19")
        XCTAssertEqual(s.kind, .prefix(1, 19))
        XCTAssertEqual(s.toGimmeQuery(tool: "go"), "go@1.19")
    }

    func testPrefixMajorOnly() {
        // S24: prefix:3 means "any 3.x.x" in mise, NOT "any 3.0.x".
        let s = MiseVersionSpec.parse("prefix:3")
        XCTAssertEqual(s.kind, .prefixMajor(3))
        // A bare-major query resolves to fuzzyMajor(3) = any 3.x.x.
        XCTAssertEqual(s.toGimmeQuery(tool: "go"), "go@3")
    }

    func testRefUnsupported() {
        let s = MiseVersionSpec.parse("ref:master")
        if case .unsupported(let reason) = s.kind {
            XCTAssertTrue(reason.contains("ref"))
        } else { XCTFail("expected unsupported") }
        XCTAssertNil(s.toGimmeQuery(tool: "erlang"))
    }

    func testPathUnsupported() {
        let s = MiseVersionSpec.parse("path:./shfmt")
        if case .unsupported = s.kind {} else { XCTFail("expected unsupported") }
        XCTAssertNil(s.toGimmeQuery(tool: "shfmt"))
    }

    func testSubArithmeticUnsupported() {
        let s = MiseVersionSpec.parse("sub-2:lts")
        if case .unsupported = s.kind {} else { XCTFail("expected unsupported") }
        XCTAssertNil(s.toGimmeQuery(tool: "node"))
    }

    func testUnknownScopeUnsupported() {
        let s = MiseVersionSpec.parse("weird:1.0")
        if case .unsupported = s.kind {} else { XCTFail("expected unsupported") }
        XCTAssertNil(s.toGimmeQuery(tool: "x"))
    }

    func testRawPreserved() {
        let s = MiseVersionSpec.parse("prefix:1.19")
        XCTAssertEqual(s.raw, "prefix:1.19")
    }

    func testInvalidPrefixFallsBack() {
        let s = MiseVersionSpec.parse("prefix:abc")
        if case .unsupported = s.kind {} else { XCTFail("expected unsupported for non-numeric prefix") }
    }
}
