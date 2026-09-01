import XCTest
@testable import GimmeCore

/// CLI argument parsing, extracted from the executable so it is testable.
/// The unknown-flag rule is a safety fix (2026-08-23): `gimme update --self`
/// on a build that predates --self silently treated the flag as a positional
/// and ran a REAL `update all`. Unknown `--flags` must hard-error instead of
/// being ignored or absorbed as package names.
final class CLIArgsTests: XCTestCase {
    func testVerbAndPositionals() throws {
        let p = try CLIArgs.parse(["install", "ripgrep", "--from", "cargo"])
        XCTAssertEqual(p.verb, "install")
        XCTAssertEqual(p.positional, ["ripgrep"])
        XCTAssertEqual(p.from, .cargo)
    }

    func testKnownFlags() throws {
        let p = try CLIArgs.parse(["update", "--self"])
        XCTAssertEqual(p.verb, "update")
        XCTAssertTrue(p.selfUpdate)
        let q = try CLIArgs.parse(["install", "rg", "--version", "1.2.3", "-y", "--json"])
        XCTAssertEqual(q.version, "1.2.3")
        XCTAssertTrue(q.yes)
        XCTAssertTrue(q.json)
        XCTAssertEqual(q.positional, ["rg"])
    }

    func testUnknownDoubleDashFlagErrors() {
        XCTAssertThrowsError(try CLIArgs.parse(["update", "--bogus"])) { error in
            XCTAssertEqual(error as? GimmeError, .usage("unknown flag: --bogus"))
        }
        XCTAssertThrowsError(try CLIArgs.parse(["install", "rg", "--selfie"]))
    }

    func testSelfFlagStillParsesForOlderVerbOrder() throws {
        // --self anywhere after the verb
        let p = try CLIArgs.parse(["update", "--refresh", "--self"])
        XCTAssertTrue(p.selfUpdate)
        XCTAssertTrue(p.refresh)
    }

    func testSingleDashNonFlagsRemainPositional() throws {
        // Package names are unlikely to start with -, but single-dash tokens
        // were positionals before and stay that way (only --flags hard-error).
        let p = try CLIArgs.parse(["install", "-weird-name"])
        XCTAssertEqual(p.positional, ["-weird-name"])
    }

    func testFromFileConsumesNextAndUnknownFromValueFallsBack() throws {
        // `--from notamanager` — the value is consumed but doesn't map; the
        // resolver errors later. Parsing itself must not throw.
        let p = try CLIArgs.parse(["install", "rg", "--from", "notamanager"])
        XCTAssertNil(p.from)
        XCTAssertEqual(p.positional, ["rg"])
    }

    func testForceFlagParsesAndImpliesRefresh() throws {
        let p = try CLIArgs.parse(["outdated", "--force"])
        XCTAssertTrue(p.force)
        XCTAssertTrue(p.refresh)
    }

    func testNoCacheIsAliasForForce() throws {
        // --no-cache was historically parsed but did nothing; it now means a
        // true force refresh (bypass engine AND response caches).
        let p = try CLIArgs.parse(["outdated", "--no-cache"])
        XCTAssertTrue(p.force)
        XCTAssertTrue(p.refresh)
    }

    func testParseFindVerb() throws {
        let p = try CLIArgs.parse(["find", "jq", "--json"])
        XCTAssertEqual(p.verb, "find")
        XCTAssertEqual(p.positional, ["jq"])
        XCTAssertTrue(p.json)
        XCTAssertFalse(p.all)  // find is all-managers by definition, not via --all
    }

    func testFindRejectsUnknownFlag() {
        XCTAssertThrowsError(try CLIArgs.parse(["find", "jq", "--bogus"]))
    }
}
