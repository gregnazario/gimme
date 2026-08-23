import Foundation
import GimmeCore

@main
struct GimmeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first else { printHelp(); exit(0) }

        // Version check — intercept as a top-level command so it doesn't
        // collide with `gimme install <name> --version <v>` (that --version
        // is not the first arg, so it falls through to parseArgs).
        if first == "--version" || first == "-v" {
            print("gimme \(GimmeVersion.current)")
            exit(0)
        }

        // Passthrough: `gimme brew <args>`, `gimme cargo <args>`, etc.
        if let managerID = ManagerID(rawValue: first) {
            let binary = passthroughBinary(for: managerID)
            let rest = Array(args.dropFirst())
            do {
                let runner = ProcessRunner()
                let result = try await runner.run(binary, args: rest, env: nil, stream: { print($0) })
                exit(result.exitCode)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(2)
            }
        }

        // Verb dispatch.
        let parsed = parseArgs(args)
        do {
            try await runCommand(parsed)
        } catch let e as GimmeError {
            FileHandle.standardError.write(Data("\(e.message)\n".utf8))
            if let s = e.suggested { FileHandle.standardError.write(Data("hint: \(s)\n".utf8)) }
            exit(e.category.exitCode)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(70)
        }
    }

    static func passthroughBinary(for id: ManagerID) -> String {
        // Resolve the real path via `which`, falling back to a conventional
        // default. This makes passthrough work with mise/asdf/volta/rustup
        // home dirs without hardcoded paths.
        let name: String
        switch id {
        case .homebrew: name = "brew"
        case .go:       name = "go"
        case .uv:       name = "uv"
        case .cargo:    name = "cargo"
        case .bun:      name = "bun"
        case .npm:      name = "npm"
        case .pnpm:     name = "pnpm"
        case .yarn:     name = "yarn"
        case .gem:      name = "gem"
        case .composer: name = "composer"
        case .deno:     name = "deno"
        case .pipx:     name = "pipx"
        case .aqua:     name = "aqua"
        case .ubi:      name = "ubi"
        case .appstore: name = "mas"
        }
        if let resolved = BinaryResolver.resolve(name) { return resolved }
        // Fallbacks if `which` somehow fails to find it.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch id {
        case .homebrew: return "/opt/homebrew/bin/brew"
        case .go:       return "/usr/local/go/bin/go"
        case .uv:       return "/opt/uv/bin/uv"
        case .cargo:    return "\(home)/.cargo/bin/cargo"
        case .bun:      return "\(home)/.bun/bin/bun"
        case .npm:      return "/usr/local/bin/npm"
        case .pnpm:     return "\(home)/.local/share/pnpm/pnpm"
        case .yarn:     return "\(home)/.yarn/bin/yarn"
        case .gem:      return "/usr/bin/gem"
        case .composer: return "/usr/local/bin/composer"
        case .deno:     return "\(home)/.deno/bin/deno"
        case .pipx:     return "\(home)/.local/bin/pipx"
        case .aqua:     return "\(home)/.aqua/bin/aqua"
        case .ubi:      return "\(home)/.local/bin/ubi"
        case .appstore: return "/opt/homebrew/bin/mas"
        }
    }

    struct Parsed {
        var verb: String
        var positional: [String] = []
        var from: ManagerID?
        var all: Bool
        var refresh: Bool
        var noCache: Bool
        var json: Bool
        var version: String?
        var yes: Bool
        var selfUpdate: Bool = false
    }

    static func parseArgs(_ args: [String]) -> Parsed {
        var p = Parsed(verb: args.first ?? "help", positional: [], from: nil,
                       all: false, refresh: false, noCache: false, json: false, version: nil, yes: false)
        var i = 1  // skip verb
        while i < args.count {
            let a = args[i]
            switch a {
            case "--from":
                if i + 1 < args.count, let id = ManagerID(rawValue: args[i+1]) { p.from = id; i += 1 }
            case "--all": p.all = true
            case "--refresh": p.refresh = true
            case "--no-cache": p.noCache = true
            case "--json": p.json = true
            case "--version":
                if i + 1 < args.count { p.version = args[i+1]; i += 1 }
            case "-y", "--yes": p.yes = true
            case "--self": p.selfUpdate = true
            default: p.positional.append(a)
            }
            i += 1
        }
        return p
    }

    static func runCommand(_ p: Parsed) async throws {
        let paths = GimmePaths.defaultUser
        try paths.ensureDirectories()
        let gimme = Gimme(
            registry: Gimme.defaultRegistry(),
            preferences: Preferences.load(at: paths.preferencesFile),
            config: Config.loadOrCreate(at: paths.configFile),
            cache: Cache(directory: paths.cacheDir),
            preferencesFile: paths.preferencesFile
        )
        switch p.verb {
        case "install":
            guard let name = p.positional.first else { throw GimmeError.usage("usage: gimme install <name> [--from <m>]") }
            let result = try await gimme.install(name: name, from: p.from, options: InstallOptions(version: p.version, yes: p.yes)) { id in
                // Non-interactive (-y) auto-accepts; otherwise prompt on stderr.
                if p.yes { return true }
                print("\(id.rawValue) is not installed. Install it? [y/N] ", terminator: "")
                return readLine()?.lowercased().hasPrefix("y") ?? false
            }
            if p.json { print((try? JSONEncoder().encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}") }
            else { print("installed \(result.package.id)") }
        case "uninstall":
            guard let name = p.positional.first else { throw GimmeError.usage("usage: gimme uninstall <name>") }
            try await gimme.uninstall(name: name, from: p.from)
            print("uninstalled \(name)")
        case "upgrade":
            guard let name = p.positional.first else { throw GimmeError.usage("usage: gimme upgrade <name>") }
            try await gimme.upgrade(name: name, from: p.from)
            print("upgraded \(name)")
        case "update":
            if p.selfUpdate {
                try await runSelfUpdate()
            } else {
                let summary = try await gimme.updateAll()
                for id in summary.succeeded { print("updated \(id)") }
                for f in summary.failed { print("FAILED \(f.id): \(f.error)") }
            }
        case "list":
            let list = try await gimme.list(from: p.from, refresh: p.refresh)
            if p.json { print((try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]") }
            else { list.forEach { print("[\($0.manager.rawValue)] \($0.name) \($0.version)") } }
        case "outdated":
            let outdated = try await gimme.outdated(from: p.from, refresh: p.refresh)
            if p.json { print((try? JSONEncoder().encode(outdated)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]") }
            else { outdated.forEach { print("[\($0.manager.rawValue)] \($0.name) \($0.installedVersion) → \($0.latestVersion)") } }
        case "search":
            guard let q = p.positional.first else { throw GimmeError.usage("usage: gimme search <query> [--all]") }
            let hits = try await gimme.search(query: q, all: p.all, refresh: p.refresh)
            if p.json { print((try? JSONEncoder().encode(hits)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]") }
            else { hits.forEach { print("[\($0.manager.rawValue)] \($0.name) \($0.latestVersion) — \($0.summary)") } }
        case "info":
            guard let name = p.positional.first else { throw GimmeError.usage("usage: gimme info <name>") }
            let info = try await gimme.info(name: name, from: p.from)
            if p.json { print((try? JSONEncoder().encode(info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}") }
            else { print("\(info.name) (\(info.manager.rawValue)) \(info.latestVersion)\n\(info.summary)") }
        case "forget":
            if p.all { try gimme.forgetAll(); print("forgot all preferences") }
            else if let name = p.positional.first { try gimme.forget(name: name); print("forgot \(name)") }
            else { throw GimmeError.usage("usage: gimme forget <name> | --all") }
        case "doctor":
            // Verbose form (default): per-manager status with versions.
            let statuses = await gimme.statuses()
            if p.json {
                let runtimeMgrs = await VersionManagerDetector.detect()
                let payload: [String: Any] = ["managers": statuses, "runtimeManagers": runtimeMgrs]
                let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
                print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
            } else {
                print("Package managers:")
                for s in statuses {
                    let state = s.available ? (s.version ?? "installed") : "NOT INSTALLED"
                    let tag = s.enabled ? "" : " (disabled)"
                    let padded = s.id.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                    print("  \(padded) \(state)\(tag)")
                }
                // Runtime version managers (mise/asdf) — detect only.
                let runtimeMgrs = await VersionManagerDetector.detect()
                if !runtimeMgrs.isEmpty {
                    print("\nRuntime version managers (coexist; not managed by gimme):")
                    for vm in runtimeMgrs {
                        let count = vm.runtimes.count
                        print("  \(vm.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(count) runtime\(count == 1 ? "" : "s")")
                        // Show up to 8 runtimes as a summary.
                        for r in vm.runtimes.prefix(8) {
                            print("           \(r.tool) \(r.version)")
                        }
                        if vm.runtimes.count > 8 {
                            print("           … +\(vm.runtimes.count - 8) more")
                        }
                    }
                }
            }
        case "consolidate":
            let report = try await gimme.consolidate(refresh: p.refresh)
            if p.json {
                print((try? JSONEncoder().encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            } else if !report.hasDuplicates {
                print("No duplicates found across any ecosystem. ✅\n")
                for eco in Ecosystem.allCases where !eco.managers.isEmpty {
                    print("  \(eco.displayName.padding(toLength: 14, withPad: " ", startingAt: 0)) clean")
                }
            } else {
                print("Consolidation report — \(report.duplicates.count) duplicate\(report.duplicates.count == 1 ? "" : "s") found.\n")
                // Group steps by ecosystem for display.
                var currentEco: Ecosystem? = nil
                for step in report.steps {
                    if step.duplicate.ecosystem != currentEco {
                        currentEco = step.duplicate.ecosystem
                        print("\(step.duplicate.ecosystem.displayName):")
                    }
                    let d = step.duplicate
                    let managers = d.installed.map { $0.manager.rawValue }.joined(separator: ", ")
                    print("  \(d.name)")
                    print("    installed via: \(managers)")
                    print("    recommended:    \(d.recommendedManager.rawValue)")
                    print("    to consolidate:")
                    if let install = step.installCommand { print("      \(install)") }
                    for cmd in step.uninstallCommands { print("      \(cmd)") }
                    print("")
                }
                // Clean ecosystems compactly.
                for eco in report.cleanEcosystems {
                    print("\(eco.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) clean (no duplicates)")
                }
                print("\nRun the commands above to consolidate. No changes are made automatically.")
            }
        case "config":
            if p.positional.first == "set", p.positional.count >= 3, p.positional[1] == "priority" {
                // `gimme config set priority brew,cargo,go,uv,bun`
                var cfg = Config.loadOrCreate(at: paths.configFile)
                cfg.priority = p.positional[2].split(separator: ",").map { String($0) }
                try cfg.toTOML().write(to: paths.configFile, atomically: true, encoding: .utf8)
                print("priority updated: \(cfg.priority.joined(separator: ", "))")
            } else if p.positional.first == "set", p.positional.count >= 3, p.positional[1].hasPrefix("ecosystem.") {
                // `gimme config set ecosystem.js bun`
                let ecoRaw = String(p.positional[1].dropFirst("ecosystem.".count))
                guard let eco = Ecosystem(rawValue: ecoRaw) else {
                    throw GimmeError.usage("unknown ecosystem '\(ecoRaw)'. Valid: \(Ecosystem.allCases.map { $0.rawValue }.joined(separator: ", "))")
                }
                guard let mgr = ManagerID(rawValue: p.positional[2]) else {
                    throw GimmeError.usage("unknown manager '\(p.positional[2])'")
                }
                // Validate the manager belongs to that ecosystem.
                guard mgr.ecosystem == eco else {
                    throw GimmeError.usage("\(mgr.rawValue) is in the \(mgr.ecosystem.displayName) ecosystem, not \(eco.displayName)")
                }
                var cfg = Config.loadOrCreate(at: paths.configFile)
                cfg.ecosystems.preferences[eco] = mgr
                try cfg.toTOML().write(to: paths.configFile, atomically: true, encoding: .utf8)
                print("\(eco.displayName) consolidation target: \(mgr.rawValue)")
            } else if p.positional.first == "show", p.positional.count >= 2, p.positional[1] == "ecosystems" {
                let cfg = Config.loadOrCreate(at: paths.configFile)
                for eco in Ecosystem.allCases where !eco.managers.isEmpty {
                    let rec = cfg.ecosystems.recommended(for: eco)
                    let isDefault = cfg.ecosystems.preferences[eco] == nil
                    print("  \(eco.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(rec.rawValue)\(isDefault ? "  (default)" : "")")
                }
            } else {
                print(Config.loadOrCreate(at: paths.configFile).toTOML())
            }
        case "help", "-h", "--help":
            printHelp()
        default:
            throw GimmeError.usage("unknown command '\(p.verb)'. See: gimme --help")
        }
    }

    /// `gimme update --self`: check the latest GitHub release and replace the
    /// running binary (spec: 2026-08-22-self-update-design.md).
    static func runSelfUpdate() async throws {
        let current = GimmeVersion.current
        print("gimme \(current)")
        let updater = SelfUpdate()
        guard let release = await updater.latestRelease() else {
            throw GimmeError.network("could not check https://github.com/gregnazario/gimme/releases/latest")
        }
        guard SelfUpdate.isNewer(release.version, than: current) else {
            print("up to date (latest release: \(release.version))")
            return
        }
        print("updating to \(release.version)…")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let version = try await updater.updateCLI(at: executable, to: release) { line in print(line) }
        print("updated to \(version)")
    }

    static func printHelp() {
        print("""
        gimme — unified package manager

        Usage:
          gimme install <name> [--from <manager>] [--version <v>]
          gimme uninstall <name>
          gimme upgrade <name>
          gimme update [--self]              (upgrade all outdated; --self updates gimme)
          gimme list [--from <manager>]
          gimme outdated [--from <manager>]
          gimme search <query> [--all]
          gimme info <name>
          gimme forget <name> | --all
          gimme consolidate                    (find duplicates across managers)
          gimme doctor
          gimme config [set priority <a,b,c>]

        Passthrough: gimme <manager> <args...>   (homebrew|go|uv|cargo|bun)

        Flags: --from <m> --all --refresh --no-cache --json --version <v> -y
        """)
    }
}
