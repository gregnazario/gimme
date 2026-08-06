import Foundation

/// A wired-up set of all gimme services for one prefix. The CLI builds one of
/// these from global options, then runs a command against it.
public final class World {
    public let paths: GimmePaths
    public let host: Host
    public var config: Config
    public let tapStore: TapStore
    public let downloader: Downloader
    public let stager: Stager
    public let cellar: Cellar
    public let shims: ShimManager
    public let state: StateStore
    public let lock: Lock
    public let installer: Installer
    public let livecheck: Livecheck

    public init(prefix: URL) throws {
        self.paths = GimmePaths(prefix: prefix)
        try paths.ensureDirectories()
        self.host = Host.current
        self.config = Config.loadOrCreate(at: paths.configFile)
        self.tapStore = TapStore(paths: paths, config: config)
        self.downloader = Downloader(paths: paths)
        self.stager = Stager(paths: paths, host: host)
        self.cellar = Cellar(paths: paths)
        self.shims = ShimManager(paths: paths)
        let state = StateStore(paths: paths)
        state.cellar = cellar   // enables self-healing of corrupt installed.json
        self.state = state
        self.lock = Lock(paths: paths)
        self.installer = Installer(paths: paths, host: host, tapStore: tapStore,
                                   downloader: downloader, stager: stager, cellar: cellar,
                                   shims: shims, state: state, lock: lock)
        self.livecheck = Livecheck(paths: paths, maxAgeHours: config.cache.maxAgeHours)
    }
}

/// The complete gimme command runner. The CLI is a thin wrapper over this;
/// tests call it in-process with a temp prefix for speed + determinism.
public final class Gimme {
    public let world: World

    public init(world: World) { self.world = world }

    public enum Command: String {
        case install, uninstall, update, use, pin, unpin
        case list, search, info, outdated
        case tap, doctor, config, introspect, man
        case brewImport = "brew-import"
        case shortcut   // `gimme <tool>`
    }

    public struct Options {
        public var json: Bool
        public var dryRun: Bool
        public var insecure: Bool
        public var force: Bool
        public var yes: Bool
        public var all: Bool
        public var check: Bool
        public var limit: Int?
        public var fields: String?
        public var query: String?
        public var positional: [String]
        public var fromMise: Bool
        public var noMise: Bool
        public var cwd: URL
        public init(json: Bool = false, dryRun: Bool = false, insecure: Bool = false,
                    force: Bool = false, yes: Bool = false, all: Bool = false,
                    check: Bool = false, limit: Int? = nil, fields: String? = nil,
                    query: String? = nil, positional: [String] = [],
                    fromMise: Bool = false, noMise: Bool = false,
                    cwd: URL = FileManager.default.currentDirectoryPath.isEmpty
                        ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        : URL(fileURLWithPath: "/")) {
            self.json = json; self.dryRun = dryRun; self.insecure = insecure
            self.force = force; self.yes = yes; self.all = all; self.check = check
            self.limit = limit; self.fields = fields; self.query = query
            self.positional = positional; self.fromMise = fromMise; self.noMise = noMise
            self.cwd = cwd
        }
    }

    /// Run a command. Returns (jsonObject, exitCode). Throws nothing: all
    /// GimmeErrors are caught and rendered here so the caller just emits output.
    public func run(command: Command, options: Options) -> (result: [String: Any], exitCode: Int32) {
        do {
            let (result, code) = try dispatch(command: command, options: options)
            return (result, code)
        } catch let e as GimmeError {
            return (e.toJSON(), e.category.exitCode)
        } catch {
            let ge = GimmeError.unknown("unexpected: \(error)")
            return (ge.toJSON(), ge.category.exitCode)
        }
    }

