import Foundation

/// Installs or updates the `gimme` command-line tool on this machine, shared
/// by the GUI's "Install Command-Line Tool…" menu command. The download,
/// checksum verification, and atomic replace are delegated to `SelfUpdate`
/// (same release assets as `gimme update --self`); this type adds the
/// locate-existing / decide-outcome / install-dir plumbing around it.
///
/// A fresh install goes to `~/.local/bin/gimme` — the same location
/// install.sh documents — so no root is needed and both entry points agree.
public final class CLIToolInstaller {
    public enum Outcome: Equatable {
        case installed(version: String)
        case updated(from: String, to: String)
        case upToDate(version: String)

        /// Human sentence for alerts/activity logs (path appended by callers).
        public var message: String {
            switch self {
            case .installed(let v):  return "Installed gimme \(v)"
            case .updated(let from, let to): return "Updated gimme \(from) → \(to)"
            case .upToDate(let v):   return "gimme \(v) is already installed and up to date"
            }
        }
    }

    private let updater: SelfUpdate
    private let process: any ProcessRunning
    /// Where a fresh install goes (~/.local/bin/gimme by default).
    public let defaultTarget: URL
    /// Finds an existing gimme binary on this machine (PATH first), or nil.
    private let locate: () -> String?

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                installDir: URL? = nil,
                locate: (() -> String?)? = nil) {
        self.updater = SelfUpdate(http: http, process: process)
        self.process = process
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.defaultTarget = (installDir ?? home.appendingPathComponent(".local/bin"))
            .appendingPathComponent("gimme")
        self.locate = locate ?? { BinaryResolver.resolve("gimme") }
    }

    /// The version an installed gimme reports (`gimme --version` → "2.3.2"),
    /// or nil when missing/broken/unreadable.
    public func installedVersion(at path: String) async -> String? {
        guard let result = try? await process.run(path, args: ["--version"], env: nil, stream: nil),
              result.exitCode == 0 else { return nil }
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gimme ") else { return nil }
        let version = String(line.dropFirst("gimme ".count))
        return version.isEmpty ? nil : version
    }

    /// Install the latest release, updating an existing copy in place, or
    /// reporting up-to-date (no download when the located binary already
    /// reports the released version). Throws when the check fails or the
    /// target isn't writable.
    @discardableResult
    public func installOrUpdate(progress: ((String) -> Void)? = nil) async throws -> Outcome {
        guard let release = await updater.latestRelease() else {
            throw GimmeError.network("could not check https://github.com/gregnazario/gimme/releases/latest")
        }

        let existingPath = locate()
        let target = existingPath.map { URL(fileURLWithPath: $0) } ?? defaultTarget
        let oldVersion = existingPath == nil ? nil : await installedVersion(at: target.path)

        // Already current? Skip download and replacement entirely.
        // isNewer(candidate:than:) — the RELEASE is newer than what's installed.
        if let old = oldVersion, !SelfUpdate.isNewer(release.version, than: old) {
            return .upToDate(version: old)
        }

        // Fresh installs need their parent dir; updateCLI assumes it exists.
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        _ = try await updater.updateCLI(at: target, to: release, progress: progress)
        if let old = oldVersion { return .updated(from: old, to: release.version) }
        return .installed(version: release.version)
    }

    /// True when `dir` appears in PATH — used for install guidance ("add it
    /// to your shell profile"). `pathEnv` is injectable for tests.
    public static func isOnPATH(_ dir: String, pathEnv: String? = nil) -> Bool {
        let path = pathEnv ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { $0 == dir }
    }
}
