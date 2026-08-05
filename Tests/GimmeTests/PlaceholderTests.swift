import XCTest
@testable import GimmeCore

final class PlaceholderTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(GimmeCoreVersion.value, "0.1.0")
    }
}