    private func dispatch(command: Command, options: Options) throws -> ([String: Any], Int32) {
        switch command {
        case .install:    return try runInstall(options)
        case .uninstall:  return try (runUninstall(options), 0)
        case .update:     return try (runUpdate(options), 0)
        case .use:        return try (runUse(options), 0)
        case .pin:        return try (runPin(options), 0)
        case .unpin:      return try (runUnpin(options), 0)
        case .list:       return try (runList(options), 0)
        case .search:     return try (runSearch(options), 0)
        case .info:       return try (runInfo(options), 0)
        case .outdated:   return try (runOutdated(options), 0)
        case .tap:        return try (runTap(options), 0)
        case .doctor:     return try (runDoctor(options), 0)
        case .config:     return try (runConfig(options), 0)
        case .introspect: return try (runIntrospect(options), 0)
        case .man:        return try (runMan(options), 0)
        case .brewImport: return try runBrewImport(options)
        case .shortcut:   return try (runShortcut(options), 0)
        }
    }

    // MARK: commands

    private func runInstall(_ o: Options) throws -> ([String: Any], Int32) {
        // Mise-reading mode trigger (per spec §5):
        //   no positional arg AND not --no-mise AND config discoverable at cwd,
        //   OR --from-mise forces it.
        let hasPositional = o.positional.contains { !$0.isEmpty }
        let enteringMiseMode: Bool
        if o.fromMise {
            enteringMiseMode = true
        } else if o.noMise {
            enteringMiseMode = false
        } else if hasPositional {
            enteringMiseMode = false
        } else {
            // Auto-detect: peek for config without committing.
            let (reqs, _) = MiseConfig.discover(startingAt: o.cwd)
            enteringMiseMode = !reqs.isEmpty
        }

        if enteringMiseMode {
            let integration = MiseIntegration(world: world, cwd: o.cwd)
            let result = integration.run(dryRun: o.dryRun)
            if result.outcomes.isEmpty && !o.fromMise {
                // No config found and not forced -> fall through to usage error.
                throw GimmeError.usage("install requires a tool name (no mise config detected)")
            }
            // Exit code per spec: 0 if nothing failed, 1 if any tool failed OR
            // nothing installed (ok=false).
            let code: Int32 = (result.anyFailed || !result.ok) ? 1 : 0
            return (result.toJSON(), code)
        }

        guard let tool = o.positional.first else { throw GimmeError.usage("install requires a tool name") }
        if o.dryRun {
            let plan = try world.installer.plan(query: tool)
            return (plan.toJSON(), 0)
        }
        let result = try world.installer.install(query: tool, dryRun: false, insecure: o.insecure)
        return (result.toJSON(), 0)
    }

    private func runUninstall(_ o: Options) throws -> [String: Any] {
        guard let tool = o.positional.first else { throw GimmeError.usage("uninstall requires a tool name") }
        let (name, ver) = splitAt(tool)
        try world.installer.uninstall(tool: name, version: ver, force: o.force)
        return ["cmd": "uninstall", "ok": true, "schema_version": Schema.version, "tool": name, "version": ver as Any]
    }

    private func runUpdate(_ o: Options) throws -> [String: Any] {
        let toolsToUpdate: [String]
        if o.all {
            toolsToUpdate = world.cellar.installedTools()
        } else if let tool = o.positional.first {
            toolsToUpdate = [tool]
        } else {
            throw GimmeError.usage("update requires a tool or --all")
        }
        if o.check {
            return try runOutdated(Options())
        }
        var updated: [[String: Any]] = []
        let pins = world.state.loadPinned()
        for tool in toolsToUpdate {
            if pins[tool] != nil { continue }
            let result = try world.installer.install(query: tool, dryRun: false, insecure: false)
            updated.append(["tool": result.tool, "version": result.version])
        }
        return ["cmd": "update", "ok": true, "schema_version": Schema.version, "updated": updated]
    }

    private func runUse(_ o: Options) throws -> [String: Any] {
        guard o.positional.count >= 2 else {
            throw GimmeError.usage("use requires <tool> <version>")
        }
        let tool = o.positional[0]; let version = o.positional[1]
        try world.installer.switchActive(tool: tool, version: version)
        return ["cmd": "use", "ok": true, "schema_version": Schema.version, "tool": tool, "active": version]
    }

