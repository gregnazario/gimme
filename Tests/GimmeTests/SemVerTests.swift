import XCTest
@testable import GimmeCore

final class SemVerTests: XCTestCase {
    // MARK: Version

    func testParseAndCompare() {
        XCTAssertTrue(Version("2.40.0")! < Version("2.41.0")!)
        XCTAssertEqual(Version("2.40.0"), Version("2.40.0")!)
        XCTAssertGreaterThan(Version("2.40.1")!, Version("2.40.0")!)
    }

    func testShortFormsParse() {
        XCTAssertEqual(Version("2")?.description, "2.0.0")
        XCTAssertEqual(Version("2.3")?.description, "2.3.0")
    }

    func testPrereleaseSortsBelow() {
        XCTAssertLessThan(Version("2.40.0-rc1")!, Version("2.40.0")!)
        XCTAssertLessThan(Version("2.40.0-rc1")!, Version("2.40.0-rc2")!)
    }

    func testInvalidParseFails() {
        XCTAssertNil(Version(""))
        XCTAssertNil(Version("abc"))
    }

    // MARK: SemVer 2.0.0 pre-release precedence (review-driven fixes)

    func testNumericPreReleaseComparesNumerically() {
        // SemVer 11: numeric identifiers compared as integers. Lexical compare
        // would wrongly give "10" < "2"; numeric gives 2 < 10.
        XCTAssertLessThan(Version("1.0.0-2")!, Version("1.0.0-10")!)
        XCTAssertLessThan(Version("1.0.0-9")!, Version("1.0.0-10")!)
        XCTAssertGreaterThan(Version("1.0.0-10")!, Version("1.0.0-9")!)
    }

    func testNumericPreLowerThanAlphanumeric() {
        // SemVer 11: numeric identifiers have lower precedence than alphanumeric.
        XCTAssertLessThan(Version("1.0.0-1")!, Version("1.0.0-alpha")!)
    }

    func testAlphabeticPreReleaseLexical() {
        XCTAssertLessThan(Version("1.0.0-alpha")!, Version("1.0.0-beta")!)
        XCTAssertLessThan(Version("1.0.0-rc.1")!, Version("1.0.0-rc.2")!)
    }

    func testMorePreFieldsHigherPrecedence() {
        // SemVer 11: 1.0.0-alpha < 1.0.0-alpha.1
        XCTAssertLessThan(Version("1.0.0-alpha")!, Version("1.0.0-alpha.1")!)
    }

    func testBuildMetadataDoesNotAffectPrecedence() {
        // SemVer 10: build metadata ignored for *ordering* (<), but the versions
        // are still distinct values (different strings), so == is false.
        XCTAssertEqual(Version("1.0.0+build1")?.major, 1)
        XCTAssertFalse(Version("1.0.0+build1")! < Version("1.0.0+build2")!)
        XCTAssertFalse(Version("1.0.0+build2")! < Version("1.0.0+build1")!)
        // Neither precedes the other -> same precedence (build ignored).
    }

