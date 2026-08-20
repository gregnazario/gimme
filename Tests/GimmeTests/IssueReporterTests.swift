import XCTest
@testable import GimmeCore

final class IssueReporterTests: XCTestCase {
    private func queryItems(of url: URL) throws -> [URLQueryItem] {
        try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    func testIssueURLOpensNewIssuePrefilled() throws {
        let url = try XCTUnwrap(IssueReporter.issueURL(
            title: "bun updates fail",
            happened: "Clicked Update on a bun package",
            expected: "The package upgrades",
            context: "gimme 2.1.0\nmacOS 15.6 arm64"
        ))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("/issues/new"))
        let q = try queryItems(of: url)
        XCTAssertEqual(q.first { $0.name == "title" }?.value, "bun updates fail")
        let body = try XCTUnwrap(q.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("### What happened"))
        XCTAssertTrue(body.contains("Clicked Update on a bun package"))
        XCTAssertTrue(body.contains("### What did you expect"))
        XCTAssertTrue(body.contains("The package upgrades"))
        XCTAssertTrue(body.contains("<details>"))
        XCTAssertTrue(body.contains("gimme 2.1.0"))
    }

    func testContextCollapsesAndTruncates() throws {
        // A huge activity log must not blow past practical URL lengths.
        let huge = (0..<2000).map { "activity line \($0)" }.joined(separator: "\n")
        let url = try XCTUnwrap(IssueReporter.issueURL(
            title: "t", happened: "h", expected: "e", context: huge
        ))
        XCTAssertLessThan(url.absoluteString.utf8.count, 7500)
        // The most recent entries (the end of the log) are the ones kept.
        let body = try XCTUnwrap(try queryItems(of: url).first { $0.name == "body" }?.value)
        XCTAssertFalse(body.contains("activity line 0\n"))
        XCTAssertTrue(body.contains("activity line 1999"))
    }

    func testSpecialCharactersSurviveEncoding() throws {
        let url = try XCTUnwrap(IssueReporter.issueURL(
            title: "error: \"can't\" update <pkg> & more",
            happened: "line1\nline2?q=1",
            expected: "",
            context: ""
        ))
        XCTAssertEqual(try queryItems(of: url).first { $0.name == "title" }?.value,
                       "error: \"can't\" update <pkg> & more")
    }
}
