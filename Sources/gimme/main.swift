import Foundation
import GimmeCore

/// A hand-rolled argv parser. ArgumentParser's subcommand/option sharing is
/// awkward for our needs (global flags on the parent + per-subcommand args);
/// gimme's surface is small enough that a focused parser is clearer and lets
/// every code path funnel through the in-process, fully-tested Gimme.run.
@main
enum GimmeCLI {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        let parsed = parse(argv)

        // Naked `gimme` with no args: show help.
        if parsed.command == nil && parsed.positional.isEmpty {
            print(Introspect.topLevelHelp())
            return
        }

        // Bare `gimme <tool>` (no subcommand): the signature shortcut.
        if parsed.command == nil, let tool = parsed.positional.first {
            run(command: .shortcut, options: parsed, positional: [tool])
            return
        }

        guard let command = parsed.command else {
            print(usage())
            exit(1)
        }
        run(command: command, options: parsed, positional: parsed.positional)
    }

    static func run(command: Gimme.Command, options: ParsedOptions, positional: [String]) {
        let prefixPath = options.prefix ?? GimmePaths.defaultUserPrefix.path
        let world: World
        do {
            world = try World(prefix: URL(fileURLWithPath: prefixPath))
        } catch {
            FileHandle.standardError.write(Data("gimme: cannot init prefix: \(error)\n".utf8))
            exit(70)
        }
        // S25: --tap is documented but not yet implemented. Fail loud rather
        // than silently ignoring it (which would violate the agent contract).
        if let tap = options.tap, !tap.isEmpty {
            let msg = "gimme: --tap is not yet implemented (requested: \(tap))"
            if options.json {
                let err = GimmeError.usage("--tap is not yet implemented")
                GimmeCLI.emit(err.toJSON(), json: true)
            } else {
                FileHandle.standardError.write(Data("\(msg)\n".utf8))
            }
            exit(1)
        }

        let gimme = Gimme(world: world)
        let opts = Gimme.Options(
            json: options.json, dryRun: options.dryRun, insecure: options.insecure,
            force: options.force, yes: options.yes, all: options.all, check: options.check,
            limit: options.limit, fields: options.fields, query: options.query,
            positional: positional, fromMise: options.fromMise, noMise: options.noMise,
            cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let (result, code) = gimme.run(command: command, options: opts)

        // If the user typed something that looks like a command but isn't one
        // (e.g. `gimme bogus`), the shortcut path returns NOT_FOUND. Show help
        // with a hint instead of a bare "no formula named 'bogus'" error.
        if code == 1,
           let err = result["error"] as? [String: Any],
           err["code"] as? String == "NOT_FOUND",
           command == .shortcut,
           let tool = positional.first,
           !tool.contains("@"),
           !opts.json {
            FileHandle.standardError.write(
                Data("gimme: '\(tool)' is not a gimme command and no formula named '\(tool)' was found.\n\n".utf8))
            print(Introspect.topLevelHelp())
            exit(1)
        }

        emit(result, json: opts.json)
        exit(code)
    }

    static func emit(_ result: [String: Any], json: Bool) {
        // `__raw__` is a verbatim-output escape hatch (used by `gimme man` to
        // emit groff source). Print it directly, ignoring json/human formatting.
        if let raw = result["__raw__"] as? String {
            print(raw)
            return
        }
        if json {
            let data = try? JSONSerialization.data(withJSONObject: result,
                                                    options: [.prettyPrinted, .sortedKeys])
            if let data = data, let s = String(data: data, encoding: .utf8) { print(s) }
        } else {
            print(humanLine(result))
        }
    }

    static func humanLine(_ r: [String: Any]) -> String {
        let ok = r["ok"] as? Bool ?? true
        if !ok, let err = r["error"] as? [String: Any] {
            let code = err["code"] as? String ?? "ERROR"
            let msg = err["message"] as? String ?? "unknown error"
            if let s = err["suggested"] as? String { return "✗ \(code): \(msg)\n  suggested: \(s)" }
            return "✗ \(code): \(msg)"
        }
        let cmd = r["cmd"] as? String ?? "gimme"
        switch cmd {
        case "install", "shortcut":
            if let action = r["action"] as? String, action == "noop" {
                return "✓ \(r["message"] ?? "")"
            }
            if let tool = r["tool"], let ver = r["version"] { return "✓ installed \(tool) \(ver)" }
            return "✓ done"
        case "uninstall": return "✓ removed \(r["tool"] ?? "")"
        case "use":       return "✓ switched \(r["tool"] ?? "") -> \(r["active"] ?? "")"
        case "pin":       return "✓ pinned \(r["tool"] ?? "") at \(r["pinned"] ?? "")"
        case "unpin":     return "✓ unpinned \(r["tool"] ?? "")"
        case "list":
            return (r["tools"] as? [[String: Any]] ?? [])
                .map { "\($0["name"] ?? "") \($0["version"] ?? "")" }
                .joined(separator: "\n")
        case "search":
            return (r["results"] as? [[String: Any]] ?? [])
                .map { "\($0["name"] ?? "") — \($0["desc"] ?? "")" }
                .joined(separator: "\n")
        case "info":
            let f = r["formula"] as? [String: Any] ?? [:]
            return "\(f["name"] ?? "") — \(f["desc"] ?? "")"
        case "outdated":
            return (r["outdated"] as? [[String: Any]] ?? [])
                .map { "\($0["tool"] ?? "") \($0["current"] ?? "") -> \($0["latest"] ?? "")" }
                .joined(separator: "\n")
        case "tap":       return (r["taps"] as? [String] ?? []).joined(separator: "\n")
        case "doctor":
            let checks = r["checks"] as? [[String: Any]] ?? []
            if checks.isEmpty {
                return "doctor: no checks produced (prefix may not be initialized)."
            }
            return checks.map { "[\(($0["ok"] as? Bool ?? false) ? "✓" : "✗")] \($0["name"] ?? ""): \($0["message"] ?? "")" }
                .joined(separator: "\n")
        default: return "\(r)"
        }
    }

    static func usage() -> String {
        return """
        gimme \(GimmeCoreVersion.value) — a Swift-based package manager for macOS

        Usage:
          gimme <tool>[@version]            install/update shortcut (signature UX)
          gimme install <tool>[@version]    explicit install
          gimme uninstall <tool>[@version]  remove
          gimme update [<tool>]|--all       update one or all non-pinned tools
          gimme use <tool> <version>        switch active version
          gimme pin|unpin <tool>            hold/release a version
          gimme list [--all]                list installed (or all known) tools
          gimme search <term>               search formulae
          gimme info <tool>                 show formula details
          gimme outdated                    show tools with updates available
          gimme tap <add|remove|list>       manage formula sources
          gimme doctor                      health check
          gimme config <get|set>            read/write config
          gimme introspect                  machine-readable CLI spec (for agents)
          gimme man                         emit groff man-page source (pipe to `man`)
          gimme brew-import                 clone Homebrew/homebrew-core and load all formulae

        Global flags: --json --dry-run --yes --prefix <path> --tap <name> --verbose --no-color
        """
    }

    struct ParsedOptions {
        var command: Gimme.Command?
        var json = false
        var dryRun = false
        var insecure = false
        var force = false
        var yes = false
        var all = false
        var check = false
        var limit: Int?
        var fields: String?
        var query: String?
        var prefix: String?
        var tap: String?
        var positional: [String] = []
        var fromMise = false
        var noMise = false
    }

    static func parse(_ argv: [String]) -> ParsedOptions {
        var o = ParsedOptions()
        // First non-flag token is the subcommand (unless it's a known tool).
        let subcommands: [String: Gimme.Command] = [
            "install": .install, "uninstall": .uninstall, "update": .update,
            "use": .use, "pin": .pin, "unpin": .unpin,
            "list": .list, "search": .search, "info": .info, "outdated": .outdated,
            "tap": .tap, "doctor": .doctor, "config": .config, "introspect": .introspect, "man": .man, "brew-import": .brewImport,
        ]
        var i = 0
        var sawSubcommand = false
        while i < argv.count {
            let a = argv[i]
            if a == "--version" || a == "-v" {
                print("gimme \(GimmeCoreVersion.value)"); exit(0)
            }
            if a == "--help" || a == "-h" {
                // Per-command help: if a subcommand precedes --help, show that
                // command's detail; otherwise show top-level help.
                print(Introspect.help(command: o.command?.rawValue)); exit(0)
            }
            // flags with values
            if a == "--prefix" { if i + 1 < argv.count { o.prefix = argv[i+1]; i += 2; continue } }
            if a == "--tap"    { if i + 1 < argv.count { o.tap = argv[i+1]; i += 2; continue } }
            if a == "--limit"  { if i + 1 < argv.count { o.limit = Int(argv[i+1]); i += 2; continue } }
            if a == "--fields" { if i + 1 < argv.count { o.fields = argv[i+1]; i += 2; continue } }
            if a == "--query"  { if i + 1 < argv.count { o.query = argv[i+1]; i += 2; continue } }
            if a == "--command"{ if i + 1 < argv.count {
                o.positional.append(argv[i+1]); i += 2; continue } }
            switch a {
            case "--json": o.json = true
            case "--dry-run": o.dryRun = true
            case "--insecure": o.insecure = true
            case "--force": o.force = true
            case "--yes": o.yes = true
            case "--all": o.all = true
            case "--check": o.check = true
            case "--from-mise": o.fromMise = true
            case "--no-mise": o.noMise = true
            case "--verbose": break
            case "--no-color": break
            default:
                if !sawSubcommand, let cmd = subcommands[a] {
                    o.command = cmd; sawSubcommand = true
                } else if !a.hasPrefix("-") {
                    o.positional.append(a)
                } else {
                    // S26: unknown flags must not be silently ignored — a typo
                    // in a safety-critical flag (--dry-run, --force, --insecure)
                    // would otherwise cause real side effects with no signal.
                    FileHandle.standardError.write(Data("gimme: unknown flag \(a)\n".utf8))
                    exit(1)
                }
            }
            i += 1
        }
        return o
    }
}
