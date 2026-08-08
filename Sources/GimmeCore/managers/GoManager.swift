import Foundation

/// Go adapter (spec §6.2). Uses the module proxy for existence/info and
/// `go install` for actions. No outdated, no fuzzy search.
public final class GoManager: PackageManager {
    public let id: ManagerID = .go
    public let displayName = "Go"
    public let icon = "building.columns"
    public let capabilities: Set<Capability> = [.install, .uninstall, .list, .info, .bootstrap]

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let goBinary: String

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                goBinary: String = "/usr/local/go/bin/go") {
        self.http = http
        self.process = process
        self.goBinary = goBinary
    }

    public func isAvailable() -> Bool {
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["go"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return false }
        return proc.terminationStatus == 0
    }

    public func bootstrap() async throws {
        _ = try await process.run("/bin/bash",
            args: ["-c", "curl -fsSL https://go.dev/dl/go1.23.0.darwin-arm64.pkg -o /tmp/go.pkg && sudo installer -pkg /tmp/go.pkg -target /"],
            env: nil, stream: nil)
    }

    /// Existence check via proxy @latest. Used by Resolver; also backs search.
    private func proxyLatest(_ path: String) async -> String? {
        let url = "https://proxy.golang.org/\(path)/@latest"
        struct Latest: Decodable { let Version: String }
        guard let v: Latest = try? await http.getJSON(url, as: Latest.self) else { return nil }
        return v.Version
    }

    /// Exact-existence search only: a single hit if the proxy knows the path.
    public func search(_ query: String) async throws -> [SearchHit] {
        guard let v = await proxyLatest(query) else { return [] }
        return [SearchHit(name: query, manager: .go, summary: "", latestVersion: v)]
    }

    public func info(_ package: PackageRef) async throws -> PackageInfo {
        guard let v = await proxyLatest(package.name) else {
            throw GimmeError.notFoundInManagers(name: package.name, searched: [.go])
        }
        return PackageInfo(name: package.name, manager: .go, latestVersion: v, summary: "",
            homepage: "https://pkg.go.dev/\(package.name)", license: nil, installedVersion: nil, location: nil)
    }

    public func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult {
        let target = options.version.map { "\(package.name)@\($0)" } ?? "\(package.name)@latest"
        let res = try await process.run(goBinary, args: ["install", target], env: nil, stream: nil)
        guard res.exitCode == 0 else {
            throw GimmeError.operationFailed(manager: .go, op: "install", underlying: res.stderr)
        }
        let binary = goBinaryName(for: package.name)
        return InstallResult(package: InstalledPackage(name: package.name, version: "latest", manager: .go, installedAt: Date()),
                             warnings: binary.isEmpty ? ["no binary name derivable"] : [])
    }

    public func uninstall(_ package: PackageRef) async throws {
        // `go` provides no uninstall; remove the binary from GOBIN.
        let gobin = ProcessInfo.processInfo.environment["GOBIN"]
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/go/bin")
        let binary = goBinaryName(for: package.name)
        let target = URL(fileURLWithPath: gobin).appendingPathComponent(binary)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw GimmeError.notFound("\(binary) not found in GOBIN")
        }
        try FileManager.default.removeItem(at: target)
    }

    /// Derive the installed binary name from a Go import path: the last segment.
    private func goBinaryName(for importPath: String) -> String {
        if let last = importPath.split(separator: "/").last { return String(last) }
        return importPath
    }

    public func upgrade(_ package: PackageRef) async throws {
        // Re-install to latest.
        _ = try await install(package, options: InstallOptions())
    }

    public func listInstalled() async throws -> [InstalledPackage] {
        let gobin = ProcessInfo.processInfo.environment["GOBIN"]
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/go/bin")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: gobin) else { return [] }
        return names.map { InstalledPackage(name: $0, version: "unknown", manager: .go, installedAt: nil) }
    }

    public func outdated() async throws -> [OutdatedPackage] { [] }  // not supported
}
