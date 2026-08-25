import Foundation

/// Mac App Store adapter (spec: docs/superpowers/specs/2026-08-21-appstore-updates-design.md).
/// Updates-only: list, outdated, upgrade. The read path never depends on the
/// `mas` CLI — installed apps are found by scanning .app bundles for an
/// _MASReceipt marker, and versions are compared against the public iTunes
/// Lookup API (no auth, `country=us`). `mas` is used opportunistically for the
/// write path; without it, upgrade opens the app's page in the App Store.
public final class AppStoreManager: PackageManager {
    public let id: ManagerID = .appstore
    public let displayName = "App Store"
    public let icon = "app.badge.fill"
    public let capabilities: Set<Capability> = [.list, .outdated, .upgrade]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let applicationDirs: [URL]
    private let indexCache: Cache?
    /// nil = resolve `mas` via PATH at use time; "" = force absent (tests).
    private let masBinaryOverride: String?
    /// Where the sudo askpass helper lives (injectable for tests; defaults to
    /// the gimme cache dir).
    private let askpassURL: URL?

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                applicationDirs: [URL]? = nil,
                indexCache: Cache? = nil,
                masBinary: String? = nil,
                askpassURL: URL? = nil) {
        self.http = http
        self.process = process
        self.applicationDirs = applicationDirs ?? [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        self.indexCache = indexCache
        self.masBinaryOverride = masBinary
        self.askpassURL = askpassURL ?? GimmePaths.defaultUser.cacheDir.appendingPathComponent("sudo-askpass.sh")
    }

    /// Requires only /Applications, which exists on every Mac — the adapter is
    /// always available; there is nothing to bootstrap.
    public func isAvailable() -> Bool { true }
    public func bootstrap() async throws {}

    // MARK: - Not advertised in capabilities (updates-only adapter)

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        throw GimmeError.operationFailed(manager: .appstore, op: "install",
            underlying: "App Store installs are not supported — use the App Store app")
    }
    public func uninstall(_ package: PackageRef) async throws {
        throw GimmeError.operationFailed(manager: .appstore, op: "uninstall",
            underlying: "App Store uninstalls are not supported — drag the app to the Trash")
    }

    /// Exact-existence only (the AquaManager pattern): the resolver validates
    /// manager hints via search(), and the GUI's Update button routes through
    /// it — without this, installed App Store apps never resolved. We don't
    /// advertise .search, so this never surfaces in Browse.
    public func search(_ query: String) async throws -> [SearchHit] {
        guard scanInstalledApps().contains(where: { $0.name == query || $0.bundleID == query }) else { return [] }
        return [SearchHit(name: query, manager: .appstore, summary: "Mac App Store app", latestVersion: "")]
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        throw GimmeError.notFoundInManagers(name: package.name, searched: [.appstore])
    }

    // MARK: - Receipt scan

    /// An installed Mac App Store app found by receipt scan.
    struct MASApp {
        let name: String       // human-facing display name ("Slack")
        let bundleID: String   // "com.tinyspeck.slackmacgap"
        let version: String    // CFBundleShortVersionString
    }

    /// Shallow scan of the application directories. A .app bundle is an App
    /// Store install iff it contains Contents/_MASReceipt/receipt; apps with an
    /// unreadable plist, a missing bundle ID or a missing version are skipped
    /// (never-false-flag bias). Duplicates across dirs: the first dir wins.
    func scanInstalledApps() -> [MASApp] {
        var apps: [MASApp] = []
        var seen = Set<String>()
        for dir in applicationDirs {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                let bundle = dir.appendingPathComponent(entry, isDirectory: true)
                guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/_MASReceipt/receipt").path) else { continue }
                guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
                      let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      let bundleID = dict["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
                      let version = dict["CFBundleShortVersionString"] as? String, !version.isEmpty
                else { continue }
                guard seen.insert(bundleID).inserted else { continue }
                let name = (dict["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (dict["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? String(entry.dropLast(4))
                apps.append(MASApp(name: name, bundleID: bundleID, version: version))
            }
        }
        return apps
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        scanInstalledApps().map {
            InstalledPackage(name: $0.name, version: $0.version, manager: .appstore, installedAt: nil)
        }
    }

    // MARK: - Update detection (iTunes Lookup API)

    /// iTunes Lookup response. Codable so the decoded struct itself is what the
    /// disk cache stores (key `appstore:lookup:<bundleID>`).
    struct LookupResponse: Codable {
        let resultCount: Int
        let results: [Result]
        struct Result: Codable {
            let trackId: Int
            let trackName: String?
            let version: String?
        }
    }

    private static let lookupTTL = 6 * 3600

    /// True when `installed` is strictly older than `latest`. See
    /// `DottedVersion.isOlder` — the shared dot-segment comparison.
    static func isOlder(_ installed: String, than latest: String) -> Bool {
        DottedVersion.isOlder(installed, than: latest)
    }

    /// Fetch (or serve from cache) the store record for a bundle ID. Returns
    /// nil on any failure — callers skip the app rather than flag it.
    func lookup(bundleID: String) async -> LookupResponse? {
        let key = "appstore:lookup:\(bundleID)"
        if let indexCache, let cached = indexCache.get(key, ttlSeconds: Self.lookupTTL, as: LookupResponse.self) {
            return cached
        }
        let url = "https://itunes.apple.com/lookup?bundleId=\(bundleID)&country=us"
        guard let resp: LookupResponse = try? await http.getJSON(url, as: LookupResponse.self) else { return nil }
        indexCache?.set(key, value: resp)
        return resp
    }

    public func outdated() async throws -> [OutdatedPackage] {
        await withTaskGroup(of: OutdatedPackage?.self) { group in
            for app in scanInstalledApps() {
                group.addTask {
                    guard let store = await self.lookup(bundleID: app.bundleID)?.results.first,
                          let latest = store.version, !latest.isEmpty,
                          Self.isOlder(app.version, than: latest) else { return nil }
                    return OutdatedPackage(name: app.name, installedVersion: app.version,
                                           latestVersion: latest, manager: .appstore)
                }
            }
            var out: [OutdatedPackage] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }

    // MARK: - Upgrade (hybrid mas / App Store page)

    /// sudo's stderr when it cannot prompt because there is no terminal — the
    /// mas failure signature that warrants an askpass retry.
    private static let sudoNoTTYSignature = "a terminal is required"

    /// updateAll calls upgrade() once per outdated app; without mas that would
    /// open the App Store N times. Skip further opens within this window —
    /// the store (or its updates pane) is already up.
    private static let openCoalesceInterval: TimeInterval = 10
    private let stateLock = NSLock()
    nonisolated(unsafe) private var lastOpenedAppStoreAt: Date?

    /// A bundle ID is dotted with no spaces ("com.tinyspeck.slackmacgap");
    /// display names never look like that ("Amazon Kindle").
    private func looksLikeBundleID(_ s: String) -> Bool {
        s.contains(".") && !s.contains(" ")
    }

    /// Resolve a package name (display name or bundle ID) to the app and its
    /// store track ID, or nil when it can't be found.
    private func resolveApp(_ name: String) async -> (app: MASApp, trackId: Int)? {
        let apps = scanInstalledApps()
        let app = looksLikeBundleID(name)
            ? apps.first { $0.bundleID == name }
            : apps.first { $0.name == name }
        guard let app,
              let store = await lookup(bundleID: app.bundleID)?.results.first,
              store.trackId > 0 else { return nil }
        return (app, store.trackId)
    }

    public func upgrade(_ package: PackageRef) async throws {
        guard let resolved = await resolveApp(package.name) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.appstore])
        }
        let trackId = resolved.trackId

        // Preferred path: mas drives the real upgrade. masBinaryOverride == ""
        // means "force absent" so tests are hermetic on machines that have mas.
        // mas 7 requires root and prompts via sudo — which fails with no TTY
        // (the GUI app), so a mas failure falls through to the page fallback
        // instead of erroring.
        let masPath: String?
        if masBinaryOverride == "" { masPath = nil }
        else { masPath = masBinaryOverride ?? BinaryResolver.resolve("mas") }
        var masError: String? = nil
        if let masPath {
            let res = try await process.run(masPath, args: ["upgrade", String(trackId)], env: nil, stream: nil)
            if res.exitCode == 0 { return }
            // mas 7 needs root; from a GUI launch sudo has no terminal to
            // prompt on. Retry with an askpass helper → native password
            // dialog → the update completes automatically (Homebrew's
            // pattern). Only for that failure signature — a "not signed in"
            // mas error goes straight to the page fallback instead.
            if res.stderr.contains(Self.sudoNoTTYSignature), let askpass = SudoAskpass.installHelper(at: askpassURL) {
                var env = ProcessRunner.augmentedEnvironment()
                env["SUDO_ASKPASS"] = askpass.path
                let retry = try await process.run(masPath, args: ["upgrade", String(trackId)], env: env, stream: nil)
                if retry.exitCode == 0 { return }
                masError = retry.stderr
            } else {
                masError = res.stderr
            }
        }

        // Fallback: land the App Store on the app's page; the user clicks
        // Update. Coalesced so Update-All opens the store at most once.
        let now = Date()
        stateLock.lock(); let last = lastOpenedAppStoreAt; stateLock.unlock()
        if let last, now.timeIntervalSince(last) < Self.openCoalesceInterval { return }
        stateLock.lock(); lastOpenedAppStoreAt = now; stateLock.unlock()
        let res = try await process.run("/usr/bin/open",
            args: ["macappstore://apps.apple.com/app/id\(trackId)"], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            let detail = masError.map { "mas: \($0)" } ?? res.stderr
            throw GimmeError.operationFailed(manager: .appstore, op: "upgrade", underlying: detail)
        }
    }

    /// Update All: batch every app into ONE mas invocation. sudo's timestamp
    /// is per-process without a TTY, so one invocation per app would show the
    /// password dialog once per app. On mas failure (after the single askpass
    /// retry) the batch falls back to opening the App Store updates pane once
    /// and reports the packages as handed off.
    public func upgradeAll(_ packages: [PackageRef],
                           onPackageStart: ((PackageRef) -> Void)? = nil) async -> [(PackageRef, Error?)] {
        for package in packages { onPackageStart?(package) }
        var resolved: [(PackageRef, Int)] = []
        var results: [(PackageRef, Error?)] = []
        for package in packages {
            if let r = await resolveApp(package.name) {
                resolved.append((package, r.trackId))
            } else {
                results.append((package,
                    GimmeError.notFoundInManagers(name: package.name, searched: [.appstore])))
            }
        }
        guard !resolved.isEmpty else { return results }

        let masPath: String?
        if masBinaryOverride == "" { masPath = nil }
        else { masPath = masBinaryOverride ?? BinaryResolver.resolve("mas") }
        if let masPath {
            let args = ["upgrade"] + resolved.map { String($0.1) }
            var res = try? await process.run(masPath, args: args, env: nil, stream: nil)
            if res?.exitCode != 0, res?.stderr.contains(Self.sudoNoTTYSignature) == true,
               let askpass = SudoAskpass.installHelper(at: askpassURL) {
                // One askpass retry for the whole batch — one dialog.
                var env = ProcessRunner.augmentedEnvironment()
                env["SUDO_ASKPASS"] = askpass.path
                res = try? await process.run(masPath, args: args, env: env, stream: nil)
            }
            if res?.exitCode == 0 {
                return results + resolved.map { ($0.0, nil) }
            }
        }

        // Fallback: the updates pane once; the user clicks Update All there.
        _ = try? await process.run("/usr/bin/open", args: ["macappstore://showUpdates"], env: nil, stream: nil)
        return results + resolved.map { ($0.0, nil) }
    }
}
