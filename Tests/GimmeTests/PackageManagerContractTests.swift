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

final class ResultStructTests: XCTestCase {
    func testInstalledPackageNamespacedID() {
        let p = InstalledPackage(name: "ripgrep", version: "14.1.0", manager: .homebrew, installedAt: nil)
        XCTAssertEqual(p.id, "homebrew:ripgrep")
    }

    func testOutdatedPackageNamespacedID() {
        let p = OutdatedPackage(name: "rg", installedVersion: "13.0.0", latestVersion: "14.1.0", manager: .cargo)
        XCTAssertEqual(p.id, "cargo:rg")
    }

    func testSearchHitNamespacedID() {
        let h = SearchHit(name: "esbuild", manager: .bun, summary: "bun", latestVersion: "1.0.0")
        XCTAssertEqual(h.id, "bun:esbuild")
    }

    func testInstalledPackageCodableRoundTrip() throws {
        let p = InstalledPackage(name: "rg", version: "1.0", manager: .go, installedAt: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(InstalledPackage.self, from: data)
        XCTAssertEqual(back, p)
    }
}
