import Foundation

/// The gimme command runner. The CLI is a thin wrapper; tests call in-process.
public final class Gimme {
    public let registry: Registry
    public var preferences: Preferences
    public let config: Config
    public let cache: Cache
    private let preferencesFile: URL

    public init(registry: Registry, preferences: Preferences, config: Config, cache: Cache, preferencesFile: URL) {
        self.registry = registry
        self.preferences = preferences
        self.config = config
        self.cache = cache
        self.preferencesFile = preferencesFile
    }

    public enum Command: String {
        case install, uninstall, upgrade, update
        case list, search, info, outdated
        case forget, config, doctor
    }

    // MARK: - Resolve + act helpers

    private func resolve(_ name: String, hint: ManagerID?) async throws -> (any PackageManager) {
        let resolver = Resolver(registry: registry, preferences: preferences, config: config)
        switch await resolver.resolve(name, hint: hint) {
        case .chosen(let m): return m
        case .notFound(let searched):
            throw GimmeError.notFoundInManagers(name: name, searched: searched)
        case .hintNotFound(let id, let n):
            throw GimmeError.notFound("\(id.rawValue) has no package '\(n)'")
        case .hintUnavailable(let id):
            throw GimmeError.managerUnavailable(id)
        }
    }

    @discardableResult
    public func install(name: String, from hint: ManagerID?, options: InstallOptions) async throws -> InstallResult {
        let manager = try await resolve(name, hint: hint)
        let result = try await manager.install(PackageRef(name: name, managerHint: hint), options: options)
        cache.invalidatePrefix("\(manager.id.rawValue):")
        // Remember only on explicit --from.
        if hint != nil {
            preferences.remember(name, manager.id)
            try? preferences.save(at: preferencesFile)
        }
        return result
    }

    public func uninstall(name: String, from hint: ManagerID?) async throws {
        let manager = try await resolve(name, hint: hint)
        try await manager.uninstall(PackageRef(name: name, managerHint: hint))
        cache.invalidatePrefix("\(manager.id.rawValue):")
    }

    public func upgrade(name: String, from hint: ManagerID?) async throws {
        let manager = try await resolve(name, hint: hint)
        try await manager.upgrade(PackageRef(name: name, managerHint: hint))
        cache.invalidatePrefix("\(manager.id.rawValue):")
    }

    public func info(name: String, from hint: ManagerID?) async throws -> PackageInfo {
        let manager = try await resolve(name, hint: hint)
        return try await manager.info(PackageRef(name: name, managerHint: hint))
    }

    // list/outdated/search/update/doctor/forget/config added in 7.2–7.4
}

extension Gimme {
    /// Summary of an update-all run.
    public struct UpdateSummary {
        public var succeeded: [String] = []   // package IDs
        public var failed: [(id: String, error: String)] = []
    }

    /// Upgrade every outdated package across all managers. Partial failures
    /// are captured per-package; other managers still complete (spec §9).
    public func updateAll() async throws -> UpdateSummary {
        var summary = UpdateSummary()
        let managers = registry.enabled(config: config).filter { $0.capabilities.contains(.outdated) && $0.capabilities.contains(.upgrade) }
        for m in managers {
            let outdated = (try? await m.outdated()) ?? []
            for pkg in outdated {
                do {
                    try await m.upgrade(PackageRef(name: pkg.name))
                    summary.succeeded.append(pkg.id)
                } catch {
                    summary.failed.append((pkg.id, "\(error)"))
                }
            }
            cache.invalidatePrefix("\(m.id.rawValue):")
        }
        return summary
    }

    public func forget(name: String) throws {
        preferences.forget(name)
        try preferences.save(at: preferencesFile)
    }

    public func forgetAll() throws {
        preferences.forgetAll()
        try preferences.save(at: preferencesFile)
    }

    public struct DoctorReport {
        public let available: [ManagerID]
        public let missing: [ManagerID]
    }

    public func doctor() -> DoctorReport {
        var avail: [ManagerID] = []; var miss: [ManagerID] = []
        for m in registry.managers {
            if m.isAvailable() { avail.append(m.id) } else { miss.append(m.id) }
        }
        return DoctorReport(available: avail, missing: miss)
    }
}

extension Gimme {
    /// All installed packages across managers (or one if `from` is set).
    /// Uses cache unless `refresh`.
    public func list(from managerID: ManagerID?, refresh: Bool) async throws -> [InstalledPackage] {
        let managers = managerID.flatMap { id in registry.get(id).map { [$0] } } ?? registry.enabled(config: config)
        var all: [InstalledPackage] = []
        for m in managers {
            let key = "\(m.id.rawValue):list"
            if !refresh, let cached = cache.get(key, ttlSeconds: config.listCacheTTLSeconds, as: [InstalledPackage].self) {
                all.append(contentsOf: cached); continue
            }
            let pkgs = (try? await m.listInstalled()) ?? []
            cache.set(key, value: pkgs)
            all.append(contentsOf: pkgs)
        }
        return all
    }

    /// All outdated packages across managers.
    public func outdated(from managerID: ManagerID?, refresh: Bool) async throws -> [OutdatedPackage] {
        let managers = managerID.flatMap { id in registry.get(id).map { [$0] } }
            ?? registry.enabled(config: config).filter { $0.capabilities.contains(.outdated) }
        var all: [OutdatedPackage] = []
        for m in managers {
            let key = "\(m.id.rawValue):outdated"
            if !refresh, let cached = cache.get(key, ttlSeconds: config.listCacheTTLSeconds, as: [OutdatedPackage].self) {
                all.append(contentsOf: cached); continue
            }
            let pkgs = (try? await m.outdated()) ?? []
            cache.set(key, value: pkgs)
            all.append(contentsOf: pkgs)
        }
        return all
    }

    /// Search the default-priority manager (all=false) or every manager (all=true).
    public func search(query: String, all: Bool, refresh: Bool) async throws -> [SearchHit] {
        let managers: [any PackageManager]
        if all {
            managers = registry.enabled(config: config).filter { $0.capabilities.contains(.search) }
        } else {
            // Default = first enabled manager in priority order with search.
            managers = config.priority.compactMap { idStr -> (any PackageManager)? in
                guard let id = ManagerID(rawValue: idStr),
                      let m = registry.get(id), m.isAvailable(),
                      !config.disabled.contains(idStr),
                      m.capabilities.contains(.search) else { return nil }
                return m
            }.prefix(1).map { $0 }
        }
        var hits: [SearchHit] = []
        for m in managers {
            let key = "\(m.id.rawValue):search:\(query)"
            if !refresh, let cached = cache.get(key, ttlSeconds: config.infoCacheTTLSeconds, as: [SearchHit].self) {
                hits.append(contentsOf: cached); continue
            }
            let h = (try? await m.search(query)) ?? []
            cache.set(key, value: h)
            hits.append(contentsOf: h)
        }
        return hits
    }
}

extension Gimme {
    /// Wire the five real adapters with production defaults.
    public static func defaultRegistry() -> Registry {
        Registry(managers: [HomebrewManager(), GoManager(), UvManager(), CargoManager(), BunManager()])
    }
}
