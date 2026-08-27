import XCTest
import CryptoKit
@testable import GimmeCore

final class DottedVersionTests: XCTestCase {
    func testNumericSegmentOrdering() {
        XCTAssertTrue(DottedVersion.isOlder("4.51.180", than: "4.51.191"))
        XCTAssertFalse(DottedVersion.isOlder("4.51.191", than: "4.51.180"))
        XCTAssertTrue(DottedVersion.isOlder("16.4", than: "16.10"))   // numeric, not lexical
        XCTAssertFalse(DottedVersion.isOlder("1.0", than: "1.0.0"))   // padded equal
        XCTAssertFalse(DottedVersion.isOlder("2.0", than: "2.0"))
        XCTAssertTrue(DottedVersion.isOlder("1.2b3", than: "1.2b4"))  // non-numeric → lexical
        XCTAssertTrue(DottedVersion.isOlder("2.1.0", than: "2.2.0"))
        XCTAssertTrue(DottedVersion.isOlder("2.0.0-dev", than: "2.1.0"))  // dev → any release
    }
}

final class SelfUpdateTests: XCTestCase {
    /// Delegates tar invocations to a real ProcessRunner so extraction is
    /// genuinely exercised; fabricates `--version` output for binaries.
    class TarAndVersionStub: ProcessRunning {
        var calls: [(String, [String])] = []
        var defaultVersionOutput: String? = nil  // returned for any --version call
        private let real = ProcessRunner()
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            if e.hasSuffix("/tar") { return try await real.run(e, args: args, env: env, stream: stream) }
            if args.first == "--version" {
                return ProcessResult(exitCode: 0, stdout: defaultVersionOutput ?? "", stderr: "")
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        func data(for url: URL) async throws -> Data { byURL[url.absoluteString] ?? Data() }
    }

