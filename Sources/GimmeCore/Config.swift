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
    /// Post a macOS notification when an update run finishes and the app is in
    /// the background (GUI only; see UpdateNotifier). Default on.
    public var notifyUpdates: Bool
    /// Per-ecosystem recommended provider for consolidation (spec §5). Separate
    /// from priority (install routing). Persisted under [ecosystems].
    public var ecosystems: EcosystemPreferences

    public init(
        priority: [String] = ["homebrew", "go", "uv", "cargo", "bun", "npm", "pnpm", "yarn", "gem", "composer", "deno", "pipx", "aqua", "ubi"],
        disabled: [String] = [],
        listCacheTTLSeconds: Int = 300,
        infoCacheTTLSeconds: Int = 3600,
        notifyUpdates: Bool = true,
        ecosystems: EcosystemPreferences = EcosystemPreferences()
    ) {
        self.priority = priority
        self.disabled = disabled
        self.listCacheTTLSeconds = listCacheTTLSeconds
        self.infoCacheTTLSeconds = infoCacheTTLSeconds
        self.notifyUpdates = notifyUpdates
        self.ecosystems = ecosystems
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
            // Dedupe: duplicate ids would crash SwiftUI ForEach in Preferences
            // and double-walk the resolver's priority scan.
            c.priority = Array(NSOrderedSet(array: p.compactMap { $0.asString })) as! [String]
        }
        if let d = root.array("disabled") {
            c.disabled = Array(NSOrderedSet(array: d.compactMap { $0.asString })) as! [String]
        }
        if let list = root.integer("listCacheTTLSeconds") { c.listCacheTTLSeconds = list }
        if let info = root.integer("infoCacheTTLSeconds") { c.infoCacheTTLSeconds = info }
        if let notify = root.bool("notifyUpdates") { c.notifyUpdates = notify }
        // [ecosystems] table: { js = "bun", python = "uv", ... }
        if let ecoTable = root.table("ecosystems") {
            var prefs: [Ecosystem: ManagerID] = [:]
            for (ecoRaw, value) in ecoTable.children {
                guard let eco = Ecosystem(rawValue: ecoRaw),
                      let mgrRaw = value.asString,
                      let mgr = ManagerID(rawValue: mgrRaw) else { continue }
                prefs[eco] = mgr
            }
            c.ecosystems = EcosystemPreferences(prefs)
        }
        return c
    }

    public func toTOML() -> String {
        var lines: [String] = []
        lines.append("priority = [\(priority.map { "\"\($0)\"" }.joined(separator: ", "))]")
        lines.append("disabled = [\(disabled.map { "\"\($0)\"" }.joined(separator: ", "))]")
        lines.append("listCacheTTLSeconds = \(listCacheTTLSeconds)")
        lines.append("infoCacheTTLSeconds = \(infoCacheTTLSeconds)")
        lines.append("notifyUpdates = \(notifyUpdates)")
        if !ecosystems.preferences.isEmpty {
            lines.append("")
            lines.append("[ecosystems]")
            for (eco, mgr) in ecosystems.preferences.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                lines.append("\(eco.rawValue) = \"\(mgr.rawValue)\"")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
