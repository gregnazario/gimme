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
            // The available managers didn't have it. As a last resort, check
            // unavailable (uninstalled) managers — if one has the package, we
            // can still return it and let the caller trigger bootstrap.
            if let m = await findAmongUnavailable(name, excluding: Set(searched)) {
                return m
            }
            throw GimmeError.notFoundInManagers(name: name, searched: searched)
        case .hintNotFound(let id, let n):
            throw GimmeError.notFound("\(id.rawValue) has no package '\(n)'")
        case .hintUnavailable(let id):
            // --from X where X is installed-but-unavailable: return it so
            // bootstrap can run (caller knows it may be unavailable).
            if let m = registry.get(id) { return m }
            throw GimmeError.managerUnavailable(id)
        }
    }

    /// Among managers in the registry that are NOT available, find the
    /// highest-priority one (per config) whose search includes `name`. Used so
    /// `install` can bootstrap a missing backend that has the package.
    private func findAmongUnavailable(_ name: String, excluding: Set<ManagerID>) async -> (any PackageManager)? {
        let candidates = registry.managers
            .filter { !$0.isAvailable() && !excluding.contains($0.id) && !config.disabled.contains($0.id.rawValue) }
        let ordered = config.priority.compactMap { idStr -> (any PackageManager)? in
            guard let id = ManagerID(rawValue: idStr) else { return nil }
            return candidates.first { $0.id == id }
        }
        for m in ordered {
            if let hits = try? await m.search(name), hits.contains(where: { $0.name == name }) {
                return m
            }
        }
        return nil
    }

    @discardableResult
    public func install(name: String, from hint: ManagerID?, options: InstallOptions,
                        confirmBootstrap: (ManagerID) -> Bool = { _ in false },
                        onProgress: ((String) -> Void)? = nil) async throws -> InstallResult {
        let manager = try await resolve(name, hint: hint)
        if !manager.isAvailable() {
            try await Bootstrap.run(manager, confirm: confirmBootstrap)
        }
        let result = try await manager.installStreaming(PackageRef(name: name, managerHint: hint),
                                                        options: options, onProgress: onProgress)
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

    /// Look up a registered manager by ID. Used by the GUI for direct actions
    /// like bootstrapping a missing backend.
    public func registryLookup(_ id: ManagerID) -> (any PackageManager)? {
        registry.get(id)
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
    /// `onPackageStart` is invoked (on the calling task) before each upgrade
    /// so callers (e.g. the GUI) can show per-package progress.
    public func updateAll(
        onPackageStart: ((String) -> Void)? = nil
    ) async throws -> UpdateSummary {
        var summary = UpdateSummary()
        let managers = registry.enabled(config: config).filter { $0.capabilities.contains(.outdated) && $0.capabilities.contains(.upgrade) }
        for m in managers {
            let outdated = (try? await m.outdated()) ?? []
            for pkg in outdated {
                onPackageStart?(pkg.id)
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

    /// Status of one backend manager: availability + version (if installed).
    public struct ManagerStatus: Identifiable, Equatable, Codable {
        public let id: ManagerID
        public let displayName: String
        public let available: Bool
        public let version: String?       // nil if not installed
        public let enabled: Bool          // false if disabled in config

        public init(id: ManagerID, displayName: String, available: Bool, version: String?, enabled: Bool) {
            self.id = id; self.displayName = displayName
            self.available = available; self.version = version; self.enabled = enabled
        }
    }

    /// Per-manager availability + version, gathered concurrently. Ordered by the
    /// config priority list first, then any unknown managers. Used by the GUI's
    /// By Manager view and `gimme doctor -v`.
    public func statuses() async -> [ManagerStatus] {
        let all = registry.managers
        let known = config.priority.compactMap { ManagerID(rawValue: $0) }
        let ordered = known + all.map(\.id).filter { !known.contains($0) }
        let unique = Array(NSOrderedSet(array: ordered)) as! [ManagerID]
        // Fetch version concurrently for installed managers.
        return await withTaskGroup(of: ManagerStatus.self) { group in
            for id in unique {
                guard let m = registry.get(id) else { continue }
                let available = m.isAvailable()
                let enabled = !config.disabled.contains(id.rawValue)
                let displayName = m.displayName
                if available {
                    group.addTask { ManagerStatus(id: id, displayName: displayName, available: true, version: await m.version(), enabled: enabled) }
                } else {
                    group.addTask { ManagerStatus(id: id, displayName: displayName, available: false, version: nil, enabled: enabled) }
                }
            }
            var out: [ManagerStatus] = []
            for await s in group { out.append(s) }
            // Restore priority order (TaskGroup returns unordered).
            return out.sorted { a, b in
                (unique.firstIndex(of: a.id) ?? Int.max) < (unique.firstIndex(of: b.id) ?? Int.max)
            }
        }
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
            // Cache only on success; a thrown result is never cached as empty.
            if let pkgs = try? await m.listInstalled() {
                cache.set(key, value: pkgs)
                all.append(contentsOf: pkgs)
            }
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
            if let pkgs = try? await m.outdated() {
                cache.set(key, value: pkgs)
                all.append(contentsOf: pkgs)
            }
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
            if let h = try? await m.search(query) {
                cache.set(key, value: h)
                hits.append(contentsOf: h)
            }
        }
        return hits
    }
}

extension Gimme {
    /// Wire the real adapters with production defaults.
    public static func defaultRegistry() -> Registry {
        Registry(managers: [
            HomebrewManager(), GoManager(), UvManager(), CargoManager(),
            BunManager(), NpmManager(), PnpmManager(),
            YarnManager(), GemManager(), ComposerManager()
        ])
    }
}
