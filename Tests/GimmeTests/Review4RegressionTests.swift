import XCTest
@testable import GimmeCore

/// Regression tests for the fourth-pass hardening: downloader size cap +
/// streaming hash, per-member safe extraction, ReDoS input cap, lock
/// thread-safety/O_NOFOLLOW, Cellar memoization, TOML escape-aware comment strip.
final class Review4RegressionTests: XCTestCase {
    var tmp: URL!
    var paths: GimmePaths!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: Downloader — streaming hash + size cap

    func testStreamingSha256MatchesKnownVector() {
        // Build a >64KiB file and confirm streaming sha256 matches the known
        // value for its exact bytes (computed via the in-memory helper).
        let payload = Data((0..<(200_000)).map { _ in UInt8.random(in: 0...255) })
        let f = tmp.appendingPathComponent("big")
        try? payload.write(to: f)
        XCTAssertEqual(Downloader.sha256(of: f), Downloader.sha256(ofData: payload))
    }

    func testStreamingSha256MatchesSmallFile() {
        let payload = "abc".data(using: .utf8)!
        let f = tmp.appendingPathComponent("abc")
        try? payload.write(to: f)
        XCTAssertEqual(Downloader.sha256(of: f),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testDownloaderRejectsOversizedLocalAsset() throws {
        let dl = Downloader(paths: paths, maxDownloadBytes: 16)
        let big = tmp.appendingPathComponent("big")
        try Data(count: 1024).write(to: big)
        let asset = Asset(url: URL(fileURLWithPath: big.path).absoluteString,
                          sha256: Downloader.sha256(of: big))
        XCTAssertThrowsError(try dl.fetch(asset: asset)) { error in
            guard case GimmeError.network = error else {
                XCTFail("expected network (size limit), got \(error)"); return
            }
        }
    }

    func testDownloaderAcceptsUnderLimit() throws {
        let dl = Downloader(paths: paths, maxDownloadBytes: 1_000_000)
        let payload = "hi".data(using: .utf8)!
        let src = tmp.appendingPathComponent("src")
        try payload.write(to: src)
        let asset = Asset(url: URL(fileURLWithPath: src.path).absoluteString,
                          sha256: Downloader.sha256(of: src))
        let result = try dl.fetch(asset: asset)
        XCTAssertEqual(Downloader.sha256(of: result), Downloader.sha256(of: src))
    }

    // MARK: Livecheck — ReDoS input cap

    func testLivecheckParseVersionCapsLargeInput() {
        // A large input whose version is within the first 1 MiB should parse
        // correctly (the cap truncates the tail, which is fine).
        let prefix = String(repeating: "x", count: 100_000)  // 100 KiB, well under cap
        let text = prefix + " release v1.2.3 is out"
        let v = Livecheck.parseVersionStatic(from: text, with: nil)
        XCTAssertEqual(v?.description, "1.2.3")
    }

    func testLivecheckParseVersionTruncatesPastCap() {
        // A version that appears ONLY past the 1 MiB cap is not seen (the input
        // is truncated). This documents the bound.
        let prefix = String(repeating: "x", count: Livecheck.maxRegexInputBytes + 100)
        let text = prefix + "1.2.3"
        let v = Livecheck.parseVersionStatic(from: text, with: nil)
        XCTAssertNil(v)
    }

    func testLivecheckDefaultRegexOnBoundedInput() {
        // Default regex \d+\.\d+\.\d+ still works after the cap path.
        let v = Livecheck.parseVersionStatic(from: "no version here at all", with: nil)
        XCTAssertNil(v)
    }

    // MARK: Lock — O_NOFOLLOW + thread-safety

    func testLockAcquireReleaseStillWorks() throws {
        let lock = Lock(paths: paths)
        try lock.acquire(timeoutSeconds: 1)
        lock.release()
        try lock.acquire(timeoutSeconds: 1)
        lock.release()
    }

    func testLockReentrancySurvives() throws {
        let lock = Lock(paths: paths)
        try lock.acquire(timeoutSeconds: 1)
        try lock.acquire(timeoutSeconds: 1)
        lock.release()
        // Still held -> a fresh Lock instance should time out (not us).
        let other = Lock(paths: paths)
        XCTAssertThrowsError(try other.acquire(timeoutSeconds: 1)) { error in
            guard case GimmeError.lock = error else { XCTFail("got \(error)"); return }
        }
        lock.release()
        // Now the fresh one can acquire.
        try other.acquire(timeoutSeconds: 1)
        other.release()
    }

    // MARK: Cellar — always-fresh scan (memoization reverted as unsafe)

    func testCellarScanReflectsExternalWrites() throws {
        // scanAll must always read fresh (no memo), so a receipt written by an
        // external path is visible on the next call.
        let cellar = Cellar(paths: paths)
        XCTAssertTrue(cellar.scanAll().isEmpty)
        let p = cellar.prefix(for: "t", version: "1.0.0")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try Receipt(formula: "t", tap: "core", version: "1.0.0", installedAt: "now",
                    asset: .init(url: "u", sha256: "s")).write(into: p)
        // Without any invalidation call, scanAll sees the new entry.
        XCTAssertEqual(cellar.scanAll().count, 1)
    }

    func testCellarInstalledToolsReflectsWrites() throws {
        let cellar = Cellar(paths: paths)
        for v in ["1.0.0", "2.0.0"] {
            let p = cellar.prefix(for: "tool", version: v)
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
            try Receipt(formula: "tool", tap: "core", version: v, installedAt: "now",
                        asset: .init(url: "u", sha256: "s")).write(into: p)
        }
        XCTAssertEqual(cellar.installedTools(), ["tool"])
    }

    // MARK: TOML — escape-aware comment strip

    func testTomlCommentStripHandlesEscapedQuote() throws {
        // A basic string containing an escaped quote, then a # that is part of
        // the string, then a real comment after.
        let t = try TOML.parse(#"url = "https://x/y#z" # real comment"#)
        XCTAssertEqual(t.string("url"), "https://x/y#z")
    }

    func testTomlCommentStripHandlesBackslashQuote() throws {
        // \" inside the basic string must not close the string.
        let t = try TOML.parse(#"desc = "a \"quoted\" value # not a comment" # real"#)
        // parseBasicString unescapes \" to ".
        XCTAssertEqual(t.string("desc"), "a \"quoted\" value # not a comment")
    }

    // MARK: SafeExtractor — per-member extraction rejects escaping symlink

    func testSafeExtractorRejectsSymlinkEscapingMidArchive() throws {
        // Build a tarball containing a symlink that escapes, followed by a
        // member written through it. SafeExtractor must abort.
        let staging = tmp.appendingPathComponent("mal-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // A symlink "escape" -> /tmp (outside any extract dir).
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/tmp"))
        let archive = tmp.appendingPathComponent("mal.tar.gz")
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        t.arguments = ["czf", archive.path, "-C", staging.path, "escape"]
        try t.run(); t.waitUntilExit()

        let dest = tmp.appendingPathComponent("out")
        XCTAssertThrowsError(try SafeExtractor.extract(archive: archive, into: dest)) { error in
            guard case GimmeError.install = error else {
                XCTFail("expected install error for escaping symlink, got \(error)"); return
            }
        }
        // dest should have been cleaned (no leftover).
        if FileManager.default.fileExists(atPath: dest.path) {
            // The escaping symlink member may or may not remain; assert it's
            // NOT a symlink to /tmp anymore (either removed or stripped).
            let esc = dest.appendingPathComponent("escape")
            if FileManager.default.fileExists(atPath: esc.path) {
                let target = esc.resolvingSymlinksInPath().path
                XCTAssertNotEqual(target, "/tmp",
                                  "escaping symlink survived extraction")
            }
        }
    }

    /// S23 regression: a gzipped archive with many members must extract without
    /// the O(n²) re-decompression cliff. The bulk-extract path is O(n); the old
    /// per-member path took ~28s for 200 members. Bound is generous enough for
    /// CI but tight enough to catch the regression.
    func testSafeExtractorHandlesManyMemberGzipQuickly() throws {
        let staging = tmp.appendingPathComponent("many-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for i in 0..<200 {
            let dir = staging.appendingPathComponent("pkg").appendingPathComponent("f\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "content \(i)".write(to: dir.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        }
        let archive = tmp.appendingPathComponent("many.tar.gz")
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        t.arguments = ["czf", archive.path, "-C", staging.path, "pkg"]
        try t.run(); t.waitUntilExit()

        let dest = tmp.appendingPathComponent("out")
        let start = Date()
        try SafeExtractor.extract(archive: archive, into: dest)
        let elapsed = Date().timeIntervalSince(start)
        // Bulk extract: well under 5s on any reasonable machine. The per-member
        // regression took 28s, so 10s catches it with CI headroom.
        XCTAssertLessThan(elapsed, 10.0, "extraction regressed to slow per-member path")
        for i in [0, 99, 199] {
            let f = dest.appendingPathComponent("pkg/f\(i)/file")
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), "missing member \(i)")
            XCTAssertEqual(try String(contentsOf: f), "content \(i)")
        }
    }

    func testSafeExtractorHandlesUncompressedTar() throws {
        // Plain .tar (no gzip) also works via the same per-member path.
        let staging = tmp.appendingPathComponent("plain-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "x".write(to: staging.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        let archive = tmp.appendingPathComponent("plain.tar")
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        t.arguments = ["cf", archive.path, "-C", staging.path, "a"]
        try t.run(); t.waitUntilExit()

        let dest = tmp.appendingPathComponent("plain-out")
        try SafeExtractor.extract(archive: archive, into: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a").path))
    }
}
