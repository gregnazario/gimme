import XCTest
@testable import GimmeCore

/// Regression tests for dependency install paths and lock re-entrancy.
/// Installing a formula with an unmet dependency recurses through
/// `Installer.install` -> `ensureInstalled` -> `install` on the same Lock
/// instance; this must not deadlock or leak the lock.
final class DependencyInstallTests: XCTestCase {
    var tmp: URL!
    var world: World!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { world = try World(prefix: tmp); try setUpTap() }
        catch { XCTFail("setup: \(error)") }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// Build a tap with `app` (depends on `lib`) and `lib`, each backed by a
    /// real tarball. `app` has no checksummed asset of its own but declares the
    /// dep so the install path recurses.
    private func setUpTap() throws {
        // lib: a simple payload with bin/libtool.
        let libArchive = try makeArchive(name: "lib", payload: ["lib/bin/libtool": "#!/bin/sh\necho lib"])
        let libSha = Downloader.sha256(of: libArchive)
        let libDir = world.paths.taps.appendingPathComponent("core").appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        try """
        [package]
        name = "lib"
        [[version]]
        ver = "1.0.0"
        [[version.asset]]
        os = "macos"
        arch = "arm64"
        url = "\(URL(fileURLWithPath: libArchive.path).absoluteString)"
        sha256 = "\(libSha)"
        [install]
        strategy = "steps"
        [[install.step]]
        extract = "${asset}"
        [[install.step]]
        copy = { from = "lib/bin", to = "${prefix}/bin" }
        [[provides]]
        bin = ["libtool"]
        [livecheck]
        strategy = "none"
        """.write(to: libDir.appendingPathComponent("formula.toml"), atomically: true, encoding: .utf8)

        // app: depends on lib, has its own tarball.
        let appArchive = try makeArchive(name: "app", payload: ["app/bin/app": "#!/bin/sh\necho app"])
        let appSha = Downloader.sha256(of: appArchive)
        let appDir = world.paths.taps.appendingPathComponent("core").appendingPathComponent("app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try """
        [package]
        name = "app"
        [[version]]
        ver = "1.0.0"
        [[version.asset]]
        os = "macos"
        arch = "arm64"
        url = "\(URL(fileURLWithPath: appArchive.path).absoluteString)"
        sha256 = "\(appSha)"
        [install]
        strategy = "steps"
        [[install.step]]
        extract = "${asset}"
        [[install.step]]
        copy = { from = "app/bin", to = "${prefix}/bin" }
        [[dep]]
        name = "lib"
        [[provides]]
        bin = ["app"]
        [livecheck]
        strategy = "none"
        """.write(to: appDir.appendingPathComponent("formula.toml"), atomically: true, encoding: .utf8)
    }

    private func makeArchive(name: String, payload: [String: String]) throws -> URL {
        let staging = tmp.appendingPathComponent("build-\(name)")
        for (member, content) in payload {
            let path = staging.appendingPathComponent(member)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: path, atomically: true, encoding: .utf8)
        }
        let archive = tmp.appendingPathComponent("tarballs/\(name).tar.gz")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        t.arguments = ["czf", archive.path, "-C", staging.path, name]
        try t.run(); t.waitUntilExit()
        return archive
    }

    func testInstallFormulaWithDependencyDoesNotDeadlock() throws {
        // This is the regression test for the lock re-entrancy bug. Before the
        // fix, install("app") -> ensureInstalled("lib") -> install("lib")
        // re-acquired the same Lock and deadlocked/leaked.
        let result = try world.installer.install(query: "app", dryRun: false, insecure: false)
        XCTAssertEqual(result.tool, "app")
        XCTAssertEqual(result.version, "1.0.0")

        // The dep must also be installed.
        XCTAssertTrue(world.cellar.hasInstalled("lib", version: Version("1.0.0")!))
        XCTAssertNotNil(world.cellar.receipt(for: "lib", version: "1.0.0"))

        // The lock must be fully released after install (depth back to 0) so the
        // next command can acquire it.
        try world.lock.acquire(timeoutSeconds: 1)
        world.lock.release()
    }

    func testLockReentrancyCounter() throws {
        // Direct unit test of the re-entrancy counter behavior.
        try world.lock.acquire(timeoutSeconds: 1)
        try world.lock.acquire(timeoutSeconds: 1)  // re-entrant: no-op + depth++
        try world.lock.acquire(timeoutSeconds: 1)  // depth++ again
        world.lock.release()  // depth-- (still held)
        world.lock.release()  // depth-- (still held)
        // Should still be held by us.
        try world.lock.acquire(timeoutSeconds: 1)  // depth++
        world.lock.release()  // depth-- (still held)
        world.lock.release()  // depth == 0 -> released
        // Now a fresh acquire must succeed.
        try world.lock.acquire(timeoutSeconds: 1)
        world.lock.release()
    }

    func testReleaseWithoutAcquireIsNoop() {
        // Calling release() before any acquire must not crash.
        let freshLock = Lock(paths: world.paths)
        freshLock.release()  // should be a no-op
    }
}
