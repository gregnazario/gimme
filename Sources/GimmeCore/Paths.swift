import Foundation

/// Resolves all gimme on-disk locations. v2 uses XDG-ish paths under the home
/// directory: config in ~/.config/gimme, cache in ~/.cache/gimme.
public struct GimmePaths: Equatable {
    public let configDir: URL
    public let cacheDir: URL

    public init(configDir: URL, cacheDir: URL) {
        self.configDir = configDir
        self.cacheDir = cacheDir
    }

    public var configFile: URL { configDir.appendingPathComponent("config.toml") }
    public var preferencesFile: URL { configDir.appendingPathComponent("preferences.toml") }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Default user locations: ~/.config/gimme and ~/.cache/gimme.
    public static var defaultUser: GimmePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return GimmePaths(
            configDir: home.appendingPathComponent(".config/gimme"),
            cacheDir: home.appendingPathComponent(".cache/gimme")
        )
    }
}
