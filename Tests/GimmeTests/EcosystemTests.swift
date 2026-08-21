import XCTest
@testable import GimmeCore

final class EcosystemTests: XCTestCase {
    func testEveryManagerMapsToAnEcosystem() {
        // Every ManagerID case must have a concrete ecosystem (not crash).
        for id in ManagerID.allCases {
            let eco = id.ecosystem
            XCTAssertNotNil(Ecosystem(rawValue: eco.rawValue), "\(id.rawValue) mapped to invalid ecosystem")
        }
    }

    func testJSEcosystem() {
        XCTAssertEqual(ManagerID.bun.ecosystem, .js)
        XCTAssertEqual(ManagerID.npm.ecosystem, .js)
        XCTAssertEqual(ManagerID.pnpm.ecosystem, .js)
        XCTAssertEqual(ManagerID.yarn.ecosystem, .js)
        XCTAssertEqual(ManagerID.deno.ecosystem, .js)
    }

    func testPythonEcosystem() {
        XCTAssertEqual(ManagerID.uv.ecosystem, .python)
        XCTAssertEqual(ManagerID.pipx.ecosystem, .python)
    }

    func testSystemEcosystem() {
        XCTAssertEqual(ManagerID.homebrew.ecosystem, .system)
        XCTAssertEqual(ManagerID.aqua.ecosystem, .system)
        XCTAssertEqual(ManagerID.ubi.ecosystem, .system)
        XCTAssertEqual(ManagerID.appstore.ecosystem, .system)
    }

    func testSingletonEcosystems() {
        XCTAssertEqual(ManagerID.cargo.ecosystem, .rust)
        XCTAssertEqual(ManagerID.go.ecosystem, .go)
        XCTAssertEqual(ManagerID.gem.ecosystem, .ruby)
        XCTAssertEqual(ManagerID.composer.ecosystem, .php)
    }

    func testEcosystemManagersIsInverse() {
        for eco in Ecosystem.allCases {
            for id in eco.managers {
                XCTAssertEqual(id.ecosystem, eco, "\(id.rawValue) listed in \(eco.rawValue) but maps to \(id.ecosystem.rawValue)")
            }
        }
    }

    func testDisplayName() {
        XCTAssertEqual(Ecosystem.js.displayName, "JavaScript")
        XCTAssertEqual(Ecosystem.system.displayName, "System / native")
        XCTAssertEqual(Ecosystem.other.displayName, "Other")
    }
}
