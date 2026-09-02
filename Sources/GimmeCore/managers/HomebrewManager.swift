import Foundation

/// Homebrew adapter (spec §6.1). Uses the formulae.brew.sh JSON API for
/// search/info and the `brew` CLI for actions + list/outdated.
public final class HomebrewManager: PackageManager, Sendable {
    public let id: ManagerID = .homebrew
    public let displayName = "Homebrew"
    public let icon = "cup.and.saucer.fill"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let brewBinaryOverride: String?   // nil = resolve via `which brew`

    /// Resolve the real brew path (via `which brew`), or use the injected override.
    private var binaryPath: String {
        brewBinaryOverride ?? BinaryResolver.resolve("brew", fallback: "/opt/homebrew/bin/brew") ?? "/opt/homebrew/bin/brew"
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("brew") != nil || brewBinaryOverride != nil
    }

    public func bootstrap() async throws {
        let script = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -fsSL \(script) | /bin/bash"],
            env: ["NONINTERACTIVE": "1"],
            stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)
    }

    /// Download + cache the formula/cask indexes so subsequent searches can be
    /// enriched with descriptions/versions. Fire-and-forget from the GUI on
    /// launch; a no-op when the cache is already warm.
    public func warmSearchIndexes() async {
        _ = try? await formulaIndex()
        _ = await caskIndex()
    }

    // MARK: - Search / Info (API-backed)

    private struct FormulaAPIDoc: Decodable {
        let name: String
        let desc: String?
        let versions: Versions?
        struct Versions: Decodable { let stable: String? }
    }

    private struct CaskAPIDoc: Decodable {
        let token: String           // casks identify by token
        let desc: String?
        let version: String?
    }

    /// The formula/cask indexes are ~31 MB; downloading them per query made
    /// every search take 4-5 s. Cache the raw bytes and filter locally.
    private static let indexTTLSeconds = 6 * 3600  // 6 h
    private static let searchResultLimit = 50

    /// Optional: injected so tests stay hermetic (nil = no index caching).
    private let indexCache: Cache?

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                brewBinary: String? = nil,
                indexCache: Cache? = nil) {
        self.http = http
        self.process = process
        self.brewBinaryOverride = brewBinary
        self.indexCache = indexCache
    }

    /// Fetch the formula index, cached as raw bytes (6 h TTL).
    private func formulaIndex() async throws -> [FormulaAPIDoc] {
        let key = "homebrew:index:formula"
        if let cache = indexCache,
           let data = cache.get(key, ttlSeconds: Self.indexTTLSeconds, as: Data.self),
           let docs = try? JSONDecoder().decode([FormulaAPIDoc].self, from: data) {
            return docs
        }
        let data = try await http.get("https://formulae.brew.sh/api/formula.json")
        if let cache = indexCache { cache.set(key, value: data) }
        guard let docs = try? JSONDecoder().decode([FormulaAPIDoc].self, from: data) else {
            throw GimmeError.network("failed to decode formula index")
        }
        return docs
    }

    /// Fetch the cask index, cached the same way. Best-effort: cask failures
    /// never break a formula search.
    private func caskIndex() async -> [CaskAPIDoc] {
        let key = "homebrew:index:cask"
        if let cache = indexCache,
           let data = cache.get(key, ttlSeconds: Self.indexTTLSeconds, as: Data.self),
           let docs = try? JSONDecoder().decode([CaskAPIDoc].self, from: data) {
            return docs
        }
        guard let data = try? await http.get("https://formulae.brew.sh/api/cask.json"),
              let docs = try? JSONDecoder().decode([CaskAPIDoc].self, from: data) else {
            return []
        }
        if let cache = indexCache { cache.set(key, value: data) }
        return docs
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        // Primary: `brew search` — local metadata, ~0.3 s, includes casks.
        // No network. Falls back to the (cached) API index if the CLI fails.
        if isAvailable() {
            let res = try await process.run(binaryPath, args: ["search", query], env: nil, stream: nil)
            if res.exitCode == 0 {
                let names = res.stdout.split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
                    .prefix(Self.searchResultLimit)
                return await enrich(Array(names))
            }
        }
        return try await apiSearch(query)
    }

    /// Add description/version to bare names from a warm cached index, if any.
    /// Never downloads — enrichment is best-effort.
    private func enrich(_ names: [String]) async -> [SearchHit] {
        guard let cache = indexCache else {
            return names.map { SearchHit(name: $0, manager: .homebrew, summary: "", latestVersion: "") }
        }
        var meta: [String: (String, String)] = [:]
        if let data = cache.get("homebrew:index:formula", ttlSeconds: Self.indexTTLSeconds, as: Data.self),
           let docs = try? JSONDecoder().decode([FormulaAPIDoc].self, from: data) {
            for d in docs { meta[d.name] = (d.desc ?? "", d.versions?.stable ?? "") }
        }
        if let data = cache.get("homebrew:index:cask", ttlSeconds: Self.indexTTLSeconds, as: Data.self),
           let docs = try? JSONDecoder().decode([CaskAPIDoc].self, from: data) {
            for c in docs { meta[c.token] = (c.desc ?? "GUI app (cask)", c.version ?? "") }
        }
        return names.map {
            SearchHit(name: $0, manager: .homebrew,
                      summary: meta[$0]?.0 ?? "",
                      latestVersion: meta[$0]?.1 ?? "")
        }
    }

    /// Fallback search over the formulae.brew.sh indexes (downloads + caches
    /// them when cold). Formulae first, then casks.
    private func apiSearch(_ query: String) async throws -> [SearchHit] {
        let q = query.lowercased()
        let formulas = try await formulaIndex()
        var hits = formulas.filter { $0.name.lowercased().contains(q) }.map {
            SearchHit(name: $0.name, manager: .homebrew, summary: $0.desc ?? "", latestVersion: $0.versions?.stable ?? "")
        }
        if hits.count < Self.searchResultLimit {
            let casks = await caskIndex()
            let caskHits = casks.filter { $0.token.lowercased().contains(q) }.map {
                SearchHit(name: $0.token, manager: .homebrew, summary: $0.desc ?? "GUI app (cask)", latestVersion: $0.version ?? "")
            }
            hits.append(contentsOf: caskHits)
        }
        return Array(hits.prefix(Self.searchResultLimit))
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        // Prefer the local brew info --json=v2 for installed-version accuracy.
        let res = try await process.run(binaryPath, args: ["info", "--json=v2", package.name], env: nil, stream: nil)
        if res.exitCode == 0, let data = res.stdout.data(using: .utf8) {
            struct Wrapper: Decodable { let formulae: [BrewInfo] }
            struct BrewInfo: Decodable {
                let name: String; let versions: Versions; let desc: String?; let homepage: String?; let license: String?
                struct Versions: Decodable { let stable: String? }
            }
            if let wrap = try? JSONDecoder().decode(Wrapper.self, from: data), let f = wrap.formulae.first {
                return PackageInfo(name: f.name, manager: .homebrew,
                    latestVersion: f.versions.stable ?? "", summary: f.desc ?? "",
                    homepage: f.homepage, license: f.license, installedVersion: nil, location: nil)
            }
        }
        // Fallback to API by exact name.
        let docs: [FormulaAPIDoc] = try await http.getJSON("https://formulae.brew.sh/api/formula.json", as: [FormulaAPIDoc].self)
        guard let d = docs.first(where: { $0.name == package.name }) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.homebrew])
        }
        return PackageInfo(name: d.name, manager: .homebrew, latestVersion: d.versions?.stable ?? "",
            summary: d.desc ?? "", homepage: nil, license: nil, installedVersion: nil, location: nil)
    }

    // MARK: - Actions (CLI-backed)

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res = try await process.run(binaryPath, args: ["install", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .homebrew, op: "install", underlying: res.stderr)
        }
        listMemo.clear()
        let version = (try? await installedVersion(of: package.name)) ?? "unknown"
        return InstallResult(package: InstalledPackage(name: package.name, version: version, manager: .homebrew, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["uninstall", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .homebrew, op: "uninstall", underlying: res.stderr)
        }
        listMemo.clear()
    }

    public func upgrade(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["upgrade", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .homebrew, op: "upgrade", underlying: res.stderr)
        }
        listMemo.clear()
    }

    /// Memoized so concurrent engine `list` + `outdated` calls spawn the
    /// ~0.6 s `brew list` subprocess once instead of twice. Mutating ops
    /// clear it.
    private let listMemo = InProcessMemo<[InstalledPackage]>(ttl: 5)

    public func listInstalled() async throws -> [InstalledPackage] {
        if let memoized = listMemo.get() { return memoized }
        let pkgs = try await runListInstalled()
        listMemo.set(pkgs)
        return pkgs
    }

    private func runListInstalled() async throws -> [InstalledPackage] {
        // `brew list --json --versions` returns:
        // {"formulae":[{"name","versions":["x"],...}], "casks":[{"token","versions":["x"],...}]}
        // Note: formulae use "name", casks use "token" for the identifier.
        let res = try await process.run(binaryPath, args: ["list", "--json", "--versions"], env: nil, stream: nil)
        guard res.exitCode == 0, let data = res.stdout.data(using: .utf8) else { return [] }
        struct Wrapper: Decodable {
            let formulae: [Formula]; let casks: [Cask]
            struct Formula: Decodable { let name: String; let versions: [String]? }
            struct Cask: Decodable { let token: String; let versions: [String]? }
        }
        guard let w = try? JSONDecoder().decode(Wrapper.self, from: data) else { return [] }
        let formulas = w.formulae.compactMap { f -> InstalledPackage? in
            guard let v = f.versions?.first else { return nil }
            return InstalledPackage(name: f.name, version: v, manager: .homebrew, installedAt: nil)
        }
        let casks = w.casks.compactMap { c -> InstalledPackage? in
            guard let v = c.versions?.first else { return nil }
            return InstalledPackage(name: c.token, version: v, manager: .homebrew, installedAt: nil)
        }
        return formulas + casks
    }

    public func outdated() async throws -> [OutdatedPackage] {
        let res = try await process.run(binaryPath, args: ["outdated", "--json=v2"], env: nil, stream: nil)
        guard res.exitCode == 0, let data = res.stdout.data(using: .utf8) else { return [] }
        struct Wrapper: Decodable {
            let formulae: [Item]; let casks: [Item]
            struct Item: Decodable {
                let name: String; let installed_versions: [String]?; let current_version: String?
            }
        }
        guard let w = try? JSONDecoder().decode(Wrapper.self, from: data) else { return [] }
        let formulas = w.formulae.compactMap { f -> OutdatedPackage? in
            guard let cur = f.current_version, let inst = f.installed_versions?.first else { return nil }
            return OutdatedPackage(name: f.name, installedVersion: inst, latestVersion: cur, manager: .homebrew)
        }
        let casks = w.casks.compactMap { c -> OutdatedPackage? in
            guard let cur = c.current_version, let inst = c.installed_versions?.first else { return nil }
            return OutdatedPackage(name: c.name, installedVersion: inst, latestVersion: cur, manager: .homebrew)
        }
        return formulas + casks
    }

    private func installedVersion(of name: String) async throws -> String? {
        try await listInstalled().first { $0.name == name }?.version
    }
}
