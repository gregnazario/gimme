import XCTest
@testable import GimmeCore

final class IntrospectTests: XCTestCase {
    func testRenderHasSchemaVersion() {
        let r = Introspect.render()
        XCTAssertEqual(r["cmd"] as? String, "introspect")
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["schema_version"] as? Int, 1)
    }

    func testRenderAllCommands() {
        let r = Introspect.render()
        let cmds = r["commands"] as? [[String: Any]] ?? []
        let names = cmds.compactMap { $0["name"] as? String }
        for expected in ["install","uninstall","update","use","pin","unpin",
                         "list","search","info","outdated","tap","doctor",
                         "config","introspect"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
    }

    func testRenderScopedToCommand() {
        let r = Introspect.render(command: "install")
        let cmds = r["commands"] as? [[String: Any]] ?? []
        XCTAssertEqual(cmds.count, 1)
        XCTAssertEqual(cmds[0]["name"] as? String, "install")
    }

    func testGlobalFlagsPresent() {
        let r = Introspect.render()
        let flags = r["global_flags"] as? [[String: Any]] ?? []
        let names = flags.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("--json"))
        XCTAssertTrue(names.contains("--dry-run"))
        XCTAssertTrue(names.contains("--prefix"))
    }

    func testExitCodesComplete() {
        let r = Introspect.render()
        let codes = r["exit_codes"] as? [String: Int] ?? [:]
        XCTAssertEqual(codes["success"], 0)
        XCTAssertEqual(codes["usage"], 1)
        XCTAssertEqual(codes["install"], 2)
        XCTAssertEqual(codes["conflict"], 3)
        XCTAssertEqual(codes["lock"], 4)
        XCTAssertEqual(codes["unknown"], 70)
    }

    func testEachCommandHasOutputSchema() {
        let r = Introspect.render()
        let cmds = r["commands"] as? [[String: Any]] ?? []
        XCTAssertTrue(cmds.allSatisfy { ($0["outputSchema"] as? String)?.isEmpty == false })
    }
}
