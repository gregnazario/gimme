import Foundation

/// RubyGems adapter. Uses the rubygems.org API for search/info and the `gem`
/// CLI for actions + list. Globals are the default install scope for gems.
public final class GemManager: PackageManager {
    public let id: ManagerID = .gem
    public let displayName = "RubyGems"
    public let icon = "diamond.fill"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let binaryOverride: String?   // nil = resolve via `which gem`
    /// Shared disk cache for per-package latest-version lookups (App Store
    /// pattern: one lookup per package per TTL window instead of per run).
    /// nil = off.
    private let indexCache: Cache?
    private static let latestTTLSeconds = 3600

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                binary: String? = nil,
                indexCache: Cache? = nil) {
        self.http = http
        self.process = process
        self.binaryOverride = binary
        self.indexCache = indexCache
    }

    private var binaryPath: String {
        binaryOverride ?? BinaryResolver.resolve("gem", fallback: nil) ?? ""
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("gem") != nil || binaryOverride != nil
    }

    public func bootstrap() async throws {
        // RubyGems ships with Ruby; install via mise/brew ruby.
        _ = try await process.run("/bin/bash",
            args: ["-c", "command -v mise >/dev/null && mise install ruby@latest || brew install ruby"],
            env: nil, stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Search / Info (rubygems.org API)

    private struct GemSearchHit: Decodable {
        let name: String
        let version: String
        let info: String?
        let project_uri: String?
        let homepage_uri: String?
        let licenses: [String]?
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        let url = "https://rubygems.org/api/v1/search.json?query=\(query)"
        guard let docs: [GemSearchHit] = try? await http.getJSON(url, as: [GemSearchHit].self) else { return [] }
        return docs.map { SearchHit(name: $0.name, manager: .gem, summary: $0.info ?? "", latestVersion: $0.version) }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: GemSearchHit = try? await http.getJSON("https://rubygems.org/api/v1/gems/\(package.name).json", as: GemSearchHit.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.gem])
        }
        return PackageInfo(name: doc.name, manager: .gem, latestVersion: doc.version,
            summary: doc.info ?? "", homepage: doc.homepage_uri ?? doc.project_uri,
            license: doc.licenses?.first, installedVersion: nil, location: nil)
    }

    // MARK: - Actions (gem CLI)

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        var args = ["install", package.name]
        if let v = options.version { args += ["--version", v] }
        let res = try await process.run(binaryPath, args: args, env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .gem, op: "install", underlying: res.stderr) }
        listMemo.clear()
        return InstallResult(package: InstalledPackage(name: package.name, version: options.version ?? "latest", manager: .gem, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        // -x: ignore dependencies, -a: uninstall all versions.
        let res = try await process.run(binaryPath, args: ["uninstall", "-x", "-a", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .gem, op: "uninstall", underlying: res.stderr) }
        listMemo.clear()
    }

    public func upgrade(_ package: PackageRef) async throws {
        // No separate upgrade; reinstall the latest.
        let res = try await process.run(binaryPath, args: ["install", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .gem, op: "upgrade", underlying: res.stderr) }
        listMemo.clear()
    }

    /// Memoized so concurrent engine `list` + `outdated` calls spawn `gem list`
    /// once instead of twice. Mutating ops clear it.
    private let listMemo = InProcessMemo<[InstalledPackage]>(ttl: 5)

    public func listInstalled() async throws -> [InstalledPackage] {
        if let memoized = listMemo.get() { return memoized }
        let pkgs = try await runListInstalled()
        listMemo.set(pkgs)
        return pkgs
    }

    private func runListInstalled() async throws -> [InstalledPackage] {
        // `gem list` -> "name (v1, v2)" lines, plus header lines like
        // "*** Local Gems ***". Take the first version listed per gem.
        let res = try await process.run(binaryPath, args: ["list"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        return res.stdout.split(separator: "\n").compactMap { line -> InstalledPackage? in
            let s = String(line)
            // Match: "name (version[, version]...)" with non-indented name.
            guard let paren = s.firstIndex(of: "("),
                  let close = s[paren...].firstIndex(of: ")"),
                  paren > s.startIndex else { return nil }
            let name = String(s[..<paren]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "***" else { return nil }
            let versionsBlob = String(s[s.index(after: paren)..<close])
            // Platform-specific gems append the platform to each version
            // ("1.17.4 arm64-darwin"); keep just the version so comparisons
            // against rubygems.org's plain versions match.
            let firstVersion = versionsBlob.split(separator: ",").first?
                .split(whereSeparator: \.isWhitespace).first
                .map(String.init)
            guard let version = firstVersion, !version.isEmpty else { return nil }
            return InstalledPackage(name: name, version: version, manager: .gem, installedAt: nil)
        }
    }

    /// Latest rubygems.org version of a gem, cached per package (1 h) so a
    /// 100+-gem machine doesn't re-hit the API on every expired run.
    /// forceRefresh bypasses the cache read (and overwrites the entry).
    /// Returns nil on any failure; callers skip the gem rather than flag it.
    private func latestVersion(of name: String, forceRefresh: Bool = false) async -> String? {
        let key = "\(id.rawValue):latest:\(name)"
        if !forceRefresh,
           let indexCache, let cached = indexCache.get(key, ttlSeconds: Self.latestTTLSeconds, as: String.self) {
            return cached
        }
        guard let doc: GemSearchHit = try? await http.getJSON("https://rubygems.org/api/v1/gems/\(name).json", as: GemSearchHit.self) else { return nil }
        indexCache?.set(key, value: doc.version)
        return doc.version
    }

    public func outdated(forceRefresh: Bool) async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        return await withTaskGroup(of: OutdatedPackage?.self) { group in
            for pkg in installed {
                group.addTask {
                    guard let latest = await self.latestVersion(of: pkg.name, forceRefresh: forceRefresh) else { return nil }
                    return pkg.version != latest ? OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .gem) : nil
                }
            }
            var out: [OutdatedPackage] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }

    public func outdated() async throws -> [OutdatedPackage] {
        try await outdated(forceRefresh: false)
    }
}
