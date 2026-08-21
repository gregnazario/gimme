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

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                applicationDirs: [URL]? = nil,
                indexCache: Cache? = nil,
                masBinary: String? = nil) {
        self.http = http
        self.process = process
        self.applicationDirs = applicationDirs ?? [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        self.indexCache = indexCache
        self.masBinaryOverride = masBinary
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
    public func search(_ query: String) async throws -> [SearchHit] { [] }
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

    // outdated() and upgrade() are implemented in later plan tasks.
    public func outdated() async throws -> [OutdatedPackage] { [] }
    public func upgrade(_ package: PackageRef) async throws {
        throw GimmeError.notFoundInManagers(name: package.name, searched: [.appstore])
    }
}