    private func runPin(_ o: Options) throws -> [String: Any] {
        guard let tool = o.positional.first else { throw GimmeError.usage("pin requires a tool") }
        let (name, ver) = splitAt(tool)
        // Hold the lock: pin() does a read-modify-write of pinned.json and is
        // not safe against concurrent gimme commands without it.
        try world.lock.acquire(timeoutSeconds: 30)
        defer { world.lock.release() }
        let version = ver ?? world.state.loadInstalled()[name]?.active
            ?? (world.cellar.installedVersions(for: name).first)
        guard let v = version else { throw GimmeError.notFound("\(name) is not installed") }
        try world.state.pin(name, version: v)
        return ["cmd": "pin", "ok": true, "schema_version": Schema.version, "tool": name, "pinned": v]
    }

    private func runUnpin(_ o: Options) throws -> [String: Any] {
        guard let tool = o.positional.first else { throw GimmeError.usage("unpin requires a tool") }
        try world.lock.acquire(timeoutSeconds: 30)
        defer { world.lock.release() }
        try world.state.unpin(tool)
        return ["cmd": "unpin", "ok": true, "schema_version": Schema.version, "tool": tool]
    }

    private func runList(_ o: Options) throws -> [String: Any] {
        var tools: [[String: Any]] = []
        if o.all {
            for f in world.tapStore.allFormulae() {
                let active = world.state.loadInstalled()[f.name]?.active
                tools.append(["name": f.name, "version": active ?? "not installed"])
            }
        } else {
            for (tool, entry) in world.state.loadInstalled().sorted(by: { $0.key < $1.key }) {
                tools.append(["name": tool, "version": entry.active ?? "—",
                              "installed": entry.installed])
            }
        }
        if let q = o.query {
            tools = tools.filter { "\($0)".lowercased().contains(q.lowercased()) }
        }
        if let limit = o.limit, tools.count > limit {
            tools = Array(tools.prefix(limit))
        }
        return ["cmd": "list", "ok": true, "schema_version": Schema.version, "tools": tools]
    }

    private func runSearch(_ o: Options) throws -> [String: Any] {
        guard let term = o.positional.first else { throw GimmeError.usage("search requires a term") }
        let results = world.tapStore.allFormulae()
            .filter { $0.name.lowercased().contains(term.lowercased()) }
            .map { f -> [String: Any] in
                ["name": f.name, "desc": f.package.desc ?? "", "versions": f.versions.map { $0.ver }]
            }
        return ["cmd": "search", "ok": true, "schema_version": Schema.version, "results": results]
    }

    private func runInfo(_ o: Options) throws -> [String: Any] {
        guard let tool = o.positional.first else { throw GimmeError.usage("info requires a tool") }
        let f = try world.tapStore.find(tool)
        return [
            "cmd": "info", "ok": true, "schema_version": Schema.version,
            "formula": [
                "name": f.name,
                "desc": f.package.desc as Any,
                "homepage": f.package.homepage as Any,
                "license": f.package.license as Any,
            ],
            "versions": f.versions.map { $0.ver },
            "deps": f.deps.map { ["name": $0.name, "ver": $0.ver as Any] }
        ]
    }

    private func runOutdated(_ o: Options) throws -> [String: Any] {
        var outdated: [[String: Any]] = []
        let pins = world.state.loadPinned()
        for (tool, entry) in world.state.loadInstalled() {
            if pins[tool] != nil { continue }
            guard let active = entry.active, let f = try? world.tapStore.find(tool) else { continue }
            if let latest = try world.livecheck.latest(for: f), latest > (Version(active) ?? Version("0")!) {
                outdated.append(["tool": tool, "current": active, "latest": latest.description])
            }
        }
        return ["cmd": "outdated", "ok": true, "schema_version": Schema.version, "outdated": outdated]
    }

    private func runTap(_ o: Options) throws -> [String: Any] {
        let action = o.positional.first ?? "list"
        switch action {
        case "list":
            return ["cmd": "tap", "ok": true, "schema_version": Schema.version,
                    "taps": world.tapStore.list()]
        case "add":
            guard o.positional.count >= 3 else { throw GimmeError.usage("tap add requires <name> <url>") }
            try world.tapStore.add(name: o.positional[1], url: o.positional[2])
            return ["cmd": "tap", "ok": true, "schema_version": Schema.version, "added": o.positional[1]]
        case "remove":
            guard o.positional.count >= 2 else { throw GimmeError.usage("tap remove requires <name>") }
            try world.tapStore.remove(name: o.positional[1])
            return ["cmd": "tap", "ok": true, "schema_version": Schema.version, "removed": o.positional[1]]
        default:
            throw GimmeError.usage("tap: unknown action '\(action)'; use add|remove|list")
        }
    }

