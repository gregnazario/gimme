import Foundation

/// Result of an install.
public struct InstallResult: Equatable {
    public let tool: String
    public let version: String
    public let active: String
    public let shim: String
    public init(tool: String, version: String, active: String, shim: String) {
        self.tool = tool; self.version = version; self.active = version; self.shim = shim
    }

    public func toJSON() -> [String: Any] {
        return [
            "schema_version": Schema.version,
            "cmd": "install",
            "ok": true,
            "tool": tool,
            "version": version,
            "active": active,
            "shim": shim
        ]
    }
}

/// Orchestrates the full install pipeline:
///   resolve -> fetch -> stage -> commit -> receipt -> activate -> state.
public final class Installer {
    public let paths: GimmePaths
    public let host: Host
    public let tapStore: TapStore
    public let downloader: Downloader
    public let stager: Stager
    public let cellar: Cellar
    public let shims: ShimManager
    public let state: StateStore
    public let lock: Lock

    public init(paths: GimmePaths, host: Host, tapStore: TapStore,
                downloader: Downloader, stager: Stager, cellar: Cellar,
                shims: ShimManager, state: StateStore, lock: Lock) {
        self.paths = paths; self.host = host; self.tapStore = tapStore
        self.downloader = downloader; self.stager = stager; self.cellar = cellar
        self.shims = shims; self.state = state; self.lock = lock
    }

    // MARK: planning (no side effects)

    /// Resolve a query and render a dry-run plan. Does not acquire the lock.
    public func plan(query: String) throws -> InstallPlan {
        let resolver = Resolver(provider: tapStore, cellar: cellar, state: state, host: host)
        let resolution = try resolver.resolve(query: query)

        let depPlans = resolution.deps.map {
            InstallPlan.DepPlan(name: $0.formula.name, version: $0.version,
                                sha256: $0.asset.sha256, url: $0.asset.url)
        }
        let provides = resolution.formula.provides.bin
        let cellarPrefix = cellar.prefix(for: resolution.formula.name, version: resolution.version).path
        let shim = provides.first.map { shims.shimPath(for: $0).path } ?? ""

        return InstallPlan(
            tool: resolution.formula.name, version: resolution.version,
            sha256: resolution.asset.sha256, url: resolution.asset.url,
            arch: resolution.asset.arch, os: resolution.asset.os,
            deps: depPlans, cellarPrefix: cellarPrefix, shim: shim,
            provides: provides, conflicts: [])
    }

    // MARK: install

    /// Full install. Acquires the lock. On any pre-commit failure the cellar
    /// and state are left untouched.
    public func install(query: String, dryRun: Bool = false, insecure: Bool = false) throws -> InstallResult {
        let installPlan = try plan(query: query)
        if dryRun { return InstallResult(tool: installPlan.tool, version: installPlan.version,
                                          active: installPlan.version, shim: installPlan.shim) }

        try lock.acquire(timeoutSeconds: 30)
        defer { lock.release() }

        let resolver = Resolver(provider: tapStore, cellar: cellar, state: state, host: host)
        let resolution = try resolver.resolve(query: query)

        // 1. Fetch + verify (cached by sha256).
        let assetPath = try downloader.fetch(asset: resolution.asset, insecure: insecure)

        // 2. Resolve dependency prefixes (install deps first if missing).
        var depPaths: [String: URL] = [:]
        for dep in resolution.deps {
            try ensureInstalled(query: "\(dep.formula.name)@\(dep.version)", insecure: insecure)
            depPaths[dep.formula.name] = cellar.prefix(for: dep.formula.name, version: dep.version)
        }

        // 3. Stage (in staging/, will be cleaned on failure).
        let formulaDir = tapStore.enabledTapDirs().compactMap { dir -> URL? in
            let f = dir.appendingPathComponent("Formula").appendingPathComponent(resolution.formula.name)
            return FileManager.default.isDirectory(f) ? f
                : (FileManager.default.isDirectory(dir.appendingPathComponent(resolution.formula.name))
                    ? dir.appendingPathComponent(resolution.formula.name) : nil)
        }.first
        let versionBlock = resolution.formula.versions.first { $0.ver == resolution.version }
            ?? resolution.formula.versions[0]
        let staged = try stager.run(
            formula: resolution.formula, version: versionBlock,
            assetPath: assetPath, prefix: paths.cellar, formulaDir: formulaDir,
            depPaths: depPaths)

        // 4. Commit (atomic rename into cellar).
        // Move any pre-existing version aside BEFORE commit so we can restore it
        // if the post-commit steps fail. Fail hard here: silently swallowing the
        // move would let commit destroy the prior version with no backup.
        let targetPrefix = cellar.prefix(for: resolution.formula.name, version: resolution.version)
        let hadPrior = FileManager.default.fileExists(atPath: targetPrefix.path)
        var backup: URL? = nil
        if hadPrior {
            let backupDir = paths.staging.appendingPathComponent("rollback-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: targetPrefix, to: backupDir)
                backup = backupDir
            } catch {
                // If a same-volume rename won't work, fall back to copy+remove
                // so we still have a recoverable backup. Only after verifying
                // the backup exists do we proceed; otherwise abort to avoid
                // destroying the prior version.
                try FileManager.default.copyItem(at: targetPrefix, to: backupDir)
                try FileManager.default.removeItem(at: targetPrefix)
                backup = backupDir
            }
        }
        try cellar.commit(staged: staged, tool: resolution.formula.name, version: resolution.version)

        // 5-6. Write receipt, activate shims, update state. If ANY of these
        // throw, roll back the committed cellar entry so we never leave a
        // half-installed (unreceipted/unactivated) version behind.
        do {
            let receipt = Receipt(
                formula: resolution.formula.name, tap: "core", version: resolution.version,
                installedAt: isoNow(),
                asset: .init(resolution.asset),
                deps: resolution.deps.map { Receipt.DepRef(name: $0.formula.name, version: $0.version, resolved: $0.version) })
            try receipt.write(into: targetPrefix)
            try shims.activate(tool: resolution.formula.name, version: resolution.version,
                               bins: resolution.formula.provides.bin)
            try state.recordInstalled(resolution.formula.name, version: resolution.version)
            try state.setActive(resolution.formula.name, version: resolution.version)
        } catch {
            // Rollback: remove the just-committed (incomplete) version.
            try? cellar.remove(tool: resolution.formula.name, version: resolution.version)
            // Restore the prior version if there was one.
            if let backupDir = backup, FileManager.default.fileExists(atPath: backupDir.path) {
                try? FileManager.default.moveItem(at: backupDir, to: targetPrefix)
            }
            throw error
        }

        return InstallResult(
            tool: resolution.formula.name, version: resolution.version,
            active: resolution.version,
            shim: resolution.formula.provides.bin.first
                .map { shims.shimPath(for: $0).path } ?? "")
    }

