import Foundation

/// Per-ecosystem recommended provider, separate from the install priority list
/// (spec §4/§5). Persisted in config.toml under [ecosystems].
public struct EcosystemPreferences: Codable, Equatable {
    public var preferences: [Ecosystem: ManagerID]
    public init(_ preferences: [Ecosystem: ManagerID] = [:]) { self.preferences = preferences }

    /// The recommended manager for an ecosystem, or a sensible default if unset
    /// (the first manager in that ecosystem's bucket, or homebrew as a last resort).
    public func recommended(for ecosystem: Ecosystem) -> ManagerID {
        preferences[ecosystem] ?? ecosystem.managers.first ?? .homebrew
    }

    public enum CodingKeys: String, CodingKey { case preferences }
    // Codable: [Ecosystem: ManagerID] where both are String-raw enums encodes
    // naturally as a JSON object { "js": "bun", ... }. No custom code needed.
}

/// A package installed in more than one manager within the same ecosystem (spec §4).
public struct Duplicate: Identifiable, Equatable, Codable {
    public let name: String
    public let ecosystem: Ecosystem
    public let installed: [InstalledPackage]   // every manager that has it
    public let recommendedManager: ManagerID   // from preferences
    public var id: String { "\(ecosystem.rawValue):\(name)" }

    /// The packages to migrate AWAY from (everything except the recommended).
    public var toRemove: [InstalledPackage] { installed.filter { $0.manager != recommendedManager } }
}

/// A single migration step the user should run (spec §4). Report + guide only —
/// gimmie never executes these; it prints them for the user to run.
public struct MigrationStep: Equatable, Codable {
    public let duplicate: Duplicate
    public let installCommand: String?        // nil if recommended already has it
    public let uninstallCommands: [String]
}

/// The full consolidation report over an installed-package list (spec §4).
public struct ConsolidationReport: Codable, Equatable {
    public let duplicates: [Duplicate]        // empty if clean
    public let steps: [MigrationStep]         // one per duplicate
    public let cleanEcosystems: [Ecosystem]   // ecosystems with no dups (reported too)
    public var hasDuplicates: Bool { !duplicates.isEmpty }
}

/// Hashable grouping key: (ecosystem, name).
private struct GroupKey: Hashable {
    let ecosystem: Ecosystem
    let name: String
}

/// Pure logic over already-fetched installed-package lists (spec §4). No I/O.
/// Grouping key: (ecosystem, name). A group with >1 distinct manager is a
/// duplicate. Recommended provider comes from EcosystemPreferences.
public struct Consolidator {
    public let preferences: EcosystemPreferences

    public init(preferences: EcosystemPreferences) { self.preferences = preferences }

    /// Build the full report.
    public func report(for installed: [InstalledPackage]) -> ConsolidationReport {
        // 1. Group by (ecosystem, name).
        var groups: [GroupKey: [InstalledPackage]] = [:]
        for p in installed {
            let key = GroupKey(ecosystem: p.manager.ecosystem, name: p.name)
            groups[key, default: []].append(p)
        }
        // 2. Duplicates = groups with >1 distinct manager.
        let dupKeys = groups.filter { _, pkgs in Set(pkgs.map { $0.manager }).count > 1 }
        let duplicates: [Duplicate] = dupKeys.map { key, pkgs in
            Duplicate(name: key.name, ecosystem: key.ecosystem,
                      installed: pkgs, recommendedManager: preferences.recommended(for: key.ecosystem))
        }.sorted { a, b in
            if a.ecosystem.rawValue != b.ecosystem.rawValue {
                return a.ecosystem.rawValue < b.ecosystem.rawValue
            }
            return a.name < b.name
        }
        // 3. Build migration steps.
        let steps = duplicates.map { dup -> MigrationStep in
            let recommendedHasIt = dup.installed.contains { $0.manager == dup.recommendedManager }
            let installCmd: String? = recommendedHasIt
                ? nil
                : "gimme install \(dup.name) --from \(dup.recommendedManager.rawValue)"
            let uninstallCmds = dup.toRemove.map { "gimme uninstall \(dup.name) --from \($0.manager.rawValue)" }
            return MigrationStep(duplicate: dup, installCommand: installCmd, uninstallCommands: uninstallCmds)
        }
        // 4. Clean ecosystems = those with no duplicates.
        let dupEcosystems = Set(duplicates.map { $0.ecosystem })
        let clean = Ecosystem.allCases.filter { !dupEcosystems.contains($0) }
        return ConsolidationReport(duplicates: duplicates, steps: steps, cleanEcosystems: clean)
    }
}