    var tmp: URL!
    var http: StubHTTP!
    var process: TarAndVersionStub!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("selfupdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        http = StubHTTP()
        process = TarAndVersionStub()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func sut() -> SelfUpdate { SelfUpdate(http: http, process: process, arch: "arm64") }

    // MARK: - release parsing

    func testLatestReleaseParsesTagAndAssets() async throws {
        http.byURL["https://api.github.com/repos/gregnazario/gimme/releases/latest"] = Data(#"""
        {"tag_name":"v2.3.0","assets":[{"name":"gimme-darwin-arm64.tar.gz","browser_download_url":"https://example.com/gimme-darwin-arm64.tar.gz"},{"name":"GimmeUI-darwin-arm64.tar.gz","browser_download_url":"https://example.com/GimmeUI-darwin-arm64.tar.gz"}]}
        """#.utf8)
        let release = await sut().latestRelease()
        XCTAssertEqual(release?.version, "2.3.0")
        XCTAssertEqual(release?.assets["gimme-darwin-arm64.tar.gz"], "https://example.com/gimme-darwin-arm64.tar.gz")
    }

    func testLatestReleaseNilOnFailure() async {
        let release = await sut().latestRelease()  // no stub → decode failure
        XCTAssertNil(release)
    }

    func testLatestReleaseParsesNotes() async {
        http.byURL["https://api.github.com/repos/gregnazario/gimme/releases/latest"] = Data(#"""
        {"tag_name":"v2.4.1","body":"## Faster fetches\n- per-package latest-version cache","assets":[]}
        """#.utf8)
        let release = await sut().latestRelease()
        XCTAssertEqual(release?.notes, "## Faster fetches\n- per-package latest-version cache")
    }

    func testLatestReleaseNotesNilWhenBodyAbsent() async {
        http.byURL["https://api.github.com/repos/gregnazario/gimme/releases/latest"] = Data(#"""
        {"tag_name":"v2.4.1","assets":[]}
        """#.utf8)
        let release = await sut().latestRelease()
        XCTAssertNil(release?.notes)
    }

    /// Cache entries written before `notes` existed lack the key; decoding
    /// an optional must not fail on them (12 h disk cache round-trip).
    func testReleaseDecodesCacheEntriesWrittenBeforeNotesExisted() throws {
        let json = #"{"tag":"v2.4.0","version":"2.4.0","assets":{"gimme-darwin-arm64.tar.gz":"https://example.com/a"}}"#
        let decoded = try JSONDecoder().decode(SelfUpdate.Release.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, "2.4.0")
        XCTAssertNil(decoded.notes)
    }

    func testIsNewer() {
        XCTAssertTrue(SelfUpdate.isNewer("2.3.0", than: "2.1.0"))
        XCTAssertFalse(SelfUpdate.isNewer("2.1.0", than: "2.1.0"))
        XCTAssertFalse(SelfUpdate.isNewer("2.0.5", than: "2.1.0"))
    }

    // MARK: - checksum verification

    /// Releases publish SHA256SUMS; when present, downloaded assets must
    /// match it (audit 2026-08-24 — version strings are not integrity).
    func testUpdateCLIVerifiesChecksumWhenSumExists() async throws {
        let fixture = try await makeCLIFixture(version: "2.3.0")
        let tarData = try Data(contentsOf: fixture)
        let digest = SHA256.hash(data: tarData).map { String(format: "%02x", $0) }.joined()
        http.byURL["https://example.com/gimme-darwin-arm64.tar.gz"] = tarData
        http.byURL["https://example.com/SHA256SUMS"] = Data("\(digest)  gimme-darwin-arm64.tar.gz\n".utf8)

        let binDir = tmp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let target = binDir.appendingPathComponent("gimme")
        try Data("old".utf8).write(to: target)
        process.defaultVersionOutput = "gimme 2.3.0\n"

        let release = SelfUpdate.Release(tag: "v2.3.0", version: "2.3.0", assets: [
            "gimme-darwin-arm64.tar.gz": "https://example.com/gimme-darwin-arm64.tar.gz",
            "SHA256SUMS": "https://example.com/SHA256SUMS",
        ])
        _ = try await sut().updateCLI(at: target, to: release)
        XCTAssertNotEqual(try String(contentsOf: target, encoding: .utf8), "old")
    }

    func testUpdateCLIMismatchedChecksumAbortsAndKeepsBinary() async throws {
        let fixture = try await makeCLIFixture(version: "2.3.0")
        http.byURL["https://example.com/gimme-darwin-arm64.tar.gz"] = try Data(contentsOf: fixture)
        http.byURL["https://example.com/SHA256SUMS"] = Data("0000000000000000000000000000000000000000000000000000000000000000  gimme-darwin-arm64.tar.gz\n".utf8)

        let target = tmp.appendingPathComponent("bin/gimme")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target)

        let release = SelfUpdate.Release(tag: "v2.3.0", version: "2.3.0", assets: [
            "gimme-darwin-arm64.tar.gz": "https://example.com/gimme-darwin-arm64.tar.gz",
            "SHA256SUMS": "https://example.com/SHA256SUMS",
        ])
        do {
            _ = try await sut().updateCLI(at: target, to: release)
            XCTFail("expected checksum mismatch")
        } catch { }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old", "target untouched")
        XCTAssertTrue(process.calls.allSatisfy { $0.0 != target.path }, "replaced binary never executed")
    }

    /// Pre-checksum releases (before v2.3.2) have no SHA256SUMS asset —
    /// verification is skipped rather than blocking updates.
    func testChecksumAbsentProceeds() async throws {
        let fixture = try await makeCLIFixture(version: "2.3.0")
        http.byURL["https://example.com/gimme-darwin-arm64.tar.gz"] = try Data(contentsOf: fixture)
        let target = tmp.appendingPathComponent("bin/gimme")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target)
        process.defaultVersionOutput = "gimme 2.3.0\n"
        let release = SelfUpdate.Release(tag: "v2.3.0", version: "2.3.0",
            assets: ["gimme-darwin-arm64.tar.gz": "https://example.com/gimme-darwin-arm64.tar.gz"])
        _ = try await sut().updateCLI(at: target, to: release)
        XCTAssertNotEqual(try String(contentsOf: target, encoding: .utf8), "old")
    }

    // MARK: - CLI update

    /// Build a real tar.gz fixture containing a `gimme` entry.
    private func makeCLIFixture(version: String) async throws -> URL {
        let src = tmp.appendingPathComponent("fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        echo "gimme \(version)"
        """
        try script.write(to: src.appendingPathComponent("gimme"), atomically: true, encoding: .utf8)
        let tarPath = tmp.appendingPathComponent("gimme-darwin-arm64.tar.gz")
        _ = try await ProcessRunner().run("/usr/bin/tar",
            args: ["-czf", tarPath.path, "-C", src.path, "gimme"], env: nil, stream: nil)
        return tarPath
    }

    func testUpdateCLIDownloadsVerifiesAndReplaces() async throws {
        let fixture = try await makeCLIFixture(version: "2.3.0")
        http.byURL["https://example.com/gimme-darwin-arm64.tar.gz"] = try Data(contentsOf: fixture)

        let binDir = tmp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let target = binDir.appendingPathComponent("gimme")
        try Data("old".utf8).write(to: target)

        let release = SelfUpdate.Release(tag: "v2.3.0", version: "2.3.0",
            assets: ["gimme-darwin-arm64.tar.gz": "https://example.com/gimme-darwin-arm64.tar.gz"])
        process.defaultVersionOutput = "gimme 2.3.0\n"
        let newVersion = try await sut().updateCLI(at: target, to: release)
        XCTAssertEqual(newVersion, "2.3.0")
        let replaced = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(replaced.contains("gimme 2.3.0"), "target was replaced with the fixture")
        // The verification call happened on the extracted binary.
        XCTAssertTrue(process.calls.contains { $0.1.first == "--version" && $0.0.contains("gimme") })
    }

    func testUpdateCLIAbortsWhenVersionDoesNotMatch() async throws {
        let fixture = try await makeCLIFixture(version: "2.3.0")
        http.byURL["https://example.com/gimme-darwin-arm64.tar.gz"] = try Data(contentsOf: fixture)
        let target = tmp.appendingPathComponent("bin/gimme")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target)
        process.defaultVersionOutput = nil  // empty stdout → mismatch

        let release = SelfUpdate.Release(tag: "v2.3.0", version: "2.3.0",
            assets: ["gimme-darwin-arm64.tar.gz": "https://example.com/gimme-darwin-arm64.tar.gz"])
        do {
            _ = try await sut().updateCLI(at: target, to: release)
            XCTFail("expected version-mismatch abort")
        } catch { }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old", "target untouched")
    }

    func testUpdateCLIDeclinesUnwritableTarget() async throws {
        let roDir = tmp.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        let target = roDir.appendingPathComponent("gimme")
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roDir.path) }

