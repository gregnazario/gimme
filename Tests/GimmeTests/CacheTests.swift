import XCTest
@testable import GimmeCore

final class CacheTests: XCTestCase {
    func makeCache() -> Cache {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Cache(directory: dir)
    }

    func testSetThenGet() {
        let cache = makeCache()
        cache.set("homebrew:list", value: ["rg", "fd"])
        let got: [String]? = cache.get("homebrew:list", ttlSeconds: 60, as: [String].self)
        XCTAssertEqual(got, ["rg", "fd"])
    }

    func testGetMissingReturnsNil() {
        let cache = makeCache()
        let got: String? = cache.get("nope", ttlSeconds: 60, as: String.self)
        XCTAssertNil(got)
    }

    func testExpiredReturnsNil() throws {
        let cache = makeCache()
        cache.set("k", value: "v")
        // Backdate the file's mtime by 100s, TTL 1s → expired.
        guard let file = cache.fileForTesting("k") else { return XCTFail("no file") }
        let old = Date().addingTimeInterval(-100)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let got: String? = cache.get("k", ttlSeconds: 1, as: String.self)
        XCTAssertNil(got)
    }

    func testInvalidate() {
        let cache = makeCache()
        cache.set("homebrew:list", value: [1])
        cache.set("cargo:list", value: [2])
        cache.invalidate("homebrew:list")
        XCTAssertNil(cache.get("homebrew:list", ttlSeconds: 60, as: [Int].self))
        XCTAssertEqual(cache.get("cargo:list", ttlSeconds: 60, as: [Int].self), [2])
    }

    func testInvalidatePrefix() {
        let cache = makeCache()
        cache.set("homebrew:list", value: 1)
        cache.set("homebrew:outdated", value: 2)
        cache.set("cargo:list", value: 3)
        cache.invalidatePrefix("homebrew:")
        XCTAssertNil(cache.get("homebrew:list", ttlSeconds: 60, as: Int.self))
        XCTAssertNil(cache.get("homebrew:outdated", ttlSeconds: 60, as: Int.self))
        XCTAssertEqual(cache.get("cargo:list", ttlSeconds: 60, as: Int.self), 3)
    }

    func testClear() {
        let cache = makeCache()
        cache.set("a", value: 1)
        cache.set("b", value: 2)
        cache.clear()
        XCTAssertNil(cache.get("a", ttlSeconds: 60, as: Int.self))
    }

    func testPersistsAcrossInstances() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = Cache(directory: dir)
        a.set("k", value: "v")
        let b = Cache(directory: dir)
        XCTAssertEqual(b.get("k", ttlSeconds: 60, as: String.self), "v")
    }

    func testGetAllowStaleReturnsExpiredValue() throws {
        let cache = makeCache()
        cache.set("k", value: "v")
        // Backdate the file's mtime by 100s, TTL 1s → expired.
        guard let file = cache.fileForTesting("k") else { return XCTFail("no file") }
        let old = Date().addingTimeInterval(-100)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        XCTAssertNil(cache.get("k", ttlSeconds: 1, as: String.self))
        // Stale-while-revalidate reads want the expired value back.
        XCTAssertEqual(cache.get("k", ttlSeconds: 1, as: String.self, allowStale: true), "v")
    }

    func testAgeOfKey() throws {
        let cache = makeCache()
        XCTAssertNil(cache.age(of: "missing"))
        cache.set("k", value: "v")
        let age = try XCTUnwrap(cache.age(of: "k"))
        XCTAssertLessThan(age, 5)
    }
}
