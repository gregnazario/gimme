import XCTest
@testable import GimmeCore

final class PackageRefTests: XCTestCase {
    func testPackageRefNoHint() {
        let r = PackageRef(name: "ripgrep", managerHint: nil)
        XCTAssertEqual(r.name, "ripgrep")
        XCTAssertNil(r.managerHint)
    }

    func testPackageRefWithHint() {
        let r = PackageRef(name: "ripgrep", managerHint: .cargo)
        XCTAssertEqual(r.managerHint, .cargo)
    }

    func testPackageRefHashable() {
        let a = PackageRef(name: "rg", managerHint: .homebrew)
        let b = PackageRef(name: "rg", managerHint: .homebrew)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testManagerIDRawValues() {
        XCTAssertEqual(ManagerID.homebrew.rawValue, "homebrew")
        XCTAssertEqual(ManagerID.bun.rawValue, "bun")
    }

    func testCapabilityRawValues() {
        XCTAssertEqual(Capability.install.rawValue, "install")
        XCTAssertEqual(Capability.bootstrap.rawValue, "bootstrap")
    }
}
