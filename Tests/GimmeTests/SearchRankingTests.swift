import XCTest
@testable import GimmeCore

final class SearchRankingTests: XCTestCase {
    private func hit(_ name: String, _ manager: ManagerID,
                     summary: String = "", version: String = "1.0") -> SearchHit {
        SearchHit(name: name, manager: manager, summary: summary, latestVersion: version)
    }

    func testExactMatchBeatsSubstring() {
        let ranked = SearchRanking.rank(
            [hit("jqlang", .cargo, summary: "jq bindings"),
             hit("jq", .homebrew, summary: "lightweight and flexible JSON processor")],
            query: "jq", managerPriority: ["cargo", "homebrew"])
        XCTAssertEqual(ranked.first?.name, "jq")
    }

    func testPrefixBeatsSubstring() {
        let ranked = SearchRanking.rank(
            [hit("mysql", .cargo), hit("sqlite", .homebrew)],
            query: "sql", managerPriority: ["cargo", "homebrew"])
        XCTAssertEqual(ranked.first?.name, "sqlite")
    }

    func testNameMatchBeatsDescriptionMatch() {
        let ranked = SearchRanking.rank(
            [hit("prettier", .npm, summary: "opinionated code formatter"),
             hit("formatjson", .homebrew)],
            query: "format", managerPriority: ["npm", "homebrew"])
        XCTAssertEqual(ranked.first?.name, "formatjson")
    }

    func testQueryIsCaseInsensitiveAndTrimmed() {
        let ranked = SearchRanking.rank(
            [hit("jqtest", .homebrew), hit("jq", .cargo)],
            query: "  JQ ", managerPriority: ["homebrew", "cargo"])
        XCTAssertEqual(ranked.first?.name, "jq")
    }

    func testTiebreakByManagerPriority() {
        let hits = [hit("jq", .cargo), hit("jq", .homebrew)]
        XCTAssertEqual(
            SearchRanking.rank(hits, query: "jq", managerPriority: ["homebrew", "cargo"]).first?.manager,
            .homebrew)
        XCTAssertEqual(
            SearchRanking.rank(hits, query: "jq", managerPriority: ["cargo", "homebrew"]).first?.manager,
            .cargo)
    }

    func testUnknownManagerSortsLast() {
        let ranked = SearchRanking.rank(
            [hit("jq", .deno), hit("jq", .homebrew)],
            query: "jq", managerPriority: ["homebrew"])
        XCTAssertEqual(ranked.first?.manager, .homebrew)
    }

    func testNameTiebreakWhenPriorityEqual() {
        let ranked = SearchRanking.rank(
            [hit("zq", .deno), hit("aq", .ubi)],
            query: "q", managerPriority: ["homebrew"])
        XCTAssertEqual(ranked.first?.name, "aq")
    }

    func testEmptyQueryReturnsInputUnchanged() {
        let hits = [hit("jqlang", .cargo), hit("jq", .homebrew)]
        XCTAssertEqual(SearchRanking.rank(hits, query: "", managerPriority: ["homebrew"]), hits)
        XCTAssertEqual(SearchRanking.rank(hits, query: "   ", managerPriority: ["homebrew"]), hits)
    }

    func testEmptyHits() {
        XCTAssertEqual(SearchRanking.rank([], query: "jq", managerPriority: ["homebrew"]), [])
    }
}
