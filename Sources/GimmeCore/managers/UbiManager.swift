import Foundation

/// ubi adapter (spec §7). Universal Binary Installer — downloads GitHub
/// releases by owner/repo. No registry, so no search. No version metadata
/// stored, so list is a best-effort scan of the install dir and outdated is
/// unsupported. System ecosystem.
public final class UbiManager: PackageManager {
    public let id: ManagerID = .ubi
    public let displayName = "ubi"
    public let icon = "wrench.and.screwdriver"
    public let capabilities: Set<Capability> = [.install, .uninstall, .list, .info, .bootstrap]

    private let process: any ProcessRunning
    private let binaryOverride: String?
    private let installDir: String   // where ubi drops binaries (~/.local/bin)

    public init(process: any ProcessRunning = ProcessRunner(),
                binary: String? = nil,
                installDir: String? = nil) {
        self.process = process
        self.binaryOverride = binary
        self.installDir = installDir ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
    }

    private var binaryPath: String {
        binaryOverride ?? BinaryResolver.resolve("ubi", fallback: nil) ?? ""
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("ubi") != nil || binaryOverride != nil
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "brew install ubi || cargo install ubi"],
            env: nil, stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    }

    /// No search — ubi has no registry.
    public func search(_ query: String) async throws -> [SearchHit] { [] }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        // Best-effort: homepage is the GitHub repo; no metadata without API calls.
        let installed = try await listInstalled()
        let binaryName = ubiBinaryName(for: package.name)
        let isInstalled = installed.contains { $0.name == binaryName }
        return PackageInfo(name: package.name, manager: .ubi,
            latestVersion: "",
            summary: isInstalled ? "installed via ubi" : "GitHub release installer",
            homepage: "https://github.com/\(package.name)", license: nil,
            installedVersion: isInstalled ? "unknown" : nil, location: nil)
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        var args = ["--project", package.name]
        if let v = options.version { args += ["--tag", v] }
        let res = try await process.run(binaryPath, args: args, env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .ubi, op: "install", underlying: res.stderr) }
        return InstallResult(package: InstalledPackage(name: package.name, version: options.version ?? "latest", manager: .ubi, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        // ubi has no uninstall; remove the binary from the install dir.
        guard let binaryName = safeBinaryName(ubiBinaryName(for: package.name)) else {
            throw GimmeError.notFound("unsafe binary name derived from '\(package.name)'")
        }
        let target = URL(fileURLWithPath: installDir).appendingPathComponent(binaryName)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw GimmeError.notFound("\(binaryName) not found in \(installDir)")
        }
        try FileManager.default.removeItem(at: target)
    }

    public func upgrade(_ package: PackageRef) async throws {
        // Re-run ubi to fetch the latest release.
        _ = try await install(package, options: InstallOptions())
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        // Best-effort scan of the install dir. ubi doesn't keep a manifest, so
        // we can't distinguish ubi-installed binaries from others — we list
        // everything that's executable. Same limitation shape as the Go adapter.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: installDir) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.map {
            InstalledPackage(name: $0, version: "unknown", manager: .ubi, installedAt: nil)
        }
    }

    public func outdated() async throws -> [OutdatedPackage] { [] }  // not supported

    /// Derive the on-disk binary name from an owner/repo spec: last segment.
    private func ubiBinaryName(for spec: String) -> String {
        if let last = spec.split(separator: "/").last { return String(last) }
        return spec
    }
}
