import Foundation

/// Yarn (classic v1) adapter. Uses the npm registry for search/info and the
/// `yarn global` CLI for actions. Note: Yarn Berry (v2+) removed global installs;
/// this adapter targets the classic model, which is what global yarn users run.
public final class YarnManager: PackageManager {
    public let id: ManagerID = .yarn
    public let displayName = "Yarn"
    public let icon = "circle.hexagongrid.fill"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let binaryOverride: String?   // nil = resolve via `which yarn`

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                binary: String? = nil) {
        self.http = http
        self.process = process
        self.binaryOverride = binary
    }

    private var binaryPath: String {
        binaryOverride ?? BinaryResolver.resolve("yarn", fallback: nil) ?? ""
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("yarn") != nil || binaryOverride != nil
    }

    public func bootstrap() async throws {
        // Yarn classic installs via corepack or npm. Prefer corepack enable.
        _ = try await process.run("/bin/bash",
            args: ["-c", "corepack enable yarn || npm install -g yarn"],
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
        let url = NpmRegistry.searchURL(query: query)
        guard let doc: NpmSearch = try? await http.getJSON(url.absoluteString, as: NpmSearch.self) else { return [] }
        return doc.objects.map { SearchHit(name: $0.package.name, manager: .yarn, summary: $0.package.description ?? "", latestVersion: $0.package.version ?? "") }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: NpmPackument = try? await http.getJSON("https://registry.npmjs.org/\(package.name)", as: NpmPackument.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.yarn])
        }
        return PackageInfo(name: doc.name ?? package.name, manager: .yarn, latestVersion: doc.distTags?.latest ?? "",
            summary: doc.description ?? "", homepage: doc.homepage, license: doc.license,
            installedVersion: nil, location: nil)
    }

    // MARK: - Actions (yarn classic global CLI)

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res = try await process.run(binaryPath, args: ["global", "add", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .yarn, op: "install", underlying: res.stderr) }
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .yarn, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["global", "remove", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .yarn, op: "uninstall", underlying: res.stderr) }
    }

    public func upgrade(_ package: PackageRef) async throws {
        // yarn classic: re-add upgrades.
        let res = try await process.run(binaryPath, args: ["global", "add", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .yarn, op: "upgrade", underlying: res.stderr) }
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        // `yarn global list` (no JSON in v1). Output is human-formatted, e.g.:
        //   info "esbuild@0.21.0" has binaries:"esbuild"
        let res = try await process.run(binaryPath, args: ["global", "list"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        return res.stdout.split(separator: "\n").compactMap { line -> InstalledPackage? in
            let s = String(line)
            // Extract the "name@version" between the first pair of double quotes.
            guard s.contains("info \""), let firstQuote = s.firstIndex(of: "\""),
                  let atEnd = s[firstQuote...].range(of: "@") else { return nil }
            let nameStart = s.index(after: firstQuote)
            let at = atEnd.lowerBound
            guard at > nameStart else { return nil }
            guard let closingQuote = s[at...].firstIndex(of: "\"") else { return nil }
            let name = String(s[nameStart..<at])
            let version = String(s[s.index(after: at)..<closingQuote])
            guard !name.isEmpty, !version.isEmpty else { return nil }
            return InstalledPackage(name: name, version: version, manager: .yarn, installedAt: nil)
        }
    }

    public func outdated() async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        return await withTaskGroup(of: OutdatedPackage?.self) { group in
            for pkg in installed {
                group.addTask {
                    guard let doc: NpmPackument = try? await self.http.getJSON("https://registry.npmjs.org/\(pkg.name)", as: NpmPackument.self),
                          let latest = doc.distTags?.latest else { return nil }
                    return pkg.version != latest ? OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .yarn) : nil
                }
            }
            var out: [OutdatedPackage] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }
}
