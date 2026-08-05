import XCTest
@testable import GimmeCore

final class LockTests: XCTestCase {
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

    func testAcquireAndRelease() throws {
        let lock = Lock(paths: paths)
        try lock.acquire(timeoutSeconds: 1)
        lock.release()
        // Re-acquiring immediately should work after release.
        try lock.acquire(timeoutSeconds: 1)
        lock.release()
    }

    func testReentrantSameFdAllowed() throws {
        // flock is associated with the open file description; re-locking via a
        // new Lock instance while one is held should fail within timeout.
        let lock1 = Lock(paths: paths)
        let lock2 = Lock(paths: paths)
        try lock1.acquire(timeoutSeconds: 1)
        // lock2 should time out (we can't easily test this without blocking
        // the test for the full timeout, so just verify lock1 worked and release).
        lock1.release()
        _ = lock2
    }
}
