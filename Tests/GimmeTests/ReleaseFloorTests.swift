import XCTest
@testable import GimmeCore

final class ReleaseFloorTests: XCTestCase {
    func testParsesMarkerLine() {
        let notes = """
        gimme 3.0.0

        Requires: macOS 26+

        What's New:
        - stuff
        """
        XCTAssertEqual(SelfUpdate.requiredMacOS(fromNotes: notes), 26)
    }

    func testParsingIsCaseAndFormatTolerant() {
        XCTAssertEqual(SelfUpdate.requiredMacOS(fromNotes: "requires: macOS 27 and newer"), 27)
        XCTAssertEqual(SelfUpdate.requiredMacOS(fromNotes: "Requires: macOS 30+"), 30)
        XCTAssertEqual(SelfUpdate.requiredMacOS(fromNotes: "line one\nRequires macOS 28+"), 28)
    }

    func testNoMarkerMeansNoConstraint() {
        XCTAssertNil(SelfUpdate.requiredMacOS(fromNotes: nil))
        XCTAssertNil(SelfUpdate.requiredMacOS(fromNotes: ""))
        XCTAssertNil(SelfUpdate.requiredMacOS(fromNotes: "gimme 2.5.0\n\nWhat's New:\n- no marker here"))
        XCTAssertNil(SelfUpdate.requiredMacOS(fromNotes: "Requires: something else"))
    }

    func testFirstMarkerWins() {
        XCTAssertEqual(SelfUpdate.requiredMacOS(fromNotes: "Requires: macOS 26+\nRequires: macOS 27+"), 26)
    }

    func testCompatibilityDecision() throws {
        func release(_ notes: String?) throws -> SelfUpdate.Release {
            SelfUpdate.Release(tag: "v9.0.0", version: "9.0.0", assets: [:], notes: notes)
        }
        // No marker → compatible everywhere.
        XCTAssertTrue(SelfUpdate.isCompatible(try release(nil), machineMajor: 13))
        XCTAssertTrue(SelfUpdate.isCompatible(try release("plain notes"), machineMajor: 15))
        // Marker respected at and above the floor…
        XCTAssertTrue(SelfUpdate.isCompatible(try release("Requires: macOS 26+"), machineMajor: 26))
        XCTAssertTrue(SelfUpdate.isCompatible(try release("Requires: macOS 26+"), machineMajor: 27))
        // …and refused below it.
        XCTAssertFalse(SelfUpdate.isCompatible(try release("Requires: macOS 26+"), machineMajor: 15))
    }
}
