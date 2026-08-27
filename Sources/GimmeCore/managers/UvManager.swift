import Foundation

/// uv (Python) adapter (spec §6.3). Per-tool isolated venvs via `uv tool`.
public final class UvManager: PackageManager {
    public let id: ManagerID = .uv
    public let displayName = "Python (uv)"
    public let icon = "snake"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let uvBinaryOverride: String?   // nil = resolve via `which uv`
    /// Shared disk cache for per-package latest-version lookups (App Store
    /// pattern: one lookup per package per TTL window instead of per run).
    /// nil = off.
    private let indexCache: Cache?
    private static let latestTTLSeconds = 3600

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                uvBinary: String? = nil,
                indexCache: Cache? = nil) {
        self.http = http
        self.process = process
        self.uvBinaryOverride = uvBinary
        self.indexCache = indexCache
    }

    /// Resolve the real uv path (via `which uv`), or use the injected override.
    private var binaryPath: String {
        uvBinaryOverride ?? BinaryResolver.resolve("uv", fallback: "/opt/uv/bin/uv") ?? "/opt/uv/bin/uv"
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("uv") != nil || uvBinaryOverride != nil
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"],
            env: nil, stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)
    }

    private struct PyPIDoc: Decodable {
        let info: Info
        struct Info: Decodable { let name: String; let summary: String?; let home_page: String?; let license: String?; let version: String? }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        guard let doc: PyPIDoc = try? await http.getJSON("https://pypi.org/pypi/\(query)/json", as: PyPIDoc.self) else { return [] }
        return [SearchHit(name: doc.info.name, manager: .uv, summary: doc.info.summary ?? "", latestVersion: doc.info.version ?? "")]
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: PyPIDoc = try? await http.getJSON("https://pypi.org/pypi/\(package.name)/json", as: PyPIDoc.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.uv])
        }
        return PackageInfo(name: doc.info.name, manager: .uv, latestVersion: doc.info.version ?? "",
            summary: doc.info.summary ?? "", homepage: doc.info.home_page, license: doc.info.license,
            installedVersion: nil, location: nil)
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res = try await process.run(binaryPath, args: ["tool", "install", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .uv, op: "install", underlying: res.stderr) }
        listMemo.clear()
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .uv, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["tool", "uninstall", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .uv, op: "uninstall", underlying: res.stderr) }
        listMemo.clear()
    }

    public func upgrade(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["tool", "upgrade", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .uv, op: "upgrade", underlying: res.stderr) }
        listMemo.clear()
    }

    /// Memoized so concurrent engine `list` + `outdated` calls spawn
    /// `uv tool list` once instead of twice. Mutating ops clear it.
    private let listMemo = InProcessMemo<[InstalledPackage]>(ttl: 5)

    public func listInstalled() async throws -> [InstalledPackage] {
        if let memoized = listMemo.get() { return memoized }
        let pkgs = try await runListInstalled()
        listMemo.set(pkgs)
        return pkgs
    }

    private func runListInstalled() async throws -> [InstalledPackage] {
        let res = try await process.run(binaryPath, args: ["tool", "list"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        // Current `uv tool list` prints one block per tool — a "name vX.Y.Z"
        // line followed by "- executable" bullets. Older uv printed
        // "name (executable: bin)" with no version.
        return res.stdout.split(separator: "\n").compactMap { line -> InstalledPackage? in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("-") else { return nil }   // executable bullets
            let name: String
            var version = "unknown"
            if let paren = s.firstIndex(of: "(") {
                name = String(s[..<paren]).trimmingCharacters(in: .whitespaces)
            } else {
                let tokens = s.split(separator: " ")
                guard let first = tokens.first else { return nil }
                name = String(first)
                if tokens.count > 1 { version = Self.normalize(String(tokens[1])) }
            }
            guard !name.isEmpty else { return nil }
            return InstalledPackage(name: name, version: version, manager: .uv, installedAt: nil)
        }
    }

    /// uv versions carry a leading "v" ("v3.2.3"); PyPI's API doesn't.
    /// Normalize before storing or comparing.
    private static func normalize(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
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
                    return Self.normalize(pkg.version) != Self.normalize(latest)
                        ? OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .uv)
                        : nil
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
