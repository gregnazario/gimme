import Foundation

/// uv (Python) adapter (spec §6.3). Per-tool isolated venvs via `uv tool`.
public final class UvManager: PackageManager {
    public let id: ManagerID = .uv
    public let displayName = "Python (uv)"
    public let icon = "snake"
    public let capabilities: Set<Capability> = [.install, .uninstall, .upgrade, .list, .outdated, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let uvBinaryOverride: String?   // nil = resolve via `which uv`

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                uvBinary: String? = nil) {
        self.http = http
        self.process = process
        self.uvBinaryOverride = uvBinary
    }

    /// Resolve the real uv path (via `which uv`), or use the injected override.
    private var binaryPath: String {
        uvBinaryOverride ?? BinaryResolver.resolve("uv", fallback: "/opt/uv/bin/uv") ?? "/opt/uv/bin/uv"
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("uv") != nil || uvBinaryOverride != nil
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"],
            env: nil, stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)
    }

    private struct PyPIDoc: Decodable {
        let info: Info
        struct Info: Decodable { let name: String; let summary: String?; let home_page: String?; let license: String?; let version: String? }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        guard let doc: PyPIDoc = try? await http.getJSON("https://pypi.org/pypi/\(query)/json", as: PyPIDoc.self) else { return [] }
        return [SearchHit(name: doc.info.name, manager: .uv, summary: doc.info.summary ?? "", latestVersion: doc.info.version ?? "")]
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let doc: PyPIDoc = try? await http.getJSON("https://pypi.org/pypi/\(package.name)/json", as: PyPIDoc.self) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.uv])
        }
        return PackageInfo(name: doc.info.name, manager: .uv, latestVersion: doc.info.version ?? "",
            summary: doc.info.summary ?? "", homepage: doc.info.home_page, license: doc.info.license,
            installedVersion: nil, location: nil)
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let res = try await process.run(binaryPath, args: ["tool", "install", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .uv, op: "install", underlying: res.stderr) }
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .uv, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["tool", "uninstall", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .uv, op: "uninstall", underlying: res.stderr) }
    }

    public func upgrade(_ package: PackageRef) async throws {
        let res = try await process.run(binaryPath, args: ["tool", "upgrade", package.name], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .uv, op: "upgrade", underlying: res.stderr) }
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        let res = try await process.run(binaryPath, args: ["tool", "list"], env: nil, stream: nil)
        guard res.exitCode == 0 else { return [] }
        // Lines like: "httpie (executable: http)"
        return res.stdout.split(separator: "\n").compactMap { line -> InstalledPackage? in
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard let name = s.split(separator: " ").first, !name.isEmpty else { return nil }
            return InstalledPackage(name: String(name), version: "unknown", manager: .uv, installedAt: nil)
        }
    }

    public func outdated() async throws -> [OutdatedPackage] {
        let installed = try await listInstalled()
        return await withTaskGroup(of: OutdatedPackage?.self) { group in
            for pkg in installed {
                group.addTask {
                    guard let doc: PyPIDoc = try? await self.http.getJSON("https://pypi.org/pypi/\(pkg.name)/json", as: PyPIDoc.self),
                          let latest = doc.info.version else { return nil }
                    // We don't have installed version reliably from `uv tool list`;
                    // mark outdated only if names differ (best-effort). Real version
                    // comparison added when `uv tool list --json` is available.
                    return pkg.version != latest ? OutdatedPackage(name: pkg.name, installedVersion: pkg.version, latestVersion: latest, manager: .uv) : nil
                }
            }
            var out: [OutdatedPackage] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }
}
