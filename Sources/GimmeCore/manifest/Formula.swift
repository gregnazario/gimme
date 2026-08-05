import Foundation

/// A gimme formula: typed manifest data + install strategy.
public struct Formula: Codable, Equatable {
    public struct Pkg: Codable, Equatable {
        public var name: String
        public var desc: String?
        public var homepage: String?
        public var license: String?
        public init(name: String, desc: String? = nil, homepage: String? = nil, license: String? = nil) {
            self.name = name; self.desc = desc; self.homepage = homepage; self.license = license
        }
    }

    /// A single declared version with its assets.
    public struct Version: Codable, Equatable {
        public var ver: String
        public var released: String?
        public var assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case ver, released, asset   // TOML key is [[version.asset]]
        }

        public init(ver: String, released: String? = nil, assets: [Asset] = []) {
            self.ver = ver; self.released = released; self.assets = assets
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.ver = try c.decode(String.self, forKey: .ver)
            self.released = try c.decodeIfPresent(String.self, forKey: .released)
            self.assets = try c.decodeIfPresent([Asset].self, forKey: .asset) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ver, forKey: .ver)
            try c.encodeIfPresent(released, forKey: .released)
            try c.encode(assets, forKey: .asset)
        }

        /// Parsed semver, if the version string is well-formed.
        public var parsed: GimmeCore.Version? {
            GimmeCore.Version(ver)
        }
    }

    public struct Dep: Codable, Equatable {
        public var name: String
        public var ver: String?
        public init(name: String, ver: String? = nil) { self.name = name; self.ver = ver }
    }

    public struct Provides: Codable, Equatable {
        public var bin: [String]
        public init(bin: [String] = []) { self.bin = bin }
    }

    public struct InstallSpec: Codable, Equatable {
        public var strategy: Strategy
        public var script: String?
        public var steps: [Step]

        enum CodingKeys: String, CodingKey {
            case strategy, script, step  // TOML key is [[install.step]]
        }

        public init(strategy: Strategy = .steps, script: String? = nil, steps: [Step] = []) {
            self.strategy = strategy; self.script = script; self.steps = steps
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.strategy = try c.decodeIfPresent(Strategy.self, forKey: .strategy) ?? .steps
            self.script = try c.decodeIfPresent(String.self, forKey: .script)
            self.steps = try c.decodeIfPresent([Step].self, forKey: .step) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(strategy, forKey: .strategy)
            try c.encodeIfPresent(script, forKey: .script)
            try c.encode(steps, forKey: .step)
        }
    }

    /// A single declarative install step. Exactly one action field is set.
    public struct Step: Codable, Equatable {
        public var extract: String?
        public var copy: CopySpec?

        public init(extract: String? = nil, copy: CopySpec? = nil) {
            self.extract = extract; self.copy = copy
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.extract = try c.decodeIfPresent(String.self, forKey: .extract)
            self.copy = try c.decodeIfPresent(CopySpec.self, forKey: .copy)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(extract, forKey: .extract)
            try c.encodeIfPresent(copy, forKey: .copy)
        }

        enum CodingKeys: String, CodingKey {
            case extract, copy
        }
    }

    public struct CopySpec: Codable, Equatable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    public struct LivecheckSpec: Codable, Equatable {
        public var strategy: String
        public var repo: String?
        public var url: String?
        public var regex: String?
        public init(strategy: String, repo: String? = nil, url: String? = nil, regex: String? = nil) {
            self.strategy = strategy; self.repo = repo; self.url = url; self.regex = regex
        }
    }

    public var package: Pkg
    public var versions: [Version]
    public var install: InstallSpec
    public var deps: [Dep]
    public var provides: Provides
    public var livecheck: LivecheckSpec?

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case package
        case version     // TOML key is [[version]] (array-of-tables)
        case install
        case dep         // TOML key is [[dep]]
        case provides
        case livecheck
    }

    public init(
        package: Pkg,
        versions: [Version] = [],
        install: InstallSpec = InstallSpec(),
        deps: [Dep] = [],
        provides: Provides = Provides(),
        livecheck: LivecheckSpec? = nil
    ) {
        self.package = package
        self.versions = versions
        self.install = install
        self.deps = deps
        self.provides = provides
        self.livecheck = livecheck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.package = try c.decode(Pkg.self, forKey: .package)
        self.versions = try c.decodeIfPresent([Version].self, forKey: .version) ?? []
        self.install = try c.decodeIfPresent(InstallSpec.self, forKey: .install) ?? InstallSpec()
        self.deps = try c.decodeIfPresent([Dep].self, forKey: .dep) ?? []
        // `provides` is [[provides]] (array-of-tables); merge all bin lists.
        if let all = try c.decodeIfPresent([Provides].self, forKey: .provides) {
            self.provides = Provides(bin: all.flatMap { $0.bin })
        } else {
            self.provides = Provides()
        }
        self.livecheck = try c.decodeIfPresent(LivecheckSpec.self, forKey: .livecheck)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(package, forKey: .package)
        try c.encode(versions, forKey: .version)
        try c.encode(install, forKey: .install)
        try c.encode(deps, forKey: .dep)
        try c.encode([provides], forKey: .provides)
        try c.encodeIfPresent(livecheck, forKey: .livecheck)
    }

    /// Convenience: the formula's name.
    public var name: String { package.name }

    /// All versions, sorted highest-first.
    public var sortedVersions: [Version] {
        versions.sorted { ($0.parsed ?? GimmeCore.Version("0")!) > ($1.parsed ?? GimmeCore.Version("0")!) }
    }

    /// Highest declared version (semver-aware), or nil if none.
    public func highestVersion() -> Version? {
        sortedVersions.first
    }

    /// First version satisfying a constraint, highest-first.
    public func highestVersion(matching constraint: VersionConstraint, host: Host) -> (Version, Asset)? {
        for v in sortedVersions {
            guard let pv = v.parsed else { continue }
            guard constraint.matches(pv) else { continue }
            if let asset = v.assets.first(where: { $0.matches(host) }) {
                return (v, asset)
            }
        }
        return nil
    }
}
