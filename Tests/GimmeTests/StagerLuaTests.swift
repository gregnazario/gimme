import XCTest
@testable import GimmeCore

final class StagerLuaTests: XCTestCase {
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

    private func makeTarball() throws -> URL {
        let pkg = tmp.appendingPathComponent("payload")
        let bin = pkg.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho hi".write(to: bin.appendingPathComponent("hello"), atomically: true, encoding: .utf8)
        let archive = tmp.appendingPathComponent("payload.tar.gz")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["czf", archive.path, "-C", tmp.path, "payload"]
        try task.run(); task.waitUntilExit()
        return archive
    }

    func testLuaStrategyStagesViaSandbox() throws {
        let archive = try makeTarball()
        let formula = Formula(
            package: .init(name: "hello"),
            versions: [.init(ver: "1.0.0")],
            install: .init(strategy: .lua, script: "install.lua")
        )
        let formulaDir = FixturePaths.coreTap().appendingPathComponent("hello")
        let staged = try stager.run(
            formula: formula, version: formula.versions[0],
            assetPath: archive, prefix: paths.cellar,
            formulaDir: formulaDir, depPaths: [:])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("bin").appendingPathComponent("hello").path))
    }
}
