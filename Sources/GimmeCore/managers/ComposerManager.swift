import Foundation

/// Composer (PHP) adapter. Uses packagist.org for search/info and the
/// `composer global` CLI for actions + list.
public final class ComposerManager: PackageManager {
    public let id: ManagerID = .composer
    public let displayName = "Composer (PHP)"
    public let icon = "music.note"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let binaryOverride: String?   // nil = resolve via `which composer`

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                binary: String? = nil) {
        self.http = http
        self.process = process
        self.binaryOverride = binary
    }

    private var binaryPath: String {
        binaryOverride ?? BinaryResolver.resolve("composer", fallback: nil) ?? ""
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("composer") != nil || binaryOverride != nil
    }

    public func bootstrap() async throws {
        // Composer's official installer.
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"],
            env: nil, stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Search / Info (packagist.org)

    private struct PackagistSearch: Decodable {
        let results: [Result]
        struct Result: Decodable { let name: String; let description: String?; let version: String? }
    }
    private struct PackagistPackage: Decodable {
        let name: String
        let description: String?
        let homepage: String?
        let license: [String]?
        struct VersionInfo: Decodable { let version: String? }
        let versions: [String: VersionInfo]?
        var latestVersion: String? {
            // versions is keyed by tag (e.g. "3.5.0"); pick the non-dev one with
            // the highest semantic value, or just the first non-dev entry.
            versions?.keys.filter { !$0.contains("dev") && !$0.hasPrefix("v") }.sorted().last
                ?? versions?.keys.first { !$0.contains("dev") }
        }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        let url = "https://packagist.org/search.json?q=\(query)"
        guard let doc: PackagistSearch = try? await http.getJSON(url, as: PackagistSearch.self) else { return [] }
        return doc.results.map { SearchHit(name: $0.name, manager: .composer, summary: $0.description ?? "", latestVersion: $0.version ?? "") }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: PackagistPackage = try? await http.getJSON("https://repo.packagist.org/p2/\(package.name).json", as: PackagistPackage.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.composer])
        }
        return PackageInfo(name: doc.name, manager: .composer, latestVersion: doc.latestVersion ?? "",
            summary: doc.description ?? "", homepage: doc.homepage, license: doc.license?.first,
            installedVersion: nil, location: nil)
    }

    // MARK: - Actions (composer global CLI)

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        // Composer pins versions as "name:version".
        let target = options.version.map { "\(package.name):\($0)" } ?? package.name
        let res = try await process.run(binaryPath, args: ["global", "require", target], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .composer, op: "install", underlying: res.stderr) }
        return InstallResult(package: InstalledPackage(name: package.name, version: options.version ?? "latest", manager: .composer, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["global", "remove", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .composer, op: "uninstall", underlying: res.stderr) }
    }

    public func upgrade(_ package: PackageRef) async throws {
        // `composer global require` updates to the latest matching constraint.
        let res = try await process.run(binaryPath, args: ["global", "require", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .composer, op: "upgrade", underlying: res.stderr) }
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        // `composer global show` lists "vendor/name version description".
        let res = try await process.run(binaryPath, args: ["global", "show"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        return res.stdout.split(separator: "\n").compactMap { line -> InstalledPackage? in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            // First token must contain "/" (vendor/name); second is the version.
            let parts = s.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2, parts[0].contains("/") else { return nil }
            return InstalledPackage(name: parts[0], version: parts[1], manager: .composer, installedAt: nil)
        }
    }

    public func outdated() async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        return await withTaskGroup(of: OutdatedPackage?.self) { group in
            for pkg in installed {
                group.addTask {
                    guard let doc: PackagistPackage = try? await self.http.getJSON("https://repo.packagist.org/p2/\(pkg.name).json", as: PackagistPackage.self),
                          let latest = doc.latestVersion else { return nil }
                    return pkg.version != latest ? OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .composer) : nil
                }
            }
            var out: [OutdatedPackage] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }
}
