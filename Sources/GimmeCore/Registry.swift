import Foundation

/// Holds all package-manager adapters and answers availability/enabled
/// queries (spec §3.2). Production wires the five real adapters; tests inject
/// stubs.
public final class Registry {
    public let managers: [any PackageManager]

    public init(managers: [any PackageManager]) {
        self.managers = managers
    }

    /// All adapters that are installed on this system right now.
    public func available() -> [any PackageManager] {
        managers.filter { $0.isAvailable() }
    }

    /// Adapters that are both installed and not disabled in config.
    public func enabled(config: Config) -> [any PackageManager] {
        available().filter { !config.disabled.contains($0.id.rawValue) }
    }

    /// Look up a single adapter by ID.
    public func get(_ id: ManagerID) -> (any PackageManager)? {
        managers.first { $0.id == id }
    }
}
