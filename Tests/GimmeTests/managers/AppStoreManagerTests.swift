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
    class StubProcess: ProcessRunning {
        var calls: [(String, [String])] = []
        var envs: [[String: String]?] = []
        func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
            calls.append((e, args))
            envs.append(env)
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

    // MARK: - version comparison

    func testIsOlderNumericSegments() {
        XCTAssertTrue(AppStoreManager.isOlder("4.51.180", than: "4.51.191"))
        XCTAssertFalse(AppStoreManager.isOlder("4.51.191", than: "4.51.180"))
        XCTAssertTrue(AppStoreManager.isOlder("16.4", than: "16.10"))   // numeric, not lexical
        XCTAssertFalse(AppStoreManager.isOlder("1.0", than: "1.0.0"))   // padded equal
        XCTAssertFalse(AppStoreManager.isOlder("2.0", than: "2.0"))
        XCTAssertTrue(AppStoreManager.isOlder("1.2b3", than: "1.2b4"))  // non-numeric falls back to lexical
    }

    // MARK: - outdated

    private func stubLookup(_ http: StubHTTP, _ bundleID: String, version: String?, trackId: Int = 123) {
        let json: String
        if let version {
            json = #"{"resultCount":1,"results":[{"trackId":\#(trackId),"trackName":"T","version":"\#(version)"}]}"#
        } else {
            json = #"{"resultCount":0,"results":[]}"#
        }
        http.byURL["https://itunes.apple.com/lookup?bundleId=\(bundleID)&country=us"] = Data(json.utf8)
    }

    func testOutdatedFlagsOnlyOlderApps() async throws {
        try makeApp(tmp, "Old.app", bundleID: "com.old.app", version: "1.0.0")
        try makeApp(tmp, "New.app", bundleID: "com.new.app", version: "2.0.0")
        try makeApp(tmp, "Gone.app", bundleID: "com.gone.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.old.app", version: "1.5.0")
        stubLookup(http, "com.new.app", version: "2.0.0")
        stubLookup(http, "com.gone.app", version: nil)  // resultCount 0: pulled from store
        let out = try await manager(http).outdated()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.name, "Old")
        XCTAssertEqual(out.first?.installedVersion, "1.0.0")
        XCTAssertEqual(out.first?.latestVersion, "1.5.0")
        XCTAssertEqual(out.first?.manager, .appstore)
    }

    func testOutdatedSkipsUnresolvableLookups() async throws {
        // Empty stub body → decode failure → skipped, never flagged.
        try makeApp(tmp, "Flaky.app", bundleID: "com.flaky.app", version: "1.0.0")
        let out = try await manager(StubHTTP()).outdated()
        XCTAssertEqual(out, [])
    }

    func testOutdatedServedFromCacheWithinTTL() async throws {
        try makeApp(tmp, "Cached.app", bundleID: "com.cached.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.cached.app", version: "2.0.0")
        let cache = Cache(directory: tmp.appendingPathComponent("cache"))
        let m = AppStoreManager(http: http, process: StubProcess(), applicationDirs: [tmp],
                                indexCache: cache, masBinary: "")
        _ = try await m.outdated()
        let http2 = StubHTTP()  // no stubs: a network read would decode Data() → skip → empty
        let m2 = AppStoreManager(http: http2, process: StubProcess(), applicationDirs: [tmp],
                                 indexCache: cache, masBinary: "")
        let out = try await m2.outdated()
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(http2.requests, [])
    }

    func testOutdatedForceRefreshBypassesLookupCache() async throws {
        try makeApp(tmp, "Cached.app", bundleID: "com.cached.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.cached.app", version: "2.0.0")
        let cache = Cache(directory: tmp.appendingPathComponent("cache2"))
        let m = AppStoreManager(http: http, process: StubProcess(), applicationDirs: [tmp],
                                indexCache: cache, masBinary: "")
        _ = try await m.outdated()  // caches the 2.0.0 lookup
        let http2 = StubHTTP()
        stubLookup(http2, "com.cached.app", version: "2.1.0")
        let m2 = AppStoreManager(http: http2, process: StubProcess(), applicationDirs: [tmp],
                                 indexCache: cache, masBinary: "")
        // Normal pass: cached store version still served.
        let cached = try await m2.outdated()
        XCTAssertEqual(cached.first?.latestVersion, "2.0.0")
        // Force pass: re-asks the iTunes Lookup API.
        let forced = try await m2.outdated(forceRefresh: true)
        XCTAssertEqual(forced.first?.latestVersion, "2.1.0")
    }

    // MARK: - upgrade

    func testUpgradeRunsMasWhenPresent() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        let http = StubHTTP()
        stubLookup(http, "com.tinyspeck.slackmacgap", version: "4.51.191", trackId: 803453959)
        let p = StubProcess()
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp], masBinary: "/tmp/mas-stub")
        try await m.upgrade(PackageRef(name: "Slack"))
        XCTAssertTrue(p.calls.contains { $0.0 == "/tmp/mas-stub" && $0.1 == ["upgrade", "803453959"] })
    }

    func testUpgradeAcceptsBundleID() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        let http = StubHTTP()
        stubLookup(http, "com.tinyspeck.slackmacgap", version: "4.51.191", trackId: 803453959)
        let p = StubProcess()
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp], masBinary: "/tmp/mas-stub")
        try await m.upgrade(PackageRef(name: "com.tinyspeck.slackmacgap"))
        XCTAssertTrue(p.calls.contains { $0.0 == "/tmp/mas-stub" && $0.1 == ["upgrade", "803453959"] })
    }

    func testUpgradeOpensAppStorePageWhenMasAbsent() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        let http = StubHTTP()
        stubLookup(http, "com.tinyspeck.slackmacgap", version: "4.51.191", trackId: 803453959)
        let p = StubProcess()
        let m = manager(http, p)  // masBinary "" forces the fallback path
        try await m.upgrade(PackageRef(name: "Slack"))
        XCTAssertTrue(p.calls.contains { $0.0 == "/usr/bin/open" && $0.1 == ["macappstore://apps.apple.com/app/id803453959"] })
    }

    func testUpgradeCoalescesRepeatedOpens() async throws {
        try makeApp(tmp, "One.app", bundleID: "com.one.app", version: "1.0.0")
        try makeApp(tmp, "Two.app", bundleID: "com.two.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.one.app", version: "2.0.0", trackId: 111)
        stubLookup(http, "com.two.app", version: "2.0.0", trackId: 222)
        let p = StubProcess()
        let m = manager(http, p)
        try await m.upgrade(PackageRef(name: "One"))
        try await m.upgrade(PackageRef(name: "Two"))  // within the 10 s window → skipped
        let opens = p.calls.filter { $0.0 == "/usr/bin/open" }
        XCTAssertEqual(opens.count, 1)
        XCTAssertEqual(opens.first?.1.first, "macappstore://apps.apple.com/app/id111")
    }

    func testUpgradeThrowsForUnknownApp() async {
        let m = manager()
        do {
            try await m.upgrade(PackageRef(name: "Nope"))
            XCTFail("expected notFoundInManagers")
        } catch { }
    }

    // MARK: - search (resolver existence probe)

    /// The GUI Update button routes through Gimme.upgrade(name:from:) →
    /// Resolver, which validates the hint via search(). Without an
    /// installed-list search, every App Store upgrade failed with
    /// "appstore has no package …" before reaching the adapter.
    func testSearchMatchesInstalledAppsExactly() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        try makeApp(tmp, "Chrome.app", bundleID: "com.google.Chrome", version: "138.0.0", mas: false)
        let m = manager()
        let byName = try await m.search("Slack")
        XCTAssertEqual(byName.count, 1)
        XCTAssertEqual(byName.first?.manager, .appstore)
        XCTAssertEqual(byName.first?.latestVersion, "")  // AquaManager contract: existence probe only
        let byBundleID = try await m.search("com.tinyspeck.slackmacgap")
        XCTAssertEqual(byBundleID.count, 1)
        let miss = try await m.search("Nope")
        XCTAssertEqual(miss, [])
        let nonMAS = try await m.search("Chrome")   // installed but not from the store
        XCTAssertEqual(nonMAS, [])
    }

    /// The exact GUI path: Gimme.upgrade(name: "Slack", from: .appstore) must
    /// reach the adapter and open the App Store page (mas absent).
    func testEngineUpgradeWithHintReachesAdapter() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        let http = StubHTTP()
        stubLookup(http, "com.tinyspeck.slackmacgap", version: "4.51.191", trackId: 803453959)
        let p = StubProcess()
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp],
                                indexCache: nil, masBinary: "")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gimme = Gimme(registry: Registry(managers: [m]),
                          preferences: Preferences(),
                          config: .defaults,
                          cache: Cache(directory: home.appendingPathComponent("cache")),
                          preferencesFile: home.appendingPathComponent("prefs.json"))
        try await gimme.upgrade(name: "Slack", from: .appstore)
        XCTAssertTrue(p.calls.contains { $0.0 == "/usr/bin/open" && $0.1 == ["macappstore://apps.apple.com/app/id803453959"] })
    }

    /// mas 7 "Requires root privileges to update apps" — in the GUI there is
    /// no TTY, so `sudo` inside mas fails ("a terminal is required"). A mas
    /// failure must fall back to opening the app's App Store page rather than
    /// surfacing an error the user can't act on.
    func testUpgradeFallsBackToAppStorePageWhenMasFails() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        let http = StubHTTP()
        stubLookup(http, "com.tinyspeck.slackmacgap", version: "4.51.191", trackId: 803453959)
        final class FailingMasProcess: StubProcess {
            override func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
                let r = try await super.run(e, args: args, env: env, stream: stream)
                if e == "/tmp/mas-stub" {
                    return ProcessResult(exitCode: 1, stdout: "",
                        stderr: "sudo: a terminal is required to read the password")
                }
                return r
            }
        }
        let p = FailingMasProcess()
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp], masBinary: "/tmp/mas-stub")
        try await m.upgrade(PackageRef(name: "Slack"))
        XCTAssertTrue(p.calls.contains { $0.0 == "/tmp/mas-stub" && $0.1 == ["upgrade", "803453959"] },
                      "mas must be attempted first")
        XCTAssertTrue(p.calls.contains { $0.0 == "/usr/bin/open" && $0.1 == ["macappstore://apps.apple.com/app/id803453959"] },
                      "fallback must open the app's App Store page")
    }

    /// When mas fails only because sudo has no terminal (GUI launch), gimme
    /// retries with a SUDO_ASKPASS helper (the Homebrew pattern) so the user
    /// gets a native password dialog and the update runs automatically.
    func testUpgradeRetriesMasWithAskpassOnNoTtySudo() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        let http = StubHTTP()
        stubLookup(http, "com.tinyspeck.slackmacgap", version: "4.51.191", trackId: 803453959)
        final class AskpassAwareMas: StubProcess {
            override func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
                let r = try await super.run(e, args: args, env: env, stream: stream)
                if e == "/tmp/mas-stub" {
                    if env?["SUDO_ASKPASS"] != nil { return ProcessResult(exitCode: 0, stdout: "", stderr: "") }
                    return ProcessResult(exitCode: 1, stdout: "",
                        stderr: "sudo: a terminal is required to read the password\nsudo: a password is required")
                }
                return r
            }
        }
        let p = AskpassAwareMas()
        let askpass = tmp.appendingPathComponent("askpass/sudo-askpass.sh")
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp],
                                masBinary: "/tmp/mas-stub", askpassURL: askpass)
        try await m.upgrade(PackageRef(name: "Slack"))
        let masCalls = p.calls.filter { $0.0 == "/tmp/mas-stub" }
        XCTAssertEqual(masCalls.count, 2, "plain attempt, then askpass retry")
        XCTAssertEqual(p.envs.last??["SUDO_ASKPASS"], askpass.path)
        XCTAssertFalse(p.calls.contains { $0.0 == "/usr/bin/open" }, "no page fallback — fully automatic")
        // The helper shows the native password dialog via osascript and is
        // private to the user.
        let script = try String(contentsOf: askpass, encoding: .utf8)
        XCTAssertTrue(script.contains("osascript"))
        XCTAssertTrue(script.contains("with hidden answer"))
        let perms = try FileManager.default.attributesOfItem(atPath: askpass.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
    }

    /// Failures that aren't the sudo/no-TTY signature (e.g. "not signed in")
    /// must not trigger a password dialog — straight to the page fallback.
    func testUpgradeDoesNotAskpassOnOtherMasFailures() async throws {
        try makeApp(tmp, "Slack.app", bundleID: "com.tinyspeck.slackmacgap", version: "4.51.180")
        let http = StubHTTP()
        stubLookup(http, "com.tinyspeck.slackmacgap", version: "4.51.191", trackId: 803453959)
        final class NotSignedInMas: StubProcess {
            override func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
                let r = try await super.run(e, args: args, env: env, stream: stream)
                if e == "/tmp/mas-stub" {
                    return ProcessResult(exitCode: 1, stdout: "", stderr: "Error: Not signed in")
                }
                return r
            }
        }
        let p = NotSignedInMas()
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp], masBinary: "/tmp/mas-stub")
        try await m.upgrade(PackageRef(name: "Slack"))
        XCTAssertEqual(p.calls.filter { $0.0 == "/tmp/mas-stub" }.count, 1, "no askpass retry")
        XCTAssertTrue(p.calls.contains { $0.0 == "/usr/bin/open" }, "page fallback used")
    }

    // MARK: - upgradeAll (one sudo prompt per run, not per app)

    /// Update All must batch every App Store app into ONE mas invocation —
    /// sudo's timestamp is per-process without a TTY, so N invocations means
    /// N password dialogs.
    func testUpgradeAllBatchesMasIntoOneInvocation() async throws {
        try makeApp(tmp, "One.app", bundleID: "com.one.app", version: "1.0.0")
        try makeApp(tmp, "Two.app", bundleID: "com.two.app", version: "1.0.0")
        try makeApp(tmp, "Three.app", bundleID: "com.three.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.one.app", version: "2.0.0", trackId: 111)
        stubLookup(http, "com.two.app", version: "2.0.0", trackId: 222)
        stubLookup(http, "com.three.app", version: "2.0.0", trackId: 333)
        let p = StubProcess()
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp], masBinary: "/tmp/mas-stub")
        let refs = ["One", "Two", "Three"].map { PackageRef(name: $0) }
        let results = await m.upgradeAll(refs)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.1 == nil })
        let masCalls = p.calls.filter { $0.0 == "/tmp/mas-stub" }
        XCTAssertEqual(masCalls.count, 1, "one mas invocation for the whole batch")
        XCTAssertEqual(masCalls.first?.1, ["upgrade", "111", "222", "333"])
        XCTAssertFalse(p.calls.contains { $0.0 == "/usr/bin/open" })
    }

    /// The batch's askpass retry also happens once — one password dialog for
    /// the whole run even after the no-TTY first attempt fails.
    func testUpgradeAllAskpassRetriesOnce() async throws {
        try makeApp(tmp, "One.app", bundleID: "com.one.app", version: "1.0.0")
        try makeApp(tmp, "Two.app", bundleID: "com.two.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.one.app", version: "2.0.0", trackId: 111)
        stubLookup(http, "com.two.app", version: "2.0.0", trackId: 222)
        final class AskpassAwareMas: StubProcess {
            override func run(_ e: String, args: [String], env: [String: String]?, stream: ((String) -> Void)?) async throws -> ProcessResult {
                let r = try await super.run(e, args: args, env: env, stream: stream)
                if e == "/tmp/mas-stub" {
                    if env?["SUDO_ASKPASS"] != nil { return ProcessResult(exitCode: 0, stdout: "", stderr: "") }
                    return ProcessResult(exitCode: 1, stdout: "",
                        stderr: "sudo: a terminal is required to read the password")
                }
                return r
            }
        }
        let p = AskpassAwareMas()
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp], masBinary: "/tmp/mas-stub")
        let results = await m.upgradeAll(["One", "Two"].map { PackageRef(name: $0) })
        XCTAssertTrue(results.allSatisfy { $0.1 == nil })
        XCTAssertEqual(p.calls.filter { $0.0 == "/tmp/mas-stub" }.count, 2, "plain attempt, then one askpass retry for the batch")
        XCTAssertFalse(p.calls.contains { $0.0 == "/usr/bin/open" })
    }

    /// Without mas, the batch opens the App Store updates PANE once (not a
    /// page per app) and reports the packages as handed off.
    func testUpgradeAllOpensUpdatesPaneWhenMasAbsent() async throws {
        try makeApp(tmp, "One.app", bundleID: "com.one.app", version: "1.0.0")
        try makeApp(tmp, "Two.app", bundleID: "com.two.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.one.app", version: "2.0.0", trackId: 111)
        stubLookup(http, "com.two.app", version: "2.0.0", trackId: 222)
        let p = StubProcess()
        let m = manager(http, p)
        let results = await m.upgradeAll(["One", "Two"].map { PackageRef(name: $0) })
        XCTAssertTrue(results.allSatisfy { $0.1 == nil })
        XCTAssertEqual(p.calls.filter { $0.0 == "/usr/bin/open" }.count, 1)
        XCTAssertEqual(p.calls.first { $0.0 == "/usr/bin/open" }?.1, ["macappstore://showUpdates"])
    }

    /// Unresolvable names in the batch surface per-package errors without
    /// sinking the rest.
    func testUpgradeAllReportsUnknownNames() async {
        let m = manager()
        let results = await m.upgradeAll(["Nope", "Also Nope"].map { PackageRef(name: $0) })
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.1 != nil })
    }

    /// The full Update All path: engine → adapter → ONE mas invocation for
    /// every outdated App Store app → one sudo password dialog.
    func testEngineUpdateAllBatchesAppStoreIntoOneMasCall() async throws {
        try makeApp(tmp, "One.app", bundleID: "com.one.app", version: "1.0.0")
        try makeApp(tmp, "Two.app", bundleID: "com.two.app", version: "1.0.0")
        let http = StubHTTP()
        stubLookup(http, "com.one.app", version: "2.0.0", trackId: 111)
        stubLookup(http, "com.two.app", version: "2.0.0", trackId: 222)
        let p = StubProcess()
        let m = AppStoreManager(http: http, process: p, applicationDirs: [tmp], masBinary: "/tmp/mas-stub")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gimme = Gimme(registry: Registry(managers: [m]),
                          preferences: Preferences(),
                          config: .defaults,
                          cache: Cache(directory: home.appendingPathComponent("cache")),
                          preferencesFile: home.appendingPathComponent("prefs.json"))
        let summary = try await gimme.updateAll()
        XCTAssertEqual(summary.succeeded.sorted(), ["appstore:One", "appstore:Two"])
        let masCalls = p.calls.filter { $0.0 == "/tmp/mas-stub" }
        XCTAssertEqual(masCalls.count, 1)
        // outdated() returns TaskGroup completion order — assert the set, not sequence.
        let args = masCalls.first?.1 ?? []
        XCTAssertEqual(args.first, "upgrade")
        XCTAssertEqual(Set(args.dropFirst()), ["111", "222"])
    }
}
