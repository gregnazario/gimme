import XCTest
@testable import GimmeCore

final class SandboxTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// Build a tiny tarball: <tmp>/asset.tar.gz containing payload/bin/hello.
    private func makeAssetTarball() throws -> URL {
        let payload = tmp.appendingPathComponent("payload")
        let binDir = payload.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try "#!/bin/sh\necho hi".write(
            to: binDir.appendingPathComponent("hello"), atomically: true, encoding: .utf8)

        let archive = tmp.appendingPathComponent("asset.tar.gz")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["czf", archive.path, "-C", tmp.path, "payload"]
        try task.run(); task.waitUntilExit()
        return archive
    }

    func testRunInstallExtractsAndInstallsIntoPrefix() throws {
        let archive = try makeAssetTarball()
        let prefix = tmp.appendingPathComponent("prefix")
        let workDir = tmp.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let config = Sandbox.Config(
            workDir: workDir, prefix: prefix, assetPath: archive,
            depPaths: [:], host: Host.current)
        let sandbox = Sandbox(config: config)

        let script = FixturePaths.coreTap().appendingPathComponent("hello").appendingPathComponent("install.lua")
        let provides = try sandbox.runInstall(at: script)

        XCTAssertEqual(provides, ["hello"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefix.appendingPathComponent("bin").appendingPathComponent("hello").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefix.appendingPathComponent("share").appendingPathComponent("man").path))
    }

    func testBlockedGlobalsRaise() throws {
        let archive = try makeAssetTarball()
        let prefix = tmp.appendingPathComponent("prefix")
        let workDir = tmp.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let config = Sandbox.Config(
            workDir: workDir, prefix: prefix, assetPath: archive,
            depPaths: [:], host: Host.current)
        let sandbox = Sandbox(config: config)

        let script = workDir.appendingPathComponent("bad.lua")
        try #"""
        function install(ctx)
          os.execute("rm -rf /")
        end
        """#.write(to: script, atomically: true, encoding: .utf8)

        // os.execute is nil'd out -> calling it raises a Lua error.
        XCTAssertThrowsError(try sandbox.runInstall(at: script))
    }

    /// CRITICAL regression test: `package.loadlib` would allow arbitrary native
    /// code execution (dlopen/dlsym). The sandbox must not expose `package` at all.
    func testPackageLoadlibIsBlocked() throws {
        let archive = try makeAssetTarball()
        let prefix = tmp.appendingPathComponent("prefix")
        let workDir = tmp.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let config = Sandbox.Config(
            workDir: workDir, prefix: prefix, assetPath: archive,
            depPaths: [:], host: Host.current)
        let sandbox = Sandbox(config: config)

        let script = workDir.appendingPathComponent("loadlib.lua")
        // If `package` is accessible, calling a nil package.loadlib raises; but
        // the escape is `package` itself being non-nil. We assert it raises.
        try #"""
        function install(ctx)
          -- This must raise: package.loadlib is the sandbox escape primitive.
          package.loadlib("/usr/lib/libSystem.B.dylib", "system")()
        end
        """#.write(to: script, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try sandbox.runInstall(at: script)) { error in
            // Must be an install error (Lua runtime/load error), not success.
            guard case GimmeError.install = error else {
                XCTFail("expected sandbox to block package.loadlib, got: \(error)"); return
            }
        }
    }

    /// All other code-loading primitives must also be blocked.
    func testAllLoadPrimitivesBlocked() throws {
        let archive = try makeAssetTarball()
        let prefix = tmp.appendingPathComponent("prefix")
        let workDir = tmp.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let config = Sandbox.Config(
            workDir: workDir, prefix: prefix, assetPath: archive,
            depPaths: [:], host: Host.current)
        let sandbox = Sandbox(config: config)

        for primitive in ["loadfile", "dofile", "load", "require", "debug"] {
            let script = workDir.appendingPathComponent("bad-\(primitive).lua")
            try """
            function install(ctx)
              \(primitive)("x")
            end
            """.write(to: script, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try sandbox.runInstall(at: script),
                                 "\(primitive) should be blocked") { error in
                guard case GimmeError.install = error else {
                    XCTFail("\(primitive) not blocked, got: \(error)"); return
                }
            }
        }
    }
}
