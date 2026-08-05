import Foundation

/// Resolves all gimme on-disk locations relative to a prefix (default ~/.gimme).
/// `--prefix` overrides this in tests and for self-contained installs.
public struct GimmePaths: Equatable {
    public let prefix: URL

    public init(prefix: URL) {
        self.prefix = prefix
    }

    public var bin: URL { prefix.appendingPathComponent("bin") }
    public var cellar: URL { prefix.appendingPathComponent("cellar") }
    public var cache: URL { prefix.appendingPathComponent("cache") }
    public var taps: URL { prefix.appendingPathComponent("taps") }
    public var staging: URL { prefix.appendingPathComponent("staging") }
    public var state: URL { prefix.appendingPathComponent("state") }
    public var logs: URL { prefix.appendingPathComponent("logs") }
    public var configFile: URL { prefix.appendingPathComponent("config.toml") }

    /// Lazy (and only just-in-time) directory creation. Idempotent.
    public func ensureDirectories() throws {
        let fm = FileManager.default
        for d in [bin, cellar, cache, taps, staging, state, logs] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// The default user prefix: ~/.gimme
    public static var defaultUserPrefix: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".gimme")
    }
}
