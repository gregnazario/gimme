import Foundation

/// The gimme command runner. The CLI is a thin wrapper; tests call in-process.
public final class Gimme {
    public let registry: Registry
    public var preferences: Preferences
    public var config: Config
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
        // Concurrent existence checks; keep priority order so .first wins.
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, m) in ordered.enumerated() {
                group.addTask {
                    let has = (try? await m.search(name))?.contains { $0.name == name } ?? false
                    return (i, has)
                }
            }
            var results = Array(repeating: false, count: ordered.count)
            for await (i, has) in group { results[i] = has }
            return zip(ordered, results).first(where: { $0.1 })?.0
        }
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
            // Use the cache-aware path so we don't re-query from scratch when
            // the GUI already fetched it seconds ago.
            let outdated = (try? await self.outdated(from: m.id, refresh: false))?
                .filter { $0.manager == m.id } ?? []
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

    /// Build the consolidation report over the live installed-list (spec §6).
    /// Uses the cache like `list`; pass refresh=true to bypass.
    public func consolidate(refresh: Bool) async throws -> ConsolidationReport {
        let installed = try await list(from: nil, refresh: refresh)
        let consolidator = Consolidator(preferences: config.ecosystems)
        return consolidator.report(for: installed)
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
    /// Per-manager availability + version, TTL-cached (each `--version` is a
    /// subprocess; ~7 spawns per call). Pass refresh=true to bypass.
    /// Config-derived fields (enabled, ordering) are applied at read time from
    /// the live config so Preferences changes show immediately — only the
    /// environment truth (availability/version) is cached.
    public func statuses(refresh: Bool = false) async -> [ManagerStatus] {
        let key = "meta:statuses:env"
        var env: [ManagerStatus]
        if !refresh, let cached = cache.get(key, ttlSeconds: config.listCacheTTLSeconds, as: [ManagerStatus].self) {
            env = cached
        } else {
            env = await computeStatuses()
            cache.set(key, value: env)
        }
        // Re-derive config-dependent state with the *current* config.
        return reapplyConfig(to: env)
    }

    /// Re-sort by current priority and re-compute `enabled` flags.
    private func reapplyConfig(to env: [ManagerStatus]) -> [ManagerStatus] {
        let known = config.priority.compactMap { ManagerID(rawValue: $0) }
        let order = known + registry.managers.map(\.id).filter { !known.contains($0) }
        let rank: [ManagerID: Int] = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return env.map { s in
            let enabled = !config.disabled.contains(s.id.rawValue)
            return s.enabled == enabled ? s
                : ManagerStatus(id: s.id, displayName: s.displayName, available: s.available, version: s.version, enabled: enabled)
        }.sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
    }

    private func computeStatuses() async -> [ManagerStatus] {
        let all = registry.managers
        let known = config.priority.compactMap { ManagerID(rawValue: $0) }
        let ordered = known + all.map(\.id).filter { !known.contains($0) }
        let unique = Array(NSOrderedSet(array: ordered)) as! [ManagerID]
        // Fetch version concurrently for installed managers.
        return await withTaskGroup(of: ManagerStatus.self) { group in
            for id in unique {
                guard let m = registry.get(id) else { continue }
                let available = m.isAvailable()
                let displayName = m.displayName
                if available {
                    group.addTask { ManagerStatus(id: id, displayName: displayName, available: true, version: await m.version(), enabled: true) }
                } else {
                    group.addTask { ManagerStatus(id: id, displayName: displayName, available: false, version: nil, enabled: true) }
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
    /// Queries managers concurrently. Uses cache unless `refresh`.
    public func list(from managerID: ManagerID?, refresh: Bool) async throws -> [InstalledPackage] {
        let managers = managerID.flatMap { id in registry.get(id).map { [$0] } } ?? registry.enabled(config: config)
        return await withTaskGroup(of: [InstalledPackage].self) { group in
            for m in managers {
                group.addTask {
                    let key = "\(m.id.rawValue):list"
                    if !refresh, let cached = self.cache.get(key, ttlSeconds: self.config.listCacheTTLSeconds, as: [InstalledPackage].self) {
                        return cached
                    }
                    if let pkgs = try? await m.listInstalled() {
                        self.cache.set(key, value: pkgs)
                        return pkgs
                    }
                    return []
                }
            }
            var all: [InstalledPackage] = []
            for await result in group { all.append(contentsOf: result) }
            return all
        }
    }

    /// All outdated packages across managers. Queries managers concurrently.
    public func outdated(from managerID: ManagerID?, refresh: Bool) async throws -> [OutdatedPackage] {
        let managers = managerID.flatMap { id in registry.get(id).map { [$0] } }
            ?? registry.enabled(config: config).filter { $0.capabilities.contains(.outdated) }
        return await withTaskGroup(of: [OutdatedPackage].self) { group in
            for m in managers {
                group.addTask {
                    let key = "\(m.id.rawValue):outdated"
                    if !refresh, let cached = self.cache.get(key, ttlSeconds: self.config.listCacheTTLSeconds, as: [OutdatedPackage].self) {
                        return cached
                    }
                    if let pkgs = try? await m.outdated() {
                        self.cache.set(key, value: pkgs)
                        return pkgs
                    }
                    return []
                }
            }
            var all: [OutdatedPackage] = []
            for await result in group { all.append(contentsOf: result) }
            return all
        }
    }

    /// Search the default-priority manager (all=false) or every manager (all=true).
    public func search(query: String, all: Bool, refresh: Bool) async throws -> [SearchHit] {
        let managers: [any PackageManager]
        if all {
            managers = registry.enabled(config: config).filter { $0.capabilities.contains(.search) }
        } else {
            managers = config.priority.compactMap { idStr -> (any PackageManager)? in
                guard let id = ManagerID(rawValue: idStr),
                      let m = registry.get(id), m.isAvailable(),
                      !config.disabled.contains(idStr),
                      m.capabilities.contains(.search) else { return nil }
                return m
            }.prefix(1).map { $0 }
        }
        return await withTaskGroup(of: [SearchHit].self) { group in
            for m in managers {
                group.addTask {
                    let key = "\(m.id.rawValue):search:\(query)"
                    if !refresh, let cached = self.cache.get(key, ttlSeconds: self.config.infoCacheTTLSeconds, as: [SearchHit].self) {
                        return cached
                    }
                    if let h = try? await m.search(query) {
                        self.cache.set(key, value: h)
                        return h
                    }
                    return []
                }
            }
            var hits: [SearchHit] = []
            for await result in group { hits.append(contentsOf: result) }
            return hits
        }
    }
}

extension Gimme {
    /// Wire the real adapters with production defaults.
    public static func defaultRegistry() -> Registry {
        Registry(managers: [
            // Homebrew gets the shared disk cache so its ~31 MB search indexes
            // are downloaded once per 6 h instead of per query.
            HomebrewManager(indexCache: Cache(directory: GimmePaths.defaultUser.cacheDir)),
            GoManager(), UvManager(), CargoManager(),
            BunManager(), NpmManager(), PnpmManager(),
            YarnManager(), GemManager(), ComposerManager(),
            DenoManager(), PipxManager(), AquaManager(), UbiManager(),
            // App Store lookups share the same disk cache pattern as brew's
            // search indexes: one lookup per app per 6 h.
            AppStoreManager(indexCache: Cache(directory: GimmePaths.defaultUser.cacheDir))
        ])
    }
}
