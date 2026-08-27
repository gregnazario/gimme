import Foundation

/// bun (npm) adapter (spec §6.5). npm registry JSON for search/info; bun CLI.
public final class BunManager: PackageManager {
    public let id: ManagerID = .bun
    public let displayName = "npm (via bun)"
    public let icon = "bag"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let bunBinaryOverride: String?   // nil = resolve via `which bun`
    /// Shared disk cache for per-package dist-tags lookups (App Store pattern:
    /// one lookup per package per TTL window instead of per run). nil = off.
    private let indexCache: Cache?

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                bunBinary: String? = nil,
                indexCache: Cache? = nil) {
        self.http = http
        self.process = process
        self.bunBinaryOverride = bunBinary
        self.indexCache = indexCache
    }

    /// Resolve the real bun path (via `which bun`), or use the injected override.
    private var binaryPath: String {
        let fallback = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.bun/bin/bun"
        return bunBinaryOverride ?? BinaryResolver.resolve("bun", fallback: fallback) ?? fallback
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("bun") != nil || bunBinaryOverride != nil
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -fsSL https://bun.sh/install | bash"],
            env: nil, stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)
    }

    private struct NpmSearch: Decodable {
        let objects: [Obj]
        struct Obj: Decodable {
            let package: Pkg
            struct Pkg: Decodable { let name: String; let description: String?; let version: String? }
        }
    }
    private struct NpmPackument: Decodable {
        let name: String?
        let description: String?
        let homepage: String?
        let license: String?
        let distTags: DistTags?
        enum CodingKeys: String, CodingKey {
            case name, description, homepage, license
            case distTags = "dist-tags"
        }
        struct DistTags: Decodable { let latest: String? }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        let url = NpmRegistry.searchURL(query: query)
        guard let doc: NpmSearch = try? await http.getJSON(url.absoluteString, as: NpmSearch.self) else { return [] }
        return doc.objects.map { SearchHit(name: $0.package.name, manager: .bun, summary: $0.package.description ?? "", latestVersion: $0.package.version ?? "") }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: NpmPackument = try? await http.getJSON("https://registry.npmjs.org/\(package.name)", as: NpmPackument.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.bun])
        }
        return PackageInfo(name: doc.name ?? package.name, manager: .bun, latestVersion: doc.distTags?.latest ?? "",
            summary: doc.description ?? "", homepage: doc.homepage, license: doc.license,
            installedVersion: nil, location: nil)
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res = try await process.run(binaryPath, args: ["install", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .bun, op: "install", underlying: res.stderr) }
        listMemo.clear()
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .bun, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["remove", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .bun, op: "uninstall", underlying: res.stderr) }
        listMemo.clear()
    }

    public func upgrade(_ package: PackageRef) async throws {
        // npm semantics: reinstall to latest.
        let res = try await process.run(binaryPath, args: ["install", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .bun, op: "upgrade", underlying: res.stderr) }
        listMemo.clear()
    }

    /// Memoized so concurrent engine `list` + `outdated` calls spawn `bun pm ls`
    /// once instead of twice. Mutating ops clear it.
    private let listMemo = InProcessMemo<[InstalledPackage]>(ttl: 5)

    public func listInstalled() async throws -> [InstalledPackage] {
        if let memoized = listMemo.get() { return memoized }
        let pkgs = try await runListInstalled()
        listMemo.set(pkgs)
        return pkgs
    }

    private func runListInstalled() async throws -> [InstalledPackage] {
        let res = try await process.run(binaryPath, args: ["pm", "ls", "-g"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        // `bun pm ls -g` emits a tree with drawing characters:
        //   "├── esbuild@0.21.0"
        //   "└── @babel/core@7.0.0"
        // Strip the leading tree-drawing chars + whitespace, then split on the
        // last '@' that isn't at index 0 (so scoped names like @babel/core work).
        return res.stdout.split(separator: "\n").compactMap { line -> InstalledPackage? in
            let raw = String(line)
            // Find where the package name starts: first '@' or alnum char.
            guard let nameStart = raw.firstIndex(where: { $0 == "@" || $0.isLetter || $0.isNumber }) else { return nil }
            let s = String(raw[nameStart...])
            guard let at = s.lastIndex(of: "@"), at != s.startIndex else { return nil }
            let name = String(s[..<at])
            let version = String(s[s.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            return InstalledPackage(name: name, version: version.isEmpty ? "unknown" : version, manager: .bun, installedAt: nil)
        }
    }

    public func outdated(forceRefresh: Bool) async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        return await withTaskGroup(of: OutdatedPackage?.self) { group in
            for pkg in installed {
                group.addTask {
                    // dist-tags endpoint (~180 B), not the full packument
                    // (up to MBs) — outdated only ever needed this one field.
                    guard let latest = await NpmRegistry.latestVersion(of: pkg.name, http: self.http, indexCache: self.indexCache, forceRefresh: forceRefresh) else { return nil }
                    return pkg.version != latest ? OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .bun) : nil
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
