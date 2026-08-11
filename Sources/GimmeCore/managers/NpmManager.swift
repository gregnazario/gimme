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

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                binary: String? = nil) {
        self.http = http
        self.process = process
        self.binaryOverride = binary
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
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -fsSL https://nodejs.org/dist/v22.0.0/node-v22.0.0.pkg -o /tmp/node.pkg && sudo installer -pkg /tmp/node.pkg -target /"],
            env: nil, stream: nil)
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
        let url = "https://registry.npmjs.org/-/v1/search?size=25&q=\(query)"
        guard let doc: NpmSearch = try? await http.getJSON(url, as: NpmSearch.self) else { return [] }
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
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .npm, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["uninstall", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .npm, op: "uninstall", underlying: res.stderr) }
    }

    public func upgrade(_ package: PackageRef) async throws {
        // npm semantics: reinstall to latest.
        let res = try await process.run(binaryPath, args: ["install", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .npm, op: "upgrade", underlying: res.stderr) }
    }

    public func listInstalled() async throws -> [InstalledPackage] {
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

    public func outdated() async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        return await withTaskGroup(of: OutdatedPackage?.self) { group in
            for pkg in installed {
                group.addTask {
                    guard let doc: NpmPackument = try? await self.http.getJSON("https://registry.npmjs.org/\(pkg.name)", as: NpmPackument.self),
                          let latest = doc.distTags?.latest else { return nil }
                    return pkg.version != latest ? OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .npm) : nil
                }
            }
            var out: [OutdatedPackage] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }
}
