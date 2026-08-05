import XCTest
@testable import GimmeCore

/// Locates the repo root (the directory containing Package.swift) starting from
/// a test source file. SwiftPM doesn't bundle arbitrary resources into test
/// targets, so fixtures are resolved by filesystem path.
enum FixturePaths {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        fatalError("could not locate repo root from \(#file)")
    }()

    static func coreTap() -> URL {
        repoRoot.appendingPathComponent("Tests")
            .appendingPathComponent("GimmeTests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("taps")
            .appendingPathComponent("core")
    }

    static func tarballs() -> URL {
        repoRoot.appendingPathComponent("Tests")
            .appendingPathComponent("GimmeTests")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("tarballs")
    }
}

final class FormulaTests: XCTestCase {
    func testDecodeHelloFixture() throws {
        let fixturesDir = FixturePaths.coreTap().appendingPathComponent("hello")
        let formula = try ManifestLoader.load(directory: fixturesDir)
        XCTAssertEqual(formula.name, "hello")
        XCTAssertEqual(formula.versions.count, 2)
        XCTAssertEqual(formula.provides.bin, ["hello"])
        XCTAssertEqual(formula.install.strategy, .steps)
        XCTAssertEqual(formula.install.steps.count, 2)
    }

    func testDecodeGitFixture() throws {
        let fixturesDir = FixturePaths.coreTap().appendingPathComponent("git")
        let formula = try ManifestLoader.load(directory: fixturesDir)
        XCTAssertEqual(formula.name, "git")
        XCTAssertEqual(formula.deps.first?.name, "gettext")
        XCTAssertEqual(formula.install.strategy, .lua)
        XCTAssertEqual(formula.install.script, "install.lua")
        XCTAssertEqual(formula.livecheck?.strategy, "github-release")
        XCTAssertEqual(formula.livecheck?.repo, "git/git")
    }

    func testAssetHostMatching() {
        let host = Host(os: "macos", arch: "arm64", macosVersion: "14.0")
        let match = Asset(arch: "arm64", os: "macos", url: "u", sha256: "s")
        let wrongArch = Asset(arch: "x86_64", os: "macos", url: "u", sha256: "s")
        let unconstrained = Asset(arch: nil, os: nil, url: "u", sha256: "s")
        XCTAssertTrue(match.matches(host))
        XCTAssertFalse(wrongArch.matches(host))
        XCTAssertTrue(unconstrained.matches(host))
    }

    func testHighestVersionMatching() throws {
        let host = Host(os: "macos", arch: "arm64", macosVersion: "14.0")
        let f = Formula(
            package: .init(name: "t"),
            versions: [
                .init(ver: "2.39.0", assets: [Asset(arch: "arm64", os: "macos", url: "u1", sha256: "a")]),
                .init(ver: "2.40.0", assets: [Asset(arch: "arm64", os: "macos", url: "u2", sha256: "b")]),
                .init(ver: "2.40.1", assets: [Asset(arch: "x86_64", os: "macos", url: "u3", sha256: "c")]),
                .init(ver: "2.41.0", assets: [Asset(arch: "arm64", os: "macos", url: "u4", sha256: "d")]),
            ]
        )
        // Latest: highest host-matching -> 2.41.0
        let latest = try XCTUnwrap(f.highestVersion(matching: .any, host: host))
        XCTAssertEqual(latest.0.ver, "2.41.0")
        // Constraint 2.40 -> highest 2.40.x with arm64 -> 2.40.0 (2.40.1 is x86_64)
        let mm = try XCTUnwrap(f.highestVersion(matching: .majorMinor(major: 2, minor: 40), host: host))
        XCTAssertEqual(mm.0.ver, "2.40.0")
    }

    func testValidateRejectsMissingChecksum() {
        let f = Formula(
            package: .init(name: "t"),
            versions: [.init(ver: "1.0.0", assets: [Asset(url: "u", sha256: "")])]
        )
        XCTAssertThrowsError(try ManifestLoader.validate(f))
    }

    func testSortedVersionsDescending() {
        let f = Formula(
            package: .init(name: "t"),
            versions: [
                .init(ver: "1.0.0"),
                .init(ver: "2.0.0"),
                .init(ver: "1.5.0"),
            ]
        )
        XCTAssertEqual(f.sortedVersions.map { $0.ver }, ["2.0.0", "1.5.0", "1.0.0"])
    }
}
