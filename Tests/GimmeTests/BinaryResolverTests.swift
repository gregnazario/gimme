import XCTest
@testable import GimmeCore

final class BinaryResolverTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BinaryResolver.clearCache()
    }

    func testResolveFoundBinary() {
        // /bin/sh is always present on macOS.
        let path = BinaryResolver.resolve("sh")
        XCTAssertEqual(path, "/bin/sh")
    }

    func testResolveFoundBinaryIsCached() {
        // First call resolves; second should return the cached value.
        _ = BinaryResolver.resolve("cat")
        let cached = BinaryResolver.resolve("cat")
        XCTAssertEqual(cached, "/bin/cat")
    }

    func testResolveMissingReturnsNilWithoutCrashing() {
        // A binary that definitely doesn't exist. This is the exact case that
        // crashed before (force-unwrap of a cached nil).
        let path = BinaryResolver.resolve("definitely-not-a-real-binary-xyz123")
        XCTAssertNil(path)
        // Calling again must also not crash (cache path for not-found).
        XCTAssertNil(BinaryResolver.resolve("definitely-not-a-real-binary-xyz123"))
    }

    func testFallbackUsedWhenNotFound() {
        let path = BinaryResolver.resolve("definitely-not-a-real-binary-xyz123", fallback: "/some/fallback")
        XCTAssertEqual(path, "/some/fallback")
    }
}
