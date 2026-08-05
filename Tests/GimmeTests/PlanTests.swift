import XCTest
@testable import GimmeCore

final class PlanTests: XCTestCase {
    func testJSONShape() {
        let plan = InstallPlan(
            tool: "git", version: "2.40.0", sha256: "abc",
            url: "https://e/x.tar.gz", arch: "arm64", os: "macos",
            deps: [.init(name: "gettext", version: "0.21.1", sha256: "d1", url: "https://e/d.tar.gz")],
            cellarPrefix: "/cellar/git/2.40.0", shim: "/bin/git",
            provides: ["git"], conflicts: [])
        let j = plan.toJSON()
        XCTAssertEqual(j["schema_version"] as? Int, 1)
        XCTAssertEqual(j["cmd"] as? String, "plan")
        XCTAssertEqual(j["ok"] as? Bool, true)
        XCTAssertEqual(j["tool"] as? String, "git")
        XCTAssertEqual(j["version"] as? String, "2.40.0")
        let deps = j["deps"] as? [[String: Any]]
        XCTAssertEqual(deps?.first?["name"] as? String, "gettext")
    }

    func testCodableRoundTrip() throws {
        let plan = InstallPlan(
            tool: "x", version: "1.0.0", sha256: "a", url: "u", arch: nil, os: nil,
            deps: [], cellarPrefix: "/c", shim: "/s", provides: [], conflicts: [])
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: data)
        XCTAssertEqual(plan, decoded)
    }
}
