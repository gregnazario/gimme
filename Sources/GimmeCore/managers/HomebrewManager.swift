import Foundation

/// Homebrew adapter (spec §6.1). Uses the formulae.brew.sh JSON API for
/// search/info and the `brew` CLI for actions + list/outdated.
public final class HomebrewManager: PackageManager {
    public let id: ManagerID = .homebrew
    public let displayName = "Homebrew"
    public let icon = "cup.and.saucer.fill"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let brewBinary: String

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                brewBinary: String = "/opt/homebrew/bin/brew") {
        self.http = http
        self.process = process
        self.brewBinary = brewBinary
    }

    public func isAvailable() -> Bool {
        // Synchronous: `which brew`. Blocking but cheap.
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["brew"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        return proc.terminationStatus == 0
    }

    public func bootstrap() async throws {
        let script = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -fsSL \(script) | /bin/bash"],
            env: ["NONINTERACTIVE": "1"],
            stream: nil)
    }

    // MARK: - Search / Info (API-backed)

    private struct FormulaAPIDoc: Decodable {
        let name: String
        let desc: String?
        let versions: Versions?
        struct Versions: Decodable { let stable: String? }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        let docs: [FormulaAPIDoc] = try await http.getJSON("https://formulae.brew.sh/api/formula.json", as: [FormulaAPIDoc].self)
        return docs.filter { $0.name.contains(query) }.map {
            SearchHit(name: $0.name, manager: .homebrew, summary: $0.desc ?? "", latestVersion: $0.versions?.stable ?? "")
        }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        // Prefer the local brew info --json=v2 for installed-version accuracy.
        let res = try await process.run(brewBinary, args: ["info", "--json=v2", package.name], env: nil, stream: nil)
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
        let res = try await process.run(brewBinary, args: ["install", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .homebrew, op: "install", underlying: res.stderr)
        }
        let version = (try? await installedVersion(of: package.name)) ?? "unknown"
        return InstallResult(package: InstalledPackage(name: package.name, version: version, manager: .homebrew, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(brewBinary, args: ["uninstall", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .homebrew, op: "uninstall", underlying: res.stderr)
        }
    }

    public func upgrade(_ package: PackageRef) async throws {
        let res = try await process.run(brewBinary, args: ["upgrade", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .homebrew, op: "upgrade", underlying: res.stderr)
        }
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        let res = try await process.run(brewBinary, args: ["list", "--json=v2"], env: nil, stream: nil)
        guard res.exitCode == 0, let data = res.stdout.data(using: .utf8) else { return [] }
        struct Wrapper: Decodable {
            let formulae: [Item]; let casks: [Item]
            struct Item: Decodable {
                let name: String; let installed: [Inst]?
                struct Inst: Decodable { let version: String }
            }
        }
        guard let w = try? JSONDecoder().decode(Wrapper.self, from: data) else { return [] }
        let formulas = w.formulae.compactMap { f -> InstalledPackage? in
            guard let v = f.installed?.first?.version else { return nil }
            return InstalledPackage(name: f.name, version: v, manager: .homebrew, installedAt: nil)
        }
        let casks = w.casks.compactMap { c -> InstalledPackage? in
            guard let v = c.installed?.first?.version else { return nil }
            return InstalledPackage(name: c.name, version: v, manager: .homebrew, installedAt: nil)
        }
        return formulas + casks
    }

    public func outdated() async throws -> [OutdatedPackage] {
        let res = try await process.run(brewBinary, args: ["outdated", "--json=v2"], env: nil, stream: nil)
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
