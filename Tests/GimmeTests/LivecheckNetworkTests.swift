import XCTest
@testable import GimmeCore

/// Livecheck network tests: spin up a local HTTP server, point url-match and
/// (simulated) github-release at it, exercise the cache write path.
final class LivecheckNetworkTests: XCTestCase {
    var tmp: URL!
    var serverDir: URL!
    var serverProc: Process?
    var port: Int = 0

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        serverProc?.terminate()
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// Start a python http.server on a random free port serving serverDir.
    private func startServer(serving dir: URL) throws -> Int {
        serverDir = dir
        // Find a free port.
        let portTask = Process()
        portTask.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        portTask.arguments = ["-c", "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()"]
        let pipe = Pipe(); portTask.standardOutput = pipe
        try portTask.run(); portTask.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        port = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(port, 0)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-m", "http.server", String(port), "--directory", dir.path]
        try p.run()
        serverProc = p
        // Give the server a moment to bind.
        Thread.sleep(forTimeInterval: 0.5)
        return port
    }

    func testURLMatchStrategyOverHTTP() throws {
        let dir = tmp.appendingPathComponent("serve")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "releases: foo-1.2.3 foo-1.2.4".write(
            to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let port = try startServer(serving: dir)

        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        let lc = Livecheck(paths: paths, maxAgeHours: 1)

        let f = Formula(
            package: .init(name: "foo"),
            versions: [.init(ver: "1.0.0")],
            livecheck: .init(strategy: "url-match",
                             url: "http://127.0.0.1:\(port)/index.html",
                             regex: #"foo-(\d+\.\d+\.\d+)"#)
        )
        let latest = try lc.latest(for: f)
        XCTAssertEqual(latest?.description, "1.2.3")

        // Cache file should now exist with the discovered version.
        let cacheFile = paths.cache.appendingPathComponent("livecheck").appendingPathComponent("foo.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))

        // Second call should be served from cache.
        let cached = try lc.latest(for: f)
        XCTAssertEqual(cached?.description, "1.2.3")
    }

    func testURLMatchInvalidURLThrows() throws {
        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        let lc = Livecheck(paths: paths, maxAgeHours: 1)
        let f = Formula(
            package: .init(name: "bad"),
            versions: [.init(ver: "1.0.0")],
            livecheck: .init(strategy: "url-match", url: "not-a-url", regex: nil)
        )
        XCTAssertThrowsError(try lc.latest(for: f)) { error in
            guard case GimmeError.network = error else { XCTFail("got \(error)"); return }
        }
    }

    func testUnknownStrategyFallsBackToHighest() throws {
        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        let lc = Livecheck(paths: paths, maxAgeHours: 1)
        let f = Formula(
            package: .init(name: "x"),
            versions: [.init(ver: "1.0.0"), .init(ver: "2.0.0")],
            livecheck: .init(strategy: "exotic-strategy")
        )
        XCTAssertEqual(try lc.latest(for: f)?.description, "2.0.0")
    }

    func testLuaStrategyReturnsNil() throws {
        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        let lc = Livecheck(paths: paths, maxAgeHours: 1)
        let f = Formula(
            package: .init(name: "x"),
            versions: [.init(ver: "1.0.0")],
            livecheck: .init(strategy: "lua")
        )
        XCTAssertNil(try lc.latest(for: f))
    }

    func testGitHubReleaseMissingRepoReturnsNil() throws {
        let paths = GimmePaths(prefix: tmp)
        try paths.ensureDirectories()
        let lc = Livecheck(paths: paths, maxAgeHours: 1)
        let f = Formula(
            package: .init(name: "x"),
            versions: [.init(ver: "1.0.0")],
            livecheck: .init(strategy: "github-release", repo: nil, regex: nil)
        )
        XCTAssertNil(try lc.latest(for: f))
    }
}
