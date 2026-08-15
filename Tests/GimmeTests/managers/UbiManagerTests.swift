import XCTest
@testable import GimmeCore

final class UbiManagerTests: XCTestCase {
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if args.contains("--version") { return ProcessResult(exitCode: 0, stdout: "ubi 0.0.1\n", stderr: "") }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    private func ubi(_ p: StubProcess, binDir: String? = nil) -> UbiManager {
        UbiManager(process: p, binary: "/tmp/ubi-stub", installDir: binDir)
    }

    func testIDAndCapabilities() {
        let m = ubi(StubProcess())
        XCTAssertEqual(m.id, .ubi)
        XCTAssertTrue(m.capabilities.contains(.install))
        XCTAssertFalse(m.capabilities.contains(.search))    // no registry
        XCTAssertFalse(m.capabilities.contains(.outdated))   // no version metadata
    }

    func testInstallCallsUbiProject() async throws {
        let p = StubProcess()
        let m = ubi(p)
        _ = try await m.install(PackageRef(name: "houseabsolute/ubi"), options: InstallOptions())
        XCTAssertTrue(p.calls.contains { $0.1.contains("--project") && $0.1.contains("houseabsolute/ubi") })
    }

    func testInstallWithTag() async throws {
        let p = StubProcess()
        let m = ubi(p)
        _ = try await m.install(PackageRef(name: "houseabsolute/ubi"), options: InstallOptions(version: "0.1.0"))
        XCTAssertTrue(p.calls.contains { $0.1.contains("--tag") && $0.1.contains("0.1.0") })
    }

    func testListScansInstallDir() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Real binaries carry a Mach-O header; shims are scripts and get filtered.
        let machO = Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0])
        try machO.write(to: tmp.appendingPathComponent("rg"))
        try machO.write(to: tmp.appendingPathComponent("bat"))
        try Data("#!/bin/sh\n".utf8).write(to: tmp.appendingPathComponent("mise-shim"))
        let m = ubi(StubProcess(), binDir: tmp.path)
        let pkgs = try await m.listInstalled()
        let names = Set(pkgs.map { $0.name })
        XCTAssertTrue(names.contains("rg"))
        XCTAssertTrue(names.contains("bat"))
        XCTAssertFalse(names.contains("mise-shim"), "script shims must not be listed as ubi packages")
    }

    func testUninstallRemovesBinary() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Binary name = last segment of "owner/repo" → "ripgrep".
        let bin = tmp.appendingPathComponent("ripgrep")
        try Data().write(to: bin)
        let m = ubi(StubProcess(), binDir: tmp.path)
        try await m.uninstall(PackageRef(name: "BurntSushi/ripgrep"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.path))
    }

    func testInfoFromGithubHomepage() async throws {
        let m = ubi(StubProcess())
        let info = try await m.info(PackageRef(name: "houseabsolute/ubi"))
        XCTAssertEqual(info.manager, .ubi)
        XCTAssertEqual(info.homepage, "https://github.com/houseabsolute/ubi")
    }
}
