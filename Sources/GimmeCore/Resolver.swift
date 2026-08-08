import Foundation

/// Outcome of resolving a package name to a manager (spec §5.1).
public enum ResolveResult {
    case chosen(any PackageManager)
    case notFound(searched: [ManagerID])
    case hintNotFound(ManagerID, name: String)        // --from X but X lacks the package
    case hintUnavailable(ManagerID)                    // --from X but X not installed
}

/// Picks which manager handles a given package name (spec §5.1).
public final class Resolver {
    public let registry: Registry
    public let preferences: Preferences
    public let config: Config

    public init(registry: Registry, preferences: Preferences, config: Config) {
        self.registry = registry
        self.preferences = preferences
        self.config = config
    }

    public func resolve(_ name: String, hint: ManagerID?) async -> ResolveResult {
        // 1. Explicit --from wins.
        if let hint {
            guard let mgr = registry.get(hint) else { return .hintUnavailable(hint) }
            guard mgr.isAvailable() else { return .hintUnavailable(hint) }
            guard await hasPackage(mgr, name) else { return .hintNotFound(hint, name: name) }
            return .chosen(mgr)
        }
        // 2. Remembered preference (if that manager is still available).
        if let remembered = preferences.remembered(for: name),
           let mgr = registry.get(remembered), mgr.isAvailable() {
            return .chosen(mgr)
        }
        // 3. Priority list, concurrent existence check, pick highest-priority hit.
        let enabled = registry.enabled(config: config)
        let ordered = config.priority.compactMap { idStr -> (any PackageManager)? in
            guard let id = ManagerID(rawValue: idStr) else { return nil }
            return enabled.first { $0.id == id }
        }
        let withPackage = await concurrentExistence(ordered, name: name)
        if let best = withPackage.first {
            return .chosen(best)
        }
        return .notFound(searched: ordered.map { $0.id })
    }

    /// True if `manager.search(name)` returns an exact-name hit.
    private func hasPackage(_ manager: any PackageManager, _ name: String) async -> Bool {
        if let hits = try? await manager.search(name) {
            return hits.contains { $0.name == name }
        }
        return false
    }

    /// Check all managers concurrently; return those that have `name`, in the
    /// same order as `managers` (so .first is highest priority).
    private func concurrentExistence(_ managers: [any PackageManager], name: String) async -> [any PackageManager] {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, m) in managers.enumerated() {
                group.addTask { (i, await self.hasPackage(m, name)) }
            }
            var results = Array(repeating: false, count: managers.count)
            for await (i, has) in group { results[i] = has }
            return zip(managers, results).filter { $0.1 }.map { $0.0 }
        }
    }
}
