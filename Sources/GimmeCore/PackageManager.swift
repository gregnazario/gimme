import Foundation

/// Stable identifier for a package manager backend.
public enum ManagerID: String, Hashable, Codable, CaseIterable {
    case homebrew, go, uv, cargo, bun

    /// Display name shown in the GUI (e.g. "Homebrew", "npm (via bun)").
    public var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .go:       return "Go"
        case .uv:       return "Python (uv)"
        case .cargo:    return "Cargo"
        case .bun:      return "npm (via bun)"
        }
    }

    /// SF Symbol name for the GUI.
    public var iconName: String {
        switch self {
        case .homebrew: return "cup.and.saucer.fill"
        case .go:       return "building.columns"
        case .uv:       return "snake"
        case .cargo:    return "shippingbox"
        case .bun:      return "bag"
        }
    }
}

/// Operations a package manager can support. Not every backend supports every op.
public enum Capability: String, Hashable, Codable {
    case install, uninstall, upgrade, list, outdated, search, info, bootstrap
}

/// How we address a package across the system.
public struct PackageRef: Hashable, Codable {
    /// Package name or import path. For Go this is e.g. "github.com/spf13/cobra".
    /// For scoped npm packages, "babel/core" or "@babel/core".
    public let name: String
    /// Set when the user used --from. The Resolver honors it and records a
    /// remembered preference on successful install.
    public let managerHint: ManagerID?

    public init(name: String, managerHint: ManagerID? = nil) {
        self.name = name
        self.managerHint = managerHint
    }
}
