import Foundation

/// bun (npm) adapter (spec §6.5). npm registry JSON for search/info; bun CLI.
public final class BunManager: PackageManager {
    public let id: ManagerID = .bun
    public let displayName = "npm (via bun)"
    public let icon = "bag"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let bunBinary: String

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                bunBinary: String = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.bun/bin/bun") {
        self.http = http
        self.process = process
        self.bunBinary = bunBinary
    }

    public func isAvailable() -> Bool {
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["bun"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        return proc.terminationStatus == 0
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -fsSL https://bun.sh/install | bash"],
            env: nil, stream: nil)
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
        let url = "https://registry.npmjs.org/-/v1/search?size=25&q=\(query)"
        guard let doc: NpmSearch = try? await http.getJSON(url, as: NpmSearch.self) else { return [] }
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
        let res = try await process.run(bunBinary, args: ["install", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .bun, op: "install", underlying: res.stderr) }
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .bun, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(bunBinary, args: ["remove", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .bun, op: "uninstall", underlying: res.stderr) }
    }

    public func upgrade(_ package: PackageRef) async throws {
        // npm semantics: reinstall to latest.
        let res = try await process.run(bunBinary, args: ["install", "-g", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .bun, op: "upgrade", underlying: res.stderr) }
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        let res = try await process.run(bunBinary, args: ["pm", "ls", "-g"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        // Lines like: "esbuild@0.21.0" (and scoped "@babel/core@7.0.0").
        // The name/version separator is the last '@' that isn't at index 0
        // (so scoped names starting with '@' are handled correctly).
        return res.stdout.split(separator: "\n").compactMap { line -> InstalledPackage? in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard let at = s.lastIndex(of: "@"), at != s.startIndex else { return nil }
            let name = String(s[..<at])
            let version = String(s[s.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            return InstalledPackage(name: name, version: version.isEmpty ? "unknown" : version, manager: .bun, installedAt: nil)
        }
    }

    public func outdated() async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        var out: [OutdatedPackage] = []
        for pkg in installed {
            guard let doc: NpmPackument = try? await http.getJSON("https://registry.npmjs.org/\(pkg.name)", as: NpmPackument.self),
                  let latest = doc.distTags?.latest else { continue }
            if pkg.version != latest { out.append(OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .bun)) }
        }
        return out
    }
}
