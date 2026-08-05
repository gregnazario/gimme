import Foundation

/// A dry-run plan: what an install would do, without doing it. Returned by
/// `Installer.plan()` and rendered for `--dry-run` / the agent contract.
public struct InstallPlan: Codable, Equatable {
    public struct DepPlan: Codable, Equatable {
        public var name: String
        public var version: String
        public var sha256: String
        public var url: String
        public init(name: String, version: String, sha256: String, url: String) {
            self.name = name; self.version = version; self.sha256 = sha256; self.url = url
        }
    }

    public var tool: String
    public var version: String
    public var sha256: String
    public var url: String
    public var arch: String?
    public var os: String?
    public var deps: [DepPlan]
    public var cellarPrefix: String
    public var shim: String
    public var provides: [String]
    public var conflicts: [String]

    public init(tool: String, version: String, sha256: String, url: String,
                arch: String?, os: String?, deps: [DepPlan],
                cellarPrefix: String, shim: String, provides: [String],
                conflicts: [String]) {
        self.tool = tool; self.version = version; self.sha256 = sha256
        self.url = url; self.arch = arch; self.os = os; self.deps = deps
        self.cellarPrefix = cellarPrefix; self.shim = shim; self.provides = provides
        self.conflicts = conflicts
    }

    /// Render as the JSON object consumed by `--json --dry-run` (agent contract).
    public func toJSON() -> [String: Any] {
        return [
            "schema_version": Schema.version,
            "cmd": "plan",
            "ok": true,
            "tool": tool,
            "version": version,
            "sha256": sha256,
            "url": url,
            "arch": arch as Any,
            "os": os as Any,
            "deps": deps.map { $0.toJSON() },
            "cellar_prefix": cellarPrefix,
            "shim": shim,
            "provides": provides,
            "conflicts": conflicts
        ]
    }
}

extension InstallPlan.DepPlan {
    public func toJSON() -> [String: Any] {
        return ["name": name, "version": version, "sha256": sha256, "url": url]
    }
}
