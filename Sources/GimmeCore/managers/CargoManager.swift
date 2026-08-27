import Foundation

/// Cargo (Rust) adapter (spec §6.4). crates.io JSON for search/info; cargo CLI.
public final class CargoManager: PackageManager {
    public let id: ManagerID = .cargo
    public let displayName = "Cargo"
    public let icon = "shippingbox"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let cargoBinaryOverride: String?   // nil = resolve via `which cargo`
    /// Shared disk cache for per-package latest-version lookups (App Store
    /// pattern: one lookup per package per TTL window instead of per run).
    /// nil = off.
    private let indexCache: Cache?
    private static let latestTTLSeconds = 3600

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                cargoBinary: String? = nil,
                indexCache: Cache? = nil) {
        self.http = http
        self.process = process
        self.cargoBinaryOverride = cargoBinary
        self.indexCache = indexCache
    }

    /// Resolve the real cargo path (via `which cargo`), or use the injected override.
    private var binaryPath: String {
        let fallback = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cargo/bin/cargo"
        return cargoBinaryOverride ?? BinaryResolver.resolve("cargo", fallback: fallback) ?? fallback
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("cargo") != nil || cargoBinaryOverride != nil
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"],
            env: nil, stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)
    }

    private struct CratesSearch: Decodable {
        let crates: [Crate]
        struct Crate: Decodable { let name: String; let description: String?; let max_version: String?; let homepage: String? }
    }
    private struct CrateInfo: Decodable {
        let crate: CratesSearch.Crate
        struct Version: Decodable { let num: String }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        guard let doc: CratesSearch = try? await http.getJSON("https://crates.io/api/v1/crates?q=\(query)", as: CratesSearch.self) else { return [] }
        return doc.crates.map { SearchHit(name: $0.name, manager: .cargo, summary: $0.description ?? "", latestVersion: $0.max_version ?? "") }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: CrateInfo = try? await http.getJSON("https://crates.io/api/v1/crates/\(package.name)", as: CrateInfo.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.cargo])
        }
        return PackageInfo(name: doc.crate.name, manager: .cargo, latestVersion: doc.crate.max_version ?? "",
            summary: doc.crate.description ?? "", homepage: doc.crate.homepage, license: nil,
            installedVersion: nil, location: nil)
    }

    /// True when `cargo-binstall` is installed (faster binary installs vs
    /// compiling from source). Checked once and cached.
    private var binstallAvailable: Bool {
        if let cached = Self.binstallCache { return cached }
        let available = BinaryResolver.resolve("cargo-binstall") != nil
        Self.binstallCache = available
        return available
    }
    nonisolated(unsafe) private static var binstallCache: Bool? = nil

    /// Test hook: override the binstall-availability check. nil = auto-detect.
    public static func setBinstallAvailableForTesting(_ value: Bool?) {
        binstallCache = value
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res: ProcessResult
        if binstallAvailable {
            // `cargo binstall` downloads prebuilt binaries — much faster than
            // compiling. -y auto-confirms (no interactive prompt).
            var spec = package.name
            if let v = options.version { spec += "@\(v)" }
            res = try await process.run(binaryPath, args: ["binstall", "-y", spec], env: nil, stream: nil)
        } else {
            // Fallback: compile from source.
            var args = ["install"]
            if let v = options.version { args += ["--version", v] }
            args.append(package.name)
            res = try await process.run(binaryPath, args: args, env: nil, stream: nil)
        }
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .cargo, op: "install", underlying: res.stderr) }
        listMemo.clear()
        let version = (try? await installedVersion(of: package.name)) ?? "latest"
        return InstallResult(package: InstalledPackage(name: package.name, version: version, manager: .cargo, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["uninstall", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .cargo, op: "uninstall", underlying: res.stderr) }
        listMemo.clear()
    }

    public func upgrade(_ package: PackageRef) async throws {
        if binstallAvailable {
            // Re-run binstall to fetch the latest prebuilt binary.
            let res = try await process.run(binaryPath, args: ["binstall", "-y", "--force", package.name], env: nil, stream: nil)
            guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .cargo, op: "upgrade", underlying: res.stderr) }
        } else {
            // Cargo has no upgrade; reinstall to latest with --force.
            let res = try await process.run(binaryPath, args: ["install", package.name, "--force"], env: nil, stream: nil)
            guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .cargo, op: "upgrade", underlying: res.stderr) }
        }
        listMemo.clear()
    }

    /// Memoized so concurrent engine `list` + `outdated` calls spawn
    /// `cargo install --list` once instead of twice. Mutating ops clear it.
    private let listMemo = InProcessMemo<[InstalledPackage]>(ttl: 5)

    public func listInstalled() async throws -> [InstalledPackage] {
        if let memoized = listMemo.get() { return memoized }
        let pkgs = try await runListInstalled()
        listMemo.set(pkgs)
        return pkgs
    }

    private func runListInstalled() async throws -> [InstalledPackage] {
        let res = try await process.run(binaryPath, args: ["install", "--list"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        // Lines: "ripgrep v14.1.0:" then indented binaries.
        var pkgs: [InstalledPackage] = []
        for line in res.stdout.split(separator: "\n") {
            let s = String(line)
            // Match "name vX.Y.Z:" at column 0.
            if s.first != " " && s.contains(" v") && s.hasSuffix(":") {
                let body = String(s.dropLast())  // strip ':'
                let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[1].hasPrefix("v") {
                    pkgs.append(InstalledPackage(name: parts[0], version: String(parts[1].dropFirst()), manager: .cargo, installedAt: nil))
                }
            }
        }
        return pkgs
    }

    /// Latest crates.io version of a crate, cached per package (1 h).
    /// forceRefresh bypasses the cache read (and overwrites the entry).
    /// Returns nil on any failure; callers skip the crate rather than flag it.
    private func latestVersion(of name: String, forceRefresh: Bool = false) async -> String? {
        let key = "\(id.rawValue):latest:\(name)"
        if !forceRefresh,
           let indexCache, let cached = indexCache.get(key, ttlSeconds: Self.latestTTLSeconds, as: String.self) {
            return cached
        }
        guard let doc: CrateInfo = try? await http.getJSON("https://crates.io/api/v1/crates/\(name)", as: CrateInfo.self),
              let latest = doc.crate.max_version else { return nil }
        indexCache?.set(key, value: latest)
        return latest
    }

    public func outdated(forceRefresh: Bool) async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        return await withTaskGroup(of: OutdatedPackage?.self) { group in
            for pkg in installed {
                group.addTask {
                    guard let latest = await self.latestVersion(of: pkg.name, forceRefresh: forceRefresh) else { return nil }
                    return pkg.version != latest ? OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .cargo) : nil
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

    private func installedVersion(of name: String) async throws -> String? {
        try await listInstalled().first { $0.name == name }?.version
    }
}