    private func runDoctor(_ o: Options) throws -> [String: Any] {
        var checks: [[String: Any]] = []

        // 1. PATH check: is gimme's bin dir on PATH?
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let gimmeBin = world.paths.bin
        let onPath = path.split(separator: ":").contains { dir in
            URL(fileURLWithPath: String(dir)).resolvingSymlinksInPath().path
                == gimmeBin.resolvingSymlinksInPath().path
        }
        checks.append(["name": "path", "ok": onPath,
                       "message": onPath ? "\(gimmeBin.path) is on PATH"
                                          : "\(gimmeBin.path) is NOT on PATH — add it: export PATH=\"\(gimmeBin.path):$PATH\""])

        // 2. Prefix writable?
        let writable = FileManager.default.isWritableFile(atPath: world.paths.prefix.path)
        checks.append(["name": "writable", "ok": writable,
                       "message": writable ? "prefix writable (\(world.paths.prefix.path))"
                                            : "prefix NOT writable (\(world.paths.prefix.path))"])

        // 3. Receipts sanity.
        let scan = world.cellar.scanAll()
        let missingReceipts = scan.filter { $0.receipt == nil }.map { "\($0.tool)@\($0.version)" }
        checks.append(["name": "receipts", "ok": missingReceipts.isEmpty,
                       "message": missingReceipts.isEmpty ? "all receipts present (\(scan.count) installed)"
                                                          : "missing receipts: \(missingReceipts.joined(separator: ", "))"])

        // 4. Mise/asdf coexistence.
        let det = MiseDetector(paths: world.paths)
        let installedTools = world.cellar.installedTools()
        let managedByMise = installedTools.filter { det.isManaged(byManager: $0) }
        let miseShimsExists = FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/mise/shims").path)
        let asdfShimsExists = FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".asdf/shims").path)
        if miseShimsExists || asdfShimsExists {
            let mgrName = miseShimsExists ? "mise" : "asdf"
            let detail = managedByMise.isEmpty
                ? "no conflicts"
                : "manages: \(managedByMise.joined(separator: ", ")) (gimme defers)"
            checks.append(["name": "mise", "ok": managedByMise.isEmpty,
                           "message": "\(mgrName) detected; \(detail)"])
        } else {
            checks.append(["name": "mise", "ok": true, "message": "no mise/asdf detected"])
        }

        // 5. Binary location (helpful when debugging "which gimme am I running").
        let binPath = CommandLine.arguments.first ?? "?"
        checks.append(["name": "binary", "ok": true,
                       "message": "gimme binary: \(binPath)"])

        return ["cmd": "doctor", "ok": true, "schema_version": Schema.version, "checks": checks]
    }

    private func runConfig(_ o: Options) throws -> [String: Any] {
        let action = o.positional.first ?? "get"
        switch action {
        case "get":
            let key = o.positional.dropFirst().first
            return ["cmd": "config", "ok": true, "schema_version": Schema.version,
                    "key": key as Any, "value": configValue(for: key) as Any]
        case "set":
            guard o.positional.count >= 3 else { throw GimmeError.usage("config set requires <key> <value>") }
            try setConfig(key: o.positional[1], value: o.positional[2])
            return ["cmd": "config", "ok": true, "schema_version": Schema.version,
                    "key": o.positional[1], "value": o.positional[2]]
        default:
            throw GimmeError.usage("config: unknown action '\(action)'")
        }
    }

    private func runIntrospect(_ o: Options) throws -> [String: Any] {
        let cmd = o.positional.first
        return Introspect.render(command: cmd)
    }

    private func runMan(_ o: Options) throws -> [String: Any] {
        return ["__raw__": Introspect.manpage()]
    }

    // MARK: brew-import

    private func runBrewImport(_ o: Options) throws -> ([String: Any], Int32) {
        // `gimme brew-import` clones Homebrew/homebrew-core (shallow) and adds
        // it as a tap named "homebrew". All .rb formulae are translated
        // on-the-fly via HomebrewLoader when searched/installed.
        let tapName = o.positional.first ?? "homebrew"
        let repoURL = "https://github.com/Homebrew/homebrew-core.git"
        let dest = world.paths.taps.appendingPathComponent(tapName)

        if FileManager.default.fileExists(atPath: dest.path) {
            return ([
                "cmd": "brew-import", "ok": true, "schema_version": Schema.version,
                "message": "tap '\(tapName)' already exists — use `gimme tap update \(tapName)` to refresh"
            ], 0)
        }

        // Clone (shallow, depth 1 — homebrew-core is huge).
        do {
            try world.tapStore.add(name: tapName, url: repoURL)
        } catch let e as GimmeError {
            return (e.toJSON(), e.category.exitCode)
        }

        // Count how many formulae were parseable.
        let formulae = world.tapStore.allFormulae()
        return ([
            "cmd": "brew-import", "ok": true, "schema_version": Schema.version,
            "tap": tapName,
            "formulae_found": formulae.count,
            "message": "Imported \(formulae.count) formulae from Homebrew. Use `gimme search <term>` to browse."
        ], 0)
    }

    // MARK: shortcut (`gimme <tool>`)

    private func runShortcut(_ o: Options) throws -> [String: Any] {
        guard let tool = o.positional.first else {
            return try runList(Options(json: o.json))
        }
        let (name, _) = splitAt(tool)
        let installed = world.state.loadInstalled()[name]
        let pins = world.state.loadPinned()
        if let pin = pins[name] {
            return ["cmd": "shortcut", "ok": true, "schema_version": Schema.version,
                    "tool": name, "message": "\(name) is pinned at \(pin)", "action": "noop"]
        }
        if installed == nil {
            // Not installed -> install latest.
            let result = try world.installer.install(query: tool, dryRun: o.dryRun, insecure: o.insecure)
            var json = result.toJSON()
            json["cmd"] = "shortcut"
            return json
        }
        // Installed: check for updates via livecheck.
        if let f = try? world.tapStore.find(name),
           let active = installed?.active,
           let latest = try world.livecheck.latest(for: f),
           latest > (Version(active) ?? Version("0")!) {
            let result = try world.installer.install(query: tool, dryRun: o.dryRun, insecure: o.insecure)
            var json = result.toJSON()
            json["cmd"] = "shortcut"
            return json
        }
        return ["cmd": "shortcut", "ok": true, "schema_version": Schema.version,
                "tool": name, "version": installed?.active ?? "",
                "message": "\(name) \(installed?.active ?? "") is current", "action": "noop"]
    }

    // MARK: helpers

    private func splitAt(_ s: String) -> (String, String?) {
        if let i = s.firstIndex(of: "@") {
            return (String(s[..<i]), String(s[s.index(after: i)...]))
        }
        return (s, nil)
    }

    private func configValue(for key: String?) -> Any {
        guard let key = key else { return world.config.toTOML() }
        switch key {
        case "behavior.autoUpdateCheck": return world.config.behavior.autoUpdateCheck
        case "behavior.pruneOldVersions": return world.config.behavior.pruneOldVersions
        case "cache.maxAgeHours": return world.config.cache.maxAgeHours
        default: return NSNull()
        }
    }

    private func setConfig(key: String, value: String) throws {
        switch key {
        case "behavior.autoUpdateCheck": world.config.behavior.autoUpdateCheck = (value == "true")
        case "behavior.pruneOldVersions": world.config.behavior.pruneOldVersions = (value == "true")
        case "cache.maxAgeHours": world.config.cache.maxAgeHours = Int(value) ?? 1
        default: throw GimmeError.usage("unknown config key: \(key)")
        }
        try world.config.toTOML().write(to: world.paths.configFile, atomically: true, encoding: .utf8)
    }
}
