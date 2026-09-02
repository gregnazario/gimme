import Foundation

/// aqua adapter (spec §7). Declarative CLI-version manager (aqua.yaml); the
/// adapter models the standard imperative `aqua install/list/rm` flow — the
/// declarative yaml is aqua's internal concern. System ecosystem. Packages are
/// `owner/repo`. No outdated (versions pinned in config). No fuzzy search.
public final class AquaManager: PackageManager, Sendable {
    public let id: ManagerID = .aqua
    public let displayName = "aqua"
    public let icon = "drop.fill"
    public let capabilities: Set<Capability> = [.install, .uninstall, .list, .search, .info, .bootstrap]

    private let process: any ProcessRunning
    private let binaryOverride: String?

    public init(process: any ProcessRunning = ProcessRunner(),
                binary: String? = nil) {
        self.process = process
        self.binaryOverride = binary
    }

    private var binaryPath: String {
        binaryOverride ?? BinaryResolver.resolve("aqua", fallback: nil) ?? ""
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("aqua") != nil || binaryOverride != nil
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "brew install aquaproj/aqua/aqua"],
            env: nil, stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    }

    /// Exact-existence only: aqua has no fuzzy search. Returns a single hit if
    /// the package is already installed (i.e. appears in `aqua list`).
    public func search(_ query: String) async throws -> [SearchHit] {
        let installed = try await listInstalled()
        return installed.contains { $0.name == query }
            ? [SearchHit(name: query, manager: .aqua, summary: "", latestVersion: "")]
            : []
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        // Best-effort: report from the installed list, or a GitHub homepage.
        let installed = try await listInstalled()
        let match = installed.first { $0.name == package.name }
        return PackageInfo(name: package.name, manager: .aqua,
            latestVersion: match?.version ?? "",
            summary: match.map { _ in "installed via aqua" } ?? "not installed via aqua",
            homepage: "https://github.com/\(package.name)", license: nil,
            installedVersion: match?.version, location: nil)
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res = try await process.run(binaryPath, args: ["install", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .aqua, op: "install", underlying: res.stderr) }
        return InstallResult(package: InstalledPackage(name: package.name, version: options.version ?? "latest", manager: .aqua, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["rm", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .aqua, op: "uninstall", underlying: res.stderr) }
    }

    public func upgrade(_ package: PackageRef) async throws {
        // No separate upgrade; re-install.
        _ = try await install(package, options: InstallOptions())
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        // `aqua list` output: "owner/repo" or "owner/repo@version".
        let res = try await process.run(binaryPath, args: ["list"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        return res.stdout.split(separator: "\n").compactMap { line -> InstalledPackage? in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            if let at = s.lastIndex(of: "@") {
                let name = String(s[..<at])
                let version = String(s[s.index(after: at)...])
                return InstalledPackage(name: name, version: version, manager: .aqua, installedAt: nil)
            }
            return InstalledPackage(name: s, version: "unknown", manager: .aqua, installedAt: nil)
        }
    }

    public func outdated() async throws -> [OutdatedPackage] { [] }  // not supported
}
