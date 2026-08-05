import XCTest
@testable import GimmeCore

final class DownloaderTests: XCTestCase {
    var paths: GimmePaths!
    var downloader: Downloader!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        downloader = Downloader(paths: paths)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.prefix)
        super.tearDown()
    }

    func testCacheHitReturnsExisting() throws {
        let payload = "hello world".data(using: .utf8)!
        let sha = Downloader.sha256(ofData: payload)
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try payload.write(to: src)

        let asset = Asset(url: URL(fileURLWithPath: src.path).absoluteString, sha256: sha)
        let first = try downloader.fetch(asset: asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

        // Second call should return the cached path without re-downloading.
        let second = try downloader.fetch(asset: asset)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, sha)
    }

    func testChecksumMismatchThrows() throws {
        let payload = "hello world".data(using: .utf8)!
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try payload.write(to: src)

        let asset = Asset(url: URL(fileURLWithPath: src.path).absoluteString, sha256: "deadbeef")
        XCTAssertThrowsError(try downloader.fetch(asset: asset)) { error in
            guard case GimmeError.checksumMismatch = error else {
                XCTFail("expected checksumMismatch, got \(error)"); return
            }
        }
    }

    func testInsecureBypass() throws {
        let payload = "hello world".data(using: .utf8)!
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try payload.write(to: src)

        let asset = Asset(url: URL(fileURLWithPath: src.path).absoluteString, sha256: "deadbeef")
        let result = try downloader.fetch(asset: asset, insecure: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
    }

    func testSHA256KnownVector() {
        // SHA256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let sha = Downloader.sha256(ofData: "abc".data(using: .utf8)!)
        XCTAssertEqual(sha, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// SECURITY: a poisoned cache entry (wrong contents under the sha256 name)
    /// must be detected on the next hit, evicted, and re-fetched — not trusted.
    func testCacheReVerifiesOnHit() throws {
        let realPayload = "the real asset".data(using: .utf8)!
        let realSha = Downloader.sha256(ofData: realPayload)
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try realPayload.write(to: src)

        // Pre-poison the cache: write garbage at the sha256-named path.
        let poisoned = paths.cache.appendingPathComponent(realSha)
        try FileManager.default.createDirectory(at: poisoned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "POISON".write(to: poisoned, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(Downloader.sha256(of: poisoned), realSha)

        // fetch should detect the mismatch, evict, and re-download from src.
        let asset = Asset(url: URL(fileURLWithPath: src.path).absoluteString, sha256: realSha)
        let result = try downloader.fetch(asset: asset)
        XCTAssertEqual(Downloader.sha256(of: result), realSha)  // now correct bytes
        let contents = try String(contentsOf: result)
        XCTAssertEqual(contents, "the real asset")  // not "POISON"
    }
}