    /// Recursively ensure a query is installed. Used for deps.
    private func ensureInstalled(query: String, insecure: Bool) throws {
        let (name, _) = try Resolver(provider: tapStore, cellar: cellar, state: state, host: host)
            .parseQuery(query)
        let installed = state.loadInstalled()[name]?.installed ?? []
        let pinned = state.loadPinned()[name]
        let target = pinned ?? query.split(separator: "@").dropFirst().first.map(String.init)
        if installed.isEmpty {
            _ = try install(query: target.map { "\(name)@\($0)" } ?? name, insecure: insecure)
        }
    }

    // MARK: uninstall

    public func uninstall(tool: String, version: String? = nil, force: Bool = false) throws {
        try lock.acquire(timeoutSeconds: 30)
        defer { lock.release() }

        let entries = state.loadInstalled()
        guard let entry = entries[tool] else {
            throw GimmeError.notFound("\(tool) is not installed")
        }
        let toRemove = version ?? entry.active ?? entry.installed.first
        guard let removing = toRemove else {
            throw GimmeError.notFound("\(tool) has no installed version")
        }

        // Dependents check: refuse uninstall if another tool depends on this
        // *version* of this tool (unless --force). Match the version being
        // removed against the version the dependent actually resolved to, so
        // removing an unused version (e.g. node@20 when only node@18 is a dep)
        // is allowed.
        if !force, let dependents = findDependents(of: tool, version: removing), !dependents.isEmpty {
            throw GimmeError.conflict(
                "\(tool)@\(removing) is depended on by: \(dependents.joined(separator: ", ")). Use --force to remove anyway.")
        }

        // Remember provides from the formula, or fall back to reading the bin/
        // dir of the version we're about to remove, so we can repoint/deactivate
        // shims even if the tap was disabled (prevents dangling shims).
        let removedPrefix = cellar.prefix(for: tool, version: removing)
        let providesBins: [String]
        if let formula = try? tapStore.find(tool) {
            providesBins = formula.provides.bin
        } else {
            let removedBinDir = removedPrefix.appendingPathComponent("bin")
            providesBins = (try? FileManager.default.contentsOfDirectory(atPath: removedBinDir.path)) ?? []
        }

        // Remove cellar prefix.
        try cellar.remove(tool: tool, version: removing)
        try state.removeInstalled(tool, version: removing)

        // Repoint shim to next-highest installed version, or deactivate.
        let remaining = cellar.installedVersions(for: tool)
        if let next = remaining.first {
            try shims.activate(tool: tool, version: next, bins: providesBins)
            try state.setActive(tool, version: next)
        } else {
            // No versions left -> remove shims so they don't dangle.
            try shims.deactivate(bins: providesBins)
        }
    }

    // MARK: switch active version (no download)

    public func switchActive(tool: String, version: String) throws {
        try lock.acquire(timeoutSeconds: 30)
        defer { lock.release() }

        let installed = cellar.installedVersions(for: tool)
        guard installed.contains(version) else {
            throw GimmeError.notFound("\(tool)@\(version) is not installed; available: \(installed.joined(separator: ", "))")
        }
        guard let formula = try? tapStore.find(tool) else {
            throw GimmeError.notFound("formula for \(tool) not found in any tap")
        }
        try shims.activate(tool: tool, version: version, bins: formula.provides.bin)
        try state.setActive(tool, version: version)
    }

    // MARK: helpers

    /// Find tools that depend on `tool` at `version` (via their receipts).
    /// Matches the resolved version recorded at install time so removing an
    /// unused version of a shared dependency is not blocked.
    private func findDependents(of tool: String, version: String) -> [String]? {
        return cellar.scanAll().compactMap { (t, _, receipt) -> String? in
            guard t != tool, let r = receipt else { return nil }
            return r.deps.contains { $0.name == tool && $0.resolved == version } ? t : nil
        }
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
