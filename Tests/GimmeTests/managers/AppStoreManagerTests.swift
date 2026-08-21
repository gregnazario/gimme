import XCTest
@testable import GimmeCore

final class AppStoreManagerTests: XCTestCase {
    final class StubHTTP: HTTPClient {
        var byURL: [String: Data] = [:]
        var requests: [String] = []
        func data(for url: URL) async throws -> Data {
            requests.append(url.absoluteString)
            return byURL[url.absoluteString] ?? Data()
        }
    }
    final class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("appstore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Create a fake .app bundle in a temp "Applications" dir.
    @discardableResult
    func makeApp(_ dir: URL, _ bundleFile: String, bundleID: String, version: String,
                 name: String? = nil, mas: Bool = true) throws -> URL {
        let app = dir.appendingPathComponent(bundleFile)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if mas {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/_MASReceipt"),
                                                    withIntermediateDirectories: true)
            try Data([0x00]).write(to: app.appendingPathComponent("Contents/_MASReceipt/receipt"))
        }
        let info = contents.appendingPathComponent("Info.plist")
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundleDisplayName": name ?? bundleFile.replacingOccurrences(of: ".app", with: ""),
        ]
        try (plist as NSDictionary).write(to: info, atomically: true)
        return app
    }

    /// masBinary "" forces the no-mas fallback so tests are hermetic on
    /// machines that do have mas installed.
    func manager(_ http: HTTPClient? = nil, _ p: StubProcess? = nil) -> AppStoreManager {
        AppStoreManager(http: http ?? StubHTTP(), process: p ?? StubProcess(),
                        applicationDirs: [tmp], masBinary: "")
    }

    func testIDAndCapabilities() {
        let m = manager()
        XCTAssertEqual(m.id, .appstore)
        XCTAssertEqual(m.displayName, "App Store")
        XCTAssertEqual(m.capabilities, [.list, .outdated, .upgrade])
        XCTAssertTrue(m.isAvailable())
    }

    func testListFindsOnlyMASReceiptApps() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        try makeApp(tmp, "Chrome.app", bundleID: "com.google.Chrome", version: "138.0.0", mas: false)
        let pkgs = try await manager().listInstalled()
        XCTAssertEqual(pkgs.count, 1)
        XCTAssertEqual(pkgs.first?.name, "Slack")
        XCTAssertEqual(pkgs.first?.version, "4.51.180")
        XCTAssertEqual(pkgs.first?.manager, .appstore)
        XCTAssertNil(pkgs.first?.installedAt)
    }

    func testListSkipsAppsMissingVersionOrBundleID() async throws {
        // Hand-write a receipt app whose plist lacks CFBundleIdentifier.
        let app = tmp.appendingPathComponent("Broken.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/_MASReceipt"),
                                                withIntermediateDirectories: true)
        try Data([0x00]).write(to: app.appendingPathComponent("Contents/_MASReceipt/receipt"))
        try (["CFBundleShortVersionString": "1.0"] as NSDictionary)
            .write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try makeApp(tmp, "Good.app", bundleID: "com.good.app", version: "2.0")
        let pkgs = try await manager().listInstalled()
        XCTAssertEqual(pkgs.map(\.name), ["Good"])
    }

    func testListDedupesAcrossDirsFirstDirWins() async throws {
        let dir2 = tmp.appendingPathComponent("home-apps")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try makeApp(tmp, "One.app", bundleID: "com.one.app", version: "1.0")
        try makeApp(dir2, "One.app", bundleID: "com.one.app", version: "9.9")
        try makeApp(dir2, "Two.app", bundleID: "com.two.app", version: "2.0")
        let m = AppStoreManager(http: StubHTTP(), process: StubProcess(),
                                applicationDirs: [tmp, dir2], masBinary: "")
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs.count, 2)
        XCTAssertTrue(pkgs.contains { $0.name == "One" && $0.version == "1.0" })
    }

    func testListHandlesMissingDirectory() async throws {
        let m = AppStoreManager(http: StubHTTP(), process: StubProcess(),
                                applicationDirs: [tmp.appendingPathComponent("nope")], masBinary: "")
        let pkgs = try await m.listInstalled()
        XCTAssertEqual(pkgs, [])
    }
}
