import XCTest
@testable import GimmeCore

final class StagerStepsTests: XCTestCase {
    var paths: GimmePaths!
    var stager: Stager!
    var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        stager = Stager(paths: paths, host: Host.current)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// Build a tarball containing pkg/bin/hello.
    private func makeTarball() throws -> URL {
        let pkg = tmp.appendingPathComponent("pkg")
        let bin = pkg.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho hi".write(to: bin.appendingPathComponent("hello"), atomically: true, encoding: .utf8)
        let archive = tmp.appendingPathComponent("pkg.tar.gz")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["czf", archive.path, "-C", tmp.path, "pkg"]
        try task.run(); task.waitUntilExit()
        return archive
    }

    func testStepsStrategyStagesExtractedContent() throws {
        let archive = try makeTarball()
        let formula = Formula(
            package: .init(name: "pkg"),
            versions: [.init(ver: "1.0.0")],
            install: .init(strategy: .steps, steps: [
                .init(extract: "${asset}"),
                .init(copy: Formula.CopySpec(from: "pkg", to: "${prefix}"))
            ])
        )
        let staged = try stager.run(
            formula: formula, version: formula.versions[0],
            assetPath: archive, prefix: paths.cellar, depPaths: [:])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("pkg").appendingPathComponent("bin").appendingPathComponent("hello").path))
    }

    func testFailureCleansStaging() throws {
        let archive = try makeTarball()
        // A step that references a nonexistent path -> throws.
        let formula = Formula(
            package: .init(name: "bad"),
            versions: [.init(ver: "1.0.0")],
            install: .init(strategy: .steps, steps: [
                .init(copy: Formula.CopySpec(from: "nonexistent", to: "${prefix}/x"))
            ])
        )
        XCTAssertThrowsError(try stager.run(
            formula: formula, version: formula.versions[0],
            assetPath: archive, prefix: paths.cellar, depPaths: [:]))
        // staging dir should be cleaned: no leftover stage-* dirs.
        let stagingEntries = (try? FileManager.default.contentsOfDirectory(atPath: paths.staging.path)) ?? []
        XCTAssertTrue(stagingEntries.allSatisfy { !$0.hasPrefix("stage-") })
    }
}
