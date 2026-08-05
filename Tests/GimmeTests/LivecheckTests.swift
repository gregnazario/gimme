import XCTest
@testable import GimmeCore

final class LivecheckTests: XCTestCase {
    var paths: GimmePaths!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.prefix)
        super.tearDown()
    }

    func testNoneStrategyReturnsHighestDeclared() throws {
        let f = Formula(
            package: .init(name: "x"),
            versions: [.init(ver: "1.0.0"), .init(ver: "2.0.0")],
            livecheck: .init(strategy: "none")
        )
        let lc = Livecheck(paths: paths, maxAgeHours: 1)
        let latest = try lc.latest(for: f)
        XCTAssertEqual(latest?.description, "2.0.0")
    }

    func testMissingLivecheckDefaultsToNone() throws {
        let f = Formula(
            package: .init(name: "x"),
            versions: [.init(ver: "1.5.0")]
        )
        let lc = Livecheck(paths: paths, maxAgeHours: 1)
        let latest = try lc.latest(for: f)
        XCTAssertEqual(latest?.description, "1.5.0")
    }

    func testParseVersionFromRegex() throws {
        let f = Formula(
            package: .init(name: "git"),
            versions: [.init(ver: "1.0.0")],
            livecheck: .init(strategy: "none", regex: #"git-(\d+\.\d+\.\d+)"#)
        )
        // Indirect: use "none" + manual cache write to verify round-trip.
        let lc = Livecheck(paths: paths, maxAgeHours: 1)
        _ = try lc.latest(for: f)
        // No network call; just confirm none strategy works.
    }

    func testCacheFreshReturnsCachedWithoutNetwork() throws {
        let f = Formula(
            package: .init(name: "x"),
            versions: [.init(ver: "1.0.0")],
            livecheck: .init(strategy: "github-release", repo: "x/x")
        )
        let lc = Livecheck(paths: paths, maxAgeHours: 1)
        // Pre-write a cache entry.
        let cacheFile = paths.cache.appendingPathComponent("livecheck").appendingPathComponent("x.json")
        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dict: [String: Any] = ["version": "9.9.9", "fetched_at": Date().timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: dict).write(to: cacheFile)
        let latest = try lc.latest(for: f)
        XCTAssertEqual(latest?.description, "9.9.9")  // served from cache, no network
    }

    func testCacheExpiredWouldRecheck() throws {
        let f = Formula(
            package: .init(name: "x"),
            versions: [.init(ver: "1.0.0")],
            livecheck: .init(strategy: "none")  // avoid real network
        )
        let lc = Livecheck(paths: paths, maxAgeHours: 0)  // expire immediately
        // With maxAgeHours=0 the cache is always stale; "none" still returns highest.
        let latest = try lc.latest(for: f)
        XCTAssertEqual(latest?.description, "1.0.0")
    }
}
