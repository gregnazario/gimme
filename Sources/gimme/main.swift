import Foundation
import GimmeCore

@main
struct GimmeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first else { printHelp(); exit(0) }

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
        }
    }

    struct Parsed {
        var verb: String
        var positional: [String]
        var from: ManagerID?
        var all: Bool
        var refresh: Bool
        var noCache: Bool
        var json: Bool
        var version: String?
        var yes: Bool
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
            let summary = try await gimme.updateAll()
            for id in summary.succeeded { print("updated \(id)") }
            for f in summary.failed { print("FAILED \(f.id): \(f.error)") }
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
                print((try? JSONEncoder().encode(statuses)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
            } else {
                for s in statuses {
                    let state = s.available ? (s.version ?? "installed") : "NOT INSTALLED"
                    let tag = s.enabled ? "" : " (disabled)"
                    // Left-pad the id to a fixed width for alignment.
                    let padded = s.id.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                    print("  \(padded) \(state)\(tag)")
                }
            }
        case "config":
            if p.positional.first == "set", p.positional.count >= 3, p.positional[1] == "priority" {
                // `gimme config set priority brew,cargo,go,uv,bun`
                var cfg = Config.loadOrCreate(at: paths.configFile)
                cfg.priority = p.positional[2].split(separator: ",").map { String($0) }
                try cfg.toTOML().write(to: paths.configFile, atomically: true, encoding: .utf8)
                print("priority updated: \(cfg.priority.joined(separator: ", "))")
            } else {
                print(Config.loadOrCreate(at: paths.configFile).toTOML())
            }
        case "help", "-h", "--help":
            printHelp()
        default:
            throw GimmeError.usage("unknown command '\(p.verb)'. See: gimme --help")
        }
    }

    static func printHelp() {
        print("""
        gimmie — unified package manager

        Usage:
          gimme install <name> [--from <manager>] [--version <v>]
          gimme uninstall <name>
          gimme upgrade <name>
          gimme update                       (upgrade all outdated)
          gimme list [--from <manager>]
          gimme outdated [--from <manager>]
          gimme search <query> [--all]
          gimme info <name>
          gimme forget <name> | --all
          gimme doctor
          gimme config [set priority <a,b,c>]

        Passthrough: gimme <manager> <args...>   (homebrew|go|uv|cargo|bun)

        Flags: --from <m> --all --refresh --no-cache --json --version <v> -y
        """)
    }
}
