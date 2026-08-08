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

/// A package installed on the system. ID is manager-namespaced so the same
/// name on two managers never collides in a unified list.
public struct InstalledPackage: Identifiable, Hashable, Codable {
    public let name: String
    public let version: String
    public let manager: ManagerID
    public let installedAt: Date?

    public init(name: String, version: String, manager: ManagerID, installedAt: Date?) {
        self.name = name
        self.version = version
        self.manager = manager
        self.installedAt = installedAt
    }

    public var id: String { "\(manager.rawValue):\(name)" }
}

/// A package with a newer version available.
public struct OutdatedPackage: Identifiable, Hashable, Codable {
    public let name: String
    public let installedVersion: String
    public let latestVersion: String
    public let manager: ManagerID

    public init(name: String, installedVersion: String, latestVersion: String, manager: ManagerID) {
        self.name = name
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.manager = manager
    }

    public var id: String { "\(manager.rawValue):\(name)" }
}

/// A single search result.
public struct SearchHit: Identifiable, Hashable, Codable {
    public let name: String
    public let manager: ManagerID
    public let summary: String
    public let latestVersion: String

    public init(name: String, manager: ManagerID, summary: String, latestVersion: String) {
        self.name = name
        self.manager = manager
        self.summary = summary
        self.latestVersion = latestVersion
    }

    public var id: String { "\(manager.rawValue):\(name)" }
}

/// Full info about a package (installed or not).
public struct PackageInfo: Hashable, Codable {
    public let name: String
    public let manager: ManagerID
    public let latestVersion: String
    public let summary: String
    public let homepage: String?
    public let license: String?
    public let installedVersion: String?
    public let location: String?

    public init(name: String, manager: ManagerID, latestVersion: String, summary: String,
                homepage: String?, license: String?, installedVersion: String?, location: String?) {
        self.name = name
        self.manager = manager
        self.latestVersion = latestVersion
        self.summary = summary
        self.homepage = homepage
        self.license = license
        self.installedVersion = installedVersion
        self.location = location
    }
}

/// Options passed to install().
public struct InstallOptions: Hashable, Codable {
    public let version: String?   // pin to a version if the manager supports it
    public let yes: Bool          // non-interactive: skip prompts
    public init(version: String? = nil, yes: Bool = false) {
        self.version = version
        self.yes = yes
    }
}

/// Result of an install.
public struct InstallResult: Hashable, Codable {
    public let package: InstalledPackage
    public let warnings: [String]  // e.g. "library package — no CLI entry"
    public init(package: InstalledPackage, warnings: [String] = []) {
        self.package = package
        self.warnings = warnings
    }
}

/// The single seam every backend conforms to. The engine and UI talk only
/// through this interface (spec §4).
public protocol PackageManager {
    var id: ManagerID { get }
    var displayName: String { get }
    var icon: String { get }
    var capabilities: Set<Capability> { get }

    func isAvailable() -> Bool
    func bootstrap() async throws

    func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult
    func uninstall(_ package: PackageRef) async throws
    func upgrade(_ package: PackageRef) async throws
    func listInstalled() async throws -> [InstalledPackage]
    func outdated() async throws -> [OutdatedPackage]
    func search(_ query: String) async throws -> [SearchHit]
    func info(_ package: PackageRef) async throws -> PackageInfo
}
