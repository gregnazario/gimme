import Foundation

/// A source of formulae by name. TapStore conforms; tests inject mocks.
public protocol FormulaProvider {
    func find(_ name: String) throws -> Formula
}

/// The result of resolving a single formula query against provider + cellar.
public struct Resolution: Equatable {
    public struct ResolvedDep: Equatable {
        public let formula: Formula
        public let version: String
        public let asset: Asset
        public init(formula: Formula, version: String, asset: Asset) {
            self.formula = formula; self.version = version; self.asset = asset
        }
    }
    public let formula: Formula
    public let version: String
    public let asset: Asset
    public let deps: [ResolvedDep]
    public init(formula: Formula, version: String, asset: Asset, deps: [ResolvedDep] = []) {
        self.formula = formula; self.version = version; self.asset = asset; self.deps = deps
    }
}

/// Resolves a name@version query to concrete (formula, version, asset) + deps.
/// Strategy: reuse-installed-first, pick-highest matching, host-asset filtering.
public struct Resolver {
    public let provider: FormulaProvider
    public let cellar: Cellar
    public let state: StateStore
    public let host: Host

    public init(provider: FormulaProvider, cellar: Cellar, state: StateStore, host: Host) {
        self.provider = provider; self.cellar = cellar; self.state = state; self.host = host
    }

    /// Parse a query into (name, optional constraint). Honors pins.
    public func parseQuery(_ query: String) throws -> (String, VersionConstraint) {
        guard let at = query.firstIndex(of: "@") else {
            // No version -> check pin first.
            let pinned = state.loadPinned()[query]
            if let pv = pinned.flatMap({ Version($0) }) {
                return (query, .exact(pv))
            }
            return (query, .any)
        }
        let name = String(query[..<at])
        let constraintStr = String(query[query.index(after: at)...])
        let constraint = try VersionConstraint.parse(constraintStr)
        return (name, constraint)
    }

    public func resolve(query: String) throws -> Resolution {
        let (name, constraint) = try parseQuery(query)
        let formula = try provider.find(name)
        return try resolveTop(formula: formula, constraint: constraint, visiting: [])
    }

    /// Resolve a formula version matching `constraint` for the host, plus deps.
    /// `visiting` tracks the resolution chain for conflict reporting.
    private func resolveTop(formula: Formula, constraint: VersionConstraint, visiting: [String]) throws -> Resolution {
        // Honor constraint: if `.any`, prefer the installed active version if it satisfies host.
        if constraint == .any, let active = state.loadInstalled()[formula.name]?.active,
           Version(active) != nil {
            // Active version must have a host asset; otherwise re-resolve latest.
            if let versionBlock = formula.versions.first(where: { $0.ver == active }),
               let asset = versionBlock.assets.first(where: { $0.matches(host) }) {
                let deps = try resolveDeps(of: formula, version: active, visiting: visiting + [formula.name])
                return Resolution(formula: formula, version: active, asset: asset, deps: deps)
            }
        }

        guard let (versionBlock, asset) = formula.highestVersion(matching: constraint, host: host) else {
            throw GimmeError.notFound(
                "no version of \(formula.name) satisfies \(constraint) for \(host.os)-\(host.arch)")
        }
        let deps = try resolveDeps(of: formula, version: versionBlock.ver, visiting: visiting + [formula.name])
        return Resolution(formula: formula, version: versionBlock.ver, asset: asset, deps: deps)
    }

    /// Resolve a formula's declared deps (transitively). Reuse-installed-first;
    /// pick-highest otherwise. `visiting` enables circular-dependency detection.
    private func resolveDeps(of formula: Formula, version: String, visiting: [String]) throws -> [Resolution.ResolvedDep] {
        var resolved: [Resolution.ResolvedDep] = []
        for dep in formula.deps {
            if visiting.contains(dep.name) {
                throw GimmeError.conflict("circular dependency on \(dep.name) while resolving \(formula.name)")
            }
            let constraint = try dep.ver.map { try VersionConstraint.parse($0) } ?? .any

            // Try to find the dep formula. If not found, skip it (soft-fail) —
            // many Homebrew formulae declare build-only deps (autoconf, pkg-config,
            // rust, etc.) that gimme doesn't need for download-based installs.
            let depFormula: Formula
            do {
                depFormula = try provider.find(dep.name)
            } catch {
                // Dep not in any tap — skip rather than abort.
                continue
            }

            // Reuse installed if ANY installed version satisfies the constraint.
            if let installed = state.loadInstalled()[dep.name] {
                let satisfyingInstalled = installed.installed
                    .compactMap { Version($0) }
                    .filter { constraint.matches($0) }
                    .sorted(by: >)
                if let reuseVersion = satisfyingInstalled.first,
                   let versionBlock = depFormula.versions.first(where: { $0.ver == reuseVersion.description }),
                   let asset = versionBlock.assets.first(where: { $0.matches(host) }) {
                    resolved.append(.init(formula: depFormula, version: reuseVersion.description, asset: asset))
                    continue
                }
            }

            // Try to find a version with a host asset. If none, skip (soft-fail) —
            // the dep may be a source-only formula gimme can't download.
            guard let (versionBlock, asset) = depFormula.highestVersion(matching: constraint, host: host) else {
                continue
            }
            // Recursively resolve this dep's own deps.
            _ = try resolveDeps(of: depFormula, version: versionBlock.ver,
                                visiting: visiting + [depFormula.name])
            resolved.append(.init(formula: depFormula, version: versionBlock.ver, asset: asset))
        }
        return resolved
    }
}
