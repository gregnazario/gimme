import XCTest
@testable import GimmeCore

/// Subprocess test: invoke the real `gimme` binary in a temp cwd containing a
/// `.tool-versions`, assert the batch JSON shape. Protects the agent contract
/// for mise interop at the actual CLI layer.
final class MiseSubprocessTests: XCTestCase {
    var tmp: URL!
    var binaryPath: URL?

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let repoRoot = FixturePaths.repoRoot
        binaryPath = FileManager.default.isExecutableFile(atPath: repoRoot.appendingPathComponent(".build/debug/gimme").path)
            ? repoRoot.appendingPathComponent(".build/debug/gimme") : nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func testBinaryInstallFromToolVersionsJSON() throws {
        guard let binary = binaryPath else { return }
        // Build a tarball + tap + .tool-versions in the temp prefix.
        let prefix = tmp.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let build = tmp.appendingPathComponent("build")
        let binDir = build.appendingPathComponent("payload").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try "#!/bin/sh\necho hi".write(to: binDir.appendingPathComponent("tinytool"), atomically: true, encoding: .utf8)
        let archive = tmp.appendingPathComponent("tinytool.tar.gz")
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["czf", archive.path, "-C", build.path, "payload"]
        try tar.run(); tar.waitUntilExit()
        let sha = Downloader.sha256(of: archive)

        let tapDir = prefix.appendingPathComponent("taps/core/tinytool")
        try FileManager.default.createDirectory(at: tapDir, withIntermediateDirectories: true)
        try """
        [package]
        name = "tinytool"
        [[version]]
        ver = "1.0.0"
        [[version.asset]]
        os = "macos"
        arch = "arm64"
        url = "\(URL(fileURLWithPath: archive.path).absoluteString)"
        sha256 = "\(sha)"
        [install]
        strategy = "steps"
        [[install.step]]
        extract = "${asset}"
        [[install.step]]
        copy = { from = "payload/bin", to = "${prefix}/bin" }
        [[provides]]
        bin = ["tinytool"]
        [livecheck]
        strategy = "none"
        """.write(to: tapDir.appendingPathComponent("formula.toml"), atomically: true, encoding: .utf8)

        let proj = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try "tinytool 1.0.0\n".write(to: proj.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = binary
        task.currentDirectoryURL = proj
        task.arguments = ["--prefix", prefix.path, "install", "--json"]
        // Keep mise/asdf out of PATH so detection doesn't skip tinytool.
        task.environment = ["PATH": "/usr/bin:/bin", "HOME": prefix.path, "MISE_DATA_DIR": "/nonexistent"]
        let outPipe = Pipe(); task.standardOutput = outPipe
        let errPipe = Pipe(); task.standardError = errPipe
        try task.run(); task.waitUntilExit()

        XCTAssertEqual(task.terminationStatus, 0,
                       "stderr: \(String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")")
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let json = try XCTUnwrap(try? JSONSerialization.jsonObject(with: out.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(json["cmd"] as? String, "install-from-mise")
        XCTAssertEqual(json["source"] as? String, ".tool-versions")
        let tools = json["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["tool"] as? String, "tinytool")
        XCTAssertEqual(tools[0]["status"] as? String, "installed")
    }
}
