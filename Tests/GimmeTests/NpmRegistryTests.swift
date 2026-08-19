import XCTest
@testable import GimmeCore

/// The npm registry search endpoint requires the `text` parameter (not `q`)
/// and a percent-encoded query — these tests pin the exact URL contract.
final class NpmRegistryTests: XCTestCase {
    func testSearchURLUsesTextParameter() {
        XCTAssertEqual(
            NpmRegistry.searchURL(query: "esbuild").absoluteString,
            "https://registry.npmjs.org/-/v1/search?text=esbuild&size=25"
        )
    }

    func testSearchURLEncodesSpaces() {
        XCTAssertEqual(
            NpmRegistry.searchURL(query: "left pad").absoluteString,
            "https://registry.npmjs.org/-/v1/search?text=left%20pad&size=25"
        )
    }

    func testSearchURLHandlesScopedNames() {
        let url = NpmRegistry.searchURL(query: "@z_ai/coding-helper")
        // Round-trip: whatever escaping Foundation chooses, the server must
        // see the original scoped name.
        let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let text = parsed?.queryItems?.first { $0.name == "text" }?.value
        XCTAssertEqual(text, "@z_ai/coding-helper")
    }
}