        let release = SelfUpdate.Release(tag: "v2.3.0", version: "2.3.0",
            assets: ["gimme-darwin-arm64.tar.gz": "https://example.com/nope"])
        do {
            _ = try await sut().updateCLI(at: target, to: release)
            XCTFail("expected decline")
        } catch let e as GimmeError {
            XCTAssertTrue(e.message.contains("install.sh"), "guidance to re-run install.sh")
        } catch { XCTFail("expected GimmeError") }
    }

    func testUpdateCLIMissingAssetFails() async throws {
        let target = tmp.appendingPathComponent("gimme")
        try Data("old".utf8).write(to: target)
        let release = SelfUpdate.Release(tag: "v2.3.0", version: "2.3.0", assets: [:])
        do {
            _ = try await sut().updateCLI(at: target, to: release)
            XCTFail("expected failure")
        } catch { }
    }

    // MARK: - App download

    func testDownloadAppVerifiesBundleVersion() async throws {
        // A real tar.gz containing Gimme.app with an Info.plist.
        let src = tmp.appendingPathComponent("appsrc-\(UUID().uuidString)")
        let app = src.appendingPathComponent("Gimme.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleShortVersionString": "2.3.0"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"), atomically: true)
        let tarPath = tmp.appendingPathComponent("GimmeUI-darwin-arm64.tar.gz")
        _ = try await ProcessRunner().run("/usr/bin/tar",
            args: ["-czf", tarPath.path, "-C", src.path, "Gimme.app"], env: nil, stream: nil)
        http.byURL["https://example.com/GimmeUI-darwin-arm64.tar.gz"] = try Data(contentsOf: tarPath)

        let outDir = tmp.appendingPathComponent("out")
        let appURL = try await sut().downloadApp(to: outDir, expectVersion: "2.3.0",
            assetURL: "https://example.com/GimmeUI-darwin-arm64.tar.gz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertEqual(appURL.lastPathComponent, "Gimme.app")

        // Mismatch aborts.
        let out2 = tmp.appendingPathComponent("out2")
        do {
            _ = try await sut().downloadApp(to: out2, expectVersion: "9.9.9",
                assetURL: "https://example.com/GimmeUI-darwin-arm64.tar.gz")
            XCTFail("expected mismatch abort")
        } catch { }
    }
}
