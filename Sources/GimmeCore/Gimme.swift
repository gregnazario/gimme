import Foundation

/// The gimme command runner. The CLI is a thin wrapper over this; tests call
/// it in-process. Fleshed out in Phase 7.
public final class Gimme {
    public init() {}

    /// Run a command. Stub — real dispatch added in Phase 7.
    public func run(command: String, args: [String]) throws {
        // Phase 7 implements install/uninstall/update/list/outdated/search/info/doctor/config/forget + passthrough
    }
}

extension Gimme {
    /// Wire the five real adapters with production defaults.
    public static func defaultRegistry() -> Registry {
        Registry(managers: [
            HomebrewManager(),
            GoManager(),
            UvManager(),
            CargoManager(),
            BunManager()
        ])
    }
}

