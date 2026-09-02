import Foundation

/// Deno adapter. Deno installs global scripts/binaries from JSR (jsr.io) or npm
/// via `deno install -g <spec>`, placing executables in ~/.deno/bin. This is a
/// distinct global installer — not "npm-based" — with its own registries.
///
/// `outdated` is unsupported (Deno's global installs don't track installed
/// version metadata; like the Go adapter, we list binaries without versions).
public final class DenoManager: PackageManager, Sendable {
    public let id: ManagerID = .deno
    public let displayName = "Deno"
    public let icon = "globe"
    public let capabilities: Set<Capability> = [.install, .uninstall, .list, .search, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let binaryOverride: String?
    private let denoBinDir: String   // where global binaries live (~/.deno/bin)

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                binary: String? = nil,
                denoBinDir: String? = nil) {
        self.http = http
        self.process = process
        self.binaryOverride = binary
        self.denoBinDir = denoBinDir ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.deno/bin"
    }

    private var binaryPath: String {
        binaryOverride ?? BinaryResolver.resolve("deno", fallback: nil) ?? ""
    }

    public func isAvailable() -> Bool {
        BinaryResolver.resolve("deno") != nil || binaryOverride != nil
    }

    public func bootstrap() async throws {
        // Official standalone installer.
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -fsSL https://deno.land/install.sh | sh"],
            env: nil, stream: nil)
    }

    public func version() async -> String? {
        guard isAvailable() else { return nil }
        let res = try? await process.run(binaryPath, args: ["--version"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else { return nil }
        return res.stdout.split(separator: "\n").first.map(String.init)
    }

    // MARK: - Search / Info (JSR registry)

    /// JSR search response: { items: [ { scope, name, description, latestVersion } ] }
    private struct JSRSearchResponse: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let scope: String
            let name: String
            let description: String?
            let latestVersion: String?
            /// The full JSR package name is "@scope/name".
            var fullName: String { "@\(scope)/\(name)" }
        }
    }

    public func search(_ query: String) async throws -> [SearchHit] {
        guard let doc: JSRSearchResponse = try? await http.getJSON("https://jsr.io/api/packages?search=\(query)", as: JSRSearchResponse.self) else { return [] }
        return doc.items.map { item in
            SearchHit(name: item.fullName, manager: .deno,
                      summary: item.description ?? "",
                      latestVersion: item.latestVersion ?? "")
        }
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        // JSR's search endpoint doubles as a lookup: search by the full name
        // and pick the exact match.
        guard let doc: JSRSearchResponse = try? await http.getJSON("https://jsr.io/api/packages?search=\(package.name)", as: JSRSearchResponse.self),
              let item = doc.items.first(where: { $0.fullName == package.name }) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.deno])
        }
        return PackageInfo(name: item.fullName, manager: .deno,
            latestVersion: item.latestVersion ?? "", summary: item.description ?? "",
            homepage: "https://jsr.io/\(item.fullName)", license: nil,
            installedVersion: nil, location: nil)
    }

    // MARK: - Actions (deno CLI)

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        // Deno specs: "jsr:@scope/name" or "npm:package". If the caller gave a
        // bare "@scope/name" (from our own search), prefix jsr:.
        let spec: String
        if package.name.hasPrefix("jsr:") || package.name.hasPrefix("npm:") {
            spec = package.name
        } else if package.name.hasPrefix("@") {
            spec = "jsr:\(package.name)"
        } else {
            spec = package.name
        }
        let res = try await process.run(binaryPath, args: ["install", "-g", spec], env: nil, stream: nil)
        guard res.exitCode == 0 else { throw GimmeError.operationFailed(manager: .deno, op: "install", underlying: res.stderr) }
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .deno, installedAt: Date()))
    }

    public func uninstall(_ package: PackageRef) async throws {
        // Deno has no uninstall command; remove the binary from ~/.deno/bin.
        // The binary name is the package's last path segment (or a -n override
        // we can't know), so we attempt the most likely name.
        guard let binaryName = safeBinaryName(denoBinaryName(for: package.name)) else {
            throw GimmeError.notFound("unsafe binary name derived from '\(package.name)'")
        }
        let target = URL(fileURLWithPath: denoBinDir).appendingPathComponent(binaryName)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw GimmeError.notFound("\(binaryName) not found in \(denoBinDir)")
        }
        try FileManager.default.removeItem(at: target)
    }

    public func upgrade(_ package: PackageRef) async throws {
        // Re-install to latest.
        _ = try await install(package, options: InstallOptions())
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: denoBinDir) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.map {
            InstalledPackage(name: $0, version: "unknown", manager: .deno, installedAt: nil)
        }
    }

    public func outdated() async throws -> [OutdatedPackage] { [] }  // not supported

    /// Derive the on-disk binary name from a Deno package spec. For
    /// "jsr:@scope/http" this is the last segment after the final "/".
    private func denoBinaryName(for spec: String) -> String {
        // Strip registry prefixes.
        let stripped = spec
            .replacingOccurrences(of: "jsr:", with: "")
            .replacingOccurrences(of: "npm:", with: "")
        if let last = stripped.split(separator: "/").last { return String(last) }
        return stripped
    }
}
