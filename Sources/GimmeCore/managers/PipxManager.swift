import Foundation

/// pipx adapter (spec §7). Per-tool isolated venvs (the original; uv tool is the
/// modern equivalent). Python ecosystem — consolidation nudges toward one of
/// pipx/uv. Uses PyPI JSON for search/info.
public final class PipxManager: PackageManager, Sendable {
    public let id: ManagerID = .pipx
    public let displayName = "pipx"
    public let icon = "tray.full.fill"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let binaryOverride: String?
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
        binaryOverride ?? BinaryResolver.resolve("pipx", fallback: nil) ?? ""
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("pipx") != nil || binaryOverride != nil
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "python3 -m pip install --user pipx || brew install pipx"],
            env: nil, stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Search / Info (PyPI)

    private struct PyPIDoc: Decodable {
        let info: Info
        struct Info: Decodable { let name: String; let summary: String?; let version: String? }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        guard let doc: PyPIDoc = try? await http.getJSON("https://pypi.org/pypi/\(query)/json", as: PyPIDoc.self) else { return [] }
        return [SearchHit(name: doc.info.name, manager: .pipx, summary: doc.info.summary ?? "", latestVersion: doc.info.version ?? "")]
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: PyPIDoc = try? await http.getJSON("https://pypi.org/pypi/\(package.name)/json", as: PyPIDoc.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.pipx])
        }
        return PackageInfo(name: doc.info.name, manager: .pipx, latestVersion: doc.info.version ?? "",
            summary: doc.info.summary ?? "", homepage: nil, license: nil,
            installedVersion: nil, location: nil)
    }

    // MARK: - Actions

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let spec = options.version.map { "\(package.name)==\($0)" } ?? package.name
        let res = try await process.run(binaryPath, args: ["install", spec], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .pipx, op: "install", underlying: res.stderr) }
        listMemo.clear()
        return InstallResult(package: InstalledPackage(name: package.name, version: options.version ?? "latest", manager: .pipx, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["uninstall", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .pipx, op: "uninstall", underlying: res.stderr) }
        listMemo.clear()
    }

    public func upgrade(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["upgrade", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .pipx, op: "upgrade", underlying: res.stderr) }
        listMemo.clear()
    }

    /// Memoized so concurrent engine `list` + `outdated` calls spawn
    /// `pipx list` once instead of twice. Mutating ops clear it.
    private let listMemo = InProcessMemo<[InstalledPackage]>(ttl: 5)

    public func listInstalled() async throws -> [InstalledPackage] {
        if let memoized = listMemo.get() { return memoized }
        let pkgs = try await runListInstalled()
        listMemo.set(pkgs)
        return pkgs
    }

    private func runListInstalled() async throws -> [InstalledPackage] {
        // pipx list --json: { venvs: { name: { metadata: { main_package: { package_version } } } } }
        let res = try await process.run(binaryPath, args: ["list", "--json"], env: nil, stream: nil)
        guard res.exitCode == 0, let data = res.stdout.data(using: .utf8) else { return [] }
        struct Wrapper: Decodable {
            let venvs: [String: Venv]?
            struct Venv: Decodable { let metadata: Metadata?
                struct Metadata: Decodable { let main_package: Main?
                    struct Main: Decodable { let package_version: String? } } }
        }
        guard let w = try? JSONDecoder().decode(Wrapper.self, from: data) else { return [] }
        return (w.venvs ?? [:]).compactMap { (name, venv) -> InstalledPackage? in
            guard let v = venv.metadata?.main_package?.package_version else { return nil }
            return InstalledPackage(name: name, version: v, manager: .pipx, installedAt: nil)
        }
    }

    /// Latest PyPI version of a tool, cached per package (1 h). forceRefresh
    /// bypasses the cache read (and overwrites the entry). Returns nil on
    /// any failure; callers skip the tool rather than flag it.
    private func latestVersion(of name: String, forceRefresh: Bool = false) async -> String? {
        let key = "\(id.rawValue):latest:\(name)"
        if !forceRefresh,
           let indexCache, let cached = indexCache.get(key, ttlSeconds: Self.latestTTLSeconds, as: String.self) {
            return cached
        }
        guard let doc: PyPIDoc = try? await http.getJSON("https://pypi.org/pypi/\(name)/json", as: PyPIDoc.self),
              let latest = doc.info.version else { return nil }
        indexCache?.set(key, value: latest)
        return latest
    }

    public func outdated(forceRefresh: Bool) async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        return await withTaskGroup(of: OutdatedPackage?.self) { group in
            for pkg in installed {
                group.addTask {
                    guard let latest = await self.latestVersion(of: pkg.name, forceRefresh: forceRefresh) else { return nil }
                    return pkg.version != latest ? OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .pipx) : nil
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
