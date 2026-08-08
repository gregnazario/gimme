import Foundation

/// v2 gimme configuration. Holds the manager priority list and which managers
/// are enabled. Persisted to ~/.config/gimme/config.toml.
public struct Config: Codable, Equatable {
    /// Ordered list of manager IDs consulted by the Resolver when no
    /// remembered preference applies. Default order per the design spec.
    public var priority: [String]
    /// Manager IDs explicitly disabled by the user (skipped by Resolver/Registry).
    public var disabled: [String]
    /// Cache TTL in seconds for list/outdated operations.
    public var listCacheTTLSeconds: Int
    /// Cache TTL in seconds for info/search operations.
    public var infoCacheTTLSeconds: Int

    public init(
        priority: [String] = ["homebrew", "go", "uv", "cargo", "bun"],
        disabled: [String] = [],
        listCacheTTLSeconds: Int = 300,
        infoCacheTTLSeconds: Int = 3600
    ) {
        self.priority = priority
        self.disabled = disabled
        self.listCacheTTLSeconds = listCacheTTLSeconds
        self.infoCacheTTLSeconds = infoCacheTTLSeconds
    }

    public static let defaults = Config()

    public static func loadOrCreate(at path: URL) -> Config {
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let parsed = try? TOML.parseData(data),
              let cfg = decode(from: parsed) else {
            return .defaults
        }
        return cfg
    }

    static func decode(from root: TOMLTable) -> Config? {
        var c = Config()
        if let p = root.array("priority") {
            c.priority = p.compactMap { $0.asString }
        }
        if let d = root.array("disabled") {
            c.disabled = d.compactMap { $0.asString }
        }
        if let list = root.integer("listCacheTTLSeconds") { c.listCacheTTLSeconds = list }
        if let info = root.integer("infoCacheTTLSeconds") { c.infoCacheTTLSeconds = info }
        return c
    }

    public func toTOML() -> String {
        var lines: [String] = []
        lines.append("priority = [\(priority.map { "\"\($0)\"" }.joined(separator: ", "))]")
        lines.append("disabled = [\(disabled.map { "\"\($0)\"" }.joined(separator: ", "))]")
        lines.append("listCacheTTLSeconds = \(listCacheTTLSeconds)")
        lines.append("infoCacheTTLSeconds = \(infoCacheTTLSeconds)")
        return lines.joined(separator: "\n") + "\n"
    }
}
