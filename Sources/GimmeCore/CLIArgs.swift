import Foundation

/// Parsed CLI arguments (extracted from the executable target so the rules
/// are unit-testable). The safety rule: unknown `--flags` throw instead of
/// being silently ignored — a mistyped or unsupported flag once degraded
/// `gimme update --self` into a real `update all` on a build that predates
/// --self (2026-08-23 incident).
public struct CLIArgs: Equatable {
    public var verb: String
    public var positional: [String] = []
    public var from: ManagerID?
    public var all: Bool = false
    public var refresh: Bool = false
    public var noCache: Bool = false
    public var json: Bool = false
    public var version: String?
    public var yes: Bool = false
    public var selfUpdate: Bool = false

    public init(verb: String) {
        self.verb = verb
    }

    public static func parse(_ args: [String]) throws -> CLIArgs {
        var p = CLIArgs(verb: args.first ?? "help")
        var i = 1  // skip the verb
        while i < args.count {
            let a = args[i]
            switch a {
            case "--from":
                if i + 1 < args.count {
                    p.from = ManagerID(rawValue: args[i + 1])
                    i += 1
                }
            case "--all": p.all = true
            case "--refresh": p.refresh = true
            case "--no-cache": p.noCache = true
            case "--json": p.json = true
            case "--version":
                if i + 1 < args.count { p.version = args[i + 1]; i += 1 }
            case "-y", "--yes": p.yes = true
            case "--self": p.selfUpdate = true
            default:
                // Unknown double-dash tokens are flag typos or unsupported
                // features — hard-error rather than run the wrong command.
                // Single-dash tokens keep the legacy positional behavior.
                if a.hasPrefix("--") {
                    throw GimmeError.usage("unknown flag: \(a)")
                }
                p.positional.append(a)
            }
            i += 1
        }
        return p
    }
}