    func testBuildMetadataParsed() {
        let v = Version("1.2.3+build.7")
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 3)
        XCTAssertEqual(v?.build, "build.7")
    }

    func testPreReleaseAndBuildTogether() {
        let v = Version("1.0.0-rc.1+meta")
        XCTAssertEqual(v?.pre, "rc.1")
        XCTAssertEqual(v?.build, "meta")
        // Precedence based on rc.1, ignoring +meta.
        XCTAssertLessThan(Version("1.0.0-rc.1+a")!, Version("1.0.0-rc.2+b")!)
    }

    func testClassicPrereleaseChain() {
        // The canonical SemVer example chain:
        // 1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta",
                     "1.0.0-beta", "1.0.0"].map { Version($0)! }
        for i in 0..<(chain.count - 1) {
            XCTAssertLessThan(chain[i], chain[i + 1], "expected \(chain[i]) < \(chain[i+1])")
        }
    }

    // MARK: Constraints

    func testConstraintParseAny() throws {
        if case .any = try VersionConstraint.parse("*") {} else { XCTFail("expected .any") }
        if case .any = try VersionConstraint.parse("") {} else { XCTFail("expected .any") }
    }

    func testConstraintMajorMinor() throws {
        let c = try VersionConstraint.parse("2.40")
        if case .majorMinor(let m, let mi) = c {
            XCTAssertEqual(m, 2); XCTAssertEqual(mi, 40)
        } else { XCTFail("expected majorMinor") }
    }

    func testConstraintBareMajorIsFuzzy() throws {
        // S24: a bare major ("3") means any 3.x.x, matching the mise/asdf/npm
        // convention. Previously parsed as majorMinor(3,0) which only matched 3.0.x.
        let c = try VersionConstraint.parse("3")
        if case .major(let m) = c {
            XCTAssertEqual(m, 3)
        } else { XCTFail("expected .major for bare major") }
        XCTAssertTrue(c.matches(Version("3.0.0")!))
        XCTAssertTrue(c.matches(Version("3.19.0")!))
        XCTAssertTrue(c.matches(Version("3.99.9")!))
        XCTAssertFalse(c.matches(Version("4.0.0")!))
    }

    func testConstraintExact() throws {
        let c = try VersionConstraint.parse("2.40.0")
        if case .exact(let v) = c { XCTAssertEqual(v, Version("2.40.0")!) }
        else { XCTFail("expected exact") }
    }

    func testConstraintCaretAndTilde() throws {
        if case .caret = try VersionConstraint.parse("^2.40") {} else { XCTFail("expected caret") }
        if case .tilde = try VersionConstraint.parse("~2.40.0") {} else { XCTFail("expected tilde") }
    }

    func testConstraintRange() throws {
        let c = try VersionConstraint.parse(">=2.40,<3")
        if case .range(_, _, let hi, _) = c {
            XCTAssertEqual(hi, Version("3")!)
        } else { XCTFail("expected range") }
    }

    // MARK: Matching

    func testMatchMajorMinor() throws {
        let c = try VersionConstraint.parse("2.40")
        XCTAssertTrue(c.matches(Version("2.40.0")!))
        XCTAssertTrue(c.matches(Version("2.40.5")!))
        XCTAssertFalse(c.matches(Version("2.41.0")!))
        XCTAssertFalse(c.matches(Version("2.39.9")!))
    }

    func testMatchCaret() throws {
        let c = try VersionConstraint.parse("^2.40")
        XCTAssertTrue(c.matches(Version("2.40.0")!))
        XCTAssertTrue(c.matches(Version("2.99.0")!))
        XCTAssertFalse(c.matches(Version("3.0.0")!))
        XCTAssertFalse(c.matches(Version("2.39.0")!))
    }

    func testMatchTilde() throws {
        let c = try VersionConstraint.parse("~2.40.0")
        XCTAssertTrue(c.matches(Version("2.40.0")!))
        XCTAssertTrue(c.matches(Version("2.40.5")!))
        XCTAssertFalse(c.matches(Version("2.41.0")!))
    }

    func testMatchExact() throws {
        let c = try VersionConstraint.parse("2.40.0")
        XCTAssertTrue(c.matches(Version("2.40.0")!))
        XCTAssertFalse(c.matches(Version("2.40.1")!))
    }

    func testMatchRange() throws {
        let c = try VersionConstraint.parse(">=2.40,<3")
        XCTAssertTrue(c.matches(Version("2.40.0")!))
        XCTAssertTrue(c.matches(Version("2.99.9")!))
        XCTAssertFalse(c.matches(Version("3.0.0")!))
        XCTAssertFalse(c.matches(Version("2.39.9")!))
    }

    func testMatchRangeWithLTE() throws {
        let c = try VersionConstraint.parse("<=3.0.0")
        XCTAssertTrue(c.matches(Version("3.0.0")!))
        XCTAssertFalse(c.matches(Version("3.0.1")!))
    }

    func testMatchAny() throws {
        let c = try VersionConstraint.parse("*")
        XCTAssertTrue(c.matches(Version("1.0.0")!))
        XCTAssertTrue(c.matches(Version("99.99.99")!))
    }
}
