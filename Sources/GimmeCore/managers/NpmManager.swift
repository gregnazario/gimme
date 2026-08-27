import Foundation

/// npm adapter. Uses the npm registry JSON for search/info and the `npm` CLI
/// for actions + list. Global packages via `-g`.
public final class NpmManager: PackageManager {
    public let id: ManagerID = .npm
    public let displayName = "npm"
    public let icon = "shippingbox.fill"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let binaryOverride: String?   // nil = resolve via `which npm`
    private let askpassURL: URL?
    /// Shared disk cache for per-package dist-tags lookups (App Store pattern:
    /// one lookup per package per TTL window instead of per run). nil = off.
    private let indexCache: Cache?

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                binary: String? = nil,
                askpassURL: URL? = nil,
                indexCache: Cache? = nil) {
        self.http = http
        self.process = process
        self.binaryOverride = binary
        self.askpassURL = askpassURL
        self.indexCache = indexCache
    }

    /// Resolve the real npm path (via `which npm`), or use the injected override.
    private var binaryPath: String {
        binaryOverride ?? BinaryResolver.resolve("npm", fallback: nil) ?? ""
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("npm") != nil || binaryOverride != nil
    }

    public func bootstrap() async throws {
        // npm ships with Node; install via the official Node installer.
        // Security (audit 2026-08-24): private mktemp dir + pinned SHA256
        // verified before `sudo installer`. Bump URL and hash together.
        let script = """
        set -e
        d="$(mktemp -d)"
        trap 'rm -rf "$d"' EXIT
        curl -fsSL https://nodejs.org/dist/v22.0.0/node-v22.0.0.pkg -o "$d/node.pkg"
        echo '2a7aa14f78d7b764d1552898bf1181da34d3ce40696742c137b8c3ab4079d078  node.pkg' > "$d/SHA256"
        (cd "$d" && shasum -a 256 -c SHA256 --status)
        sudo installer -pkg "$d/node.pkg" -target /
        """
        // SUDO_ASKPASS lets the GUI show the native password dialog (sudo
        // still prefers the terminal when one exists).
        _ = try await process.run("/bin/bash", args: ["-c", script],
                                  env: SudoAskpass.environment(helperURL: askpassURL), stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Search / Info (npm registry)

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
        return doc.objects.map { SearchHit(name: $0.package.name, manager: .npm, summary: $0.package.description ?? "", latestVersion: $0.package.version ?? "") }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: NpmPackument = try? await http.getJSON("https://registry.npmjs.org/\(package.name)", as: NpmPackument.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.npm])
        }
        return PackageInfo(name: doc.name ?? package.name, manager: .npm, latestVersion: doc.distTags?.latest ?? "",
            summary: doc.description ?? "", homepage: doc.homepage, license: doc.license,
            installedVersion: nil, location: nil)
    }

    // MARK: - Actions (npm CLI)

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res = try await process.run(binaryPath, args: ["install", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .npm, op: "install", underlying: res.stderr) }
        listMemo.clear()
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .npm, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["uninstall", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .npm, op: "uninstall", underlying: res.stderr) }
        listMemo.clear()
    }

    public func upgrade(_ package: PackageRef) async throws {
        // npm semantics: reinstall to latest.
        let res = try await process.run(binaryPath, args: ["install", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .npm, op: "upgrade", underlying: res.stderr) }
        listMemo.clear()
    }

    /// Memoized so concurrent engine `list` + `outdated` calls spawn `npm ls`
    /// once instead of twice. Mutating ops clear it.
    private let listMemo = InProcessMemo<[InstalledPackage]>(ttl: 5)

    public func listInstalled() async throws -> [InstalledPackage] {
        if let memoized = listMemo.get() { return memoized }
        let pkgs = try await runListInstalled()
        listMemo.set(pkgs)
        return pkgs
    }

    private func runListInstalled() async throws -> [InstalledPackage] {
        // `npm ls -g --depth=0 --json` -> {"dependencies":{"name":{"version":"x"}, ...}}
        let res = try await process.run(binaryPath, args: ["ls", "-g", "--depth=0", "--json"], env: nil, stream: nil)
        guard res.exitCode == 0, let data = res.stdout.data(using: .utf8) else { return [] }
        struct Wrapper: Decodable { let dependencies: [String: Dep]?
            struct Dep: Decodable { let version: String? } }
        guard let w = try? JSONDecoder().decode(Wrapper.self, from: data) else { return [] }
        return (w.dependencies ?? [:]).compactMap { (name, dep) -> InstalledPackage? in
            guard let v = dep.version else { return nil }
            return InstalledPackage(name: name, version: v, manager: .npm, installedAt: nil)
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
                    return pkg.version != latest ? OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .npm) : nil
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
