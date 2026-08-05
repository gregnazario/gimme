import Foundation

public struct TapConfig: Codable, Equatable {
    public var url: String
    public var enabled: Bool = true
    public init(url: String, enabled: Bool = true) {
        self.url = url
        self.enabled = enabled
    }
}

public struct Config: Codable, Equatable {
    public struct Behavior: Codable, Equatable {
        public var autoUpdateCheck: Bool = true
        public var pruneOldVersions: Bool = false
        public init(autoUpdateCheck: Bool = true, pruneOldVersions: Bool = false) {
            self.autoUpdateCheck = autoUpdateCheck
            self.pruneOldVersions = pruneOldVersions
        }
    }

    public struct Cache: Codable, Equatable {
        public var maxAgeHours: Int = 1
        public init(maxAgeHours: Int = 1) { self.maxAgeHours = maxAgeHours }
    }

    public var behavior = Behavior()
    public var cache = Cache()
    public var taps: [String: TapConfig] = [:]

    public init() {}

    public static let defaults = Config()

    /// Load config from a TOML file, returning defaults if the file is missing or unreadable.
    public static func loadOrCreate(at path: URL) -> Config {
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let parsed = try? TOML.parseData(data),
              let cfg = decode(from: parsed) else {
            return .defaults
        }
        return cfg
    }

    /// Decode a Config from a parsed TOML table.
    static func decode(from root: TOMLTable) -> Config? {
        var c = Config()
        if let behavior = root.table("behavior") {
            if let b = behavior.bool("autoUpdateCheck") { c.behavior.autoUpdateCheck = b }
            if let p = behavior.bool("pruneOldVersions") { c.behavior.pruneOldVersions = p }
        }
        if let cache = root.table("cache") {
            if let h = cache.integer("maxAgeHours") { c.cache.maxAgeHours = h }
        }
        if let taps = root.table("taps") {
            for (name, value) in taps.children {
                guard let tap = value.asTable else { continue }
                guard let url = tap.string("url") else { continue }
                let enabled = tap.bool("enabled") ?? true
                c.taps[name] = TapConfig(url: url, enabled: enabled)
            }
        }
        return c
    }

    /// Encode back to a TOML string (for `gimme config Set`).
    /// SECURITY: tap names are validated at `TapStore.add` (charset-restricted),
    /// so they're safe to interpolate into a header. URL strings are escaped so
    /// quotes/backslashes/newlines in a URL cannot break the basic string or
    /// inject TOML structure.
    public func toTOML() -> String {
        var lines: [String] = []
        lines.append("[behavior]")
        lines.append("autoUpdateCheck = \(behavior.autoUpdateCheck)")
        lines.append("pruneOldVersions = \(behavior.pruneOldVersions)")
        lines.append("")
        lines.append("[cache]")
        lines.append("maxAgeHours = \(cache.maxAgeHours)")
        for (name, tap) in taps.sorted(by: { $0.key < $1.key }) {
            lines.append("")
            lines.append("[taps.\(name)]")
            lines.append("url = \"\(escapeBasic(tap.url))\"")
            lines.append("enabled = \(tap.enabled)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escape a string for a TOML basic string: backslash and double-quote,
    /// and strip newlines (which would break the single-line representation).
    /// Tabs are escaped per TOML spec.
    private func escapeBasic(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": continue
            case "\r": continue
            case "\t": out.append("\\t")
            default: out.append(ch)
            }
        }
        return out
    }
}
