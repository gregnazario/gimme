import Foundation

/// Machine-readable CLI specification. Emits every command's args, flags,
/// exit codes, and JSON output schema. Consumed by `gimme introspect` and the
/// AI-agent contract (an agent loads this once to know the whole surface).
public enum Introspect {
    public static let version: Int = Schema.version

    public struct CommandSpec: Codable {
        public var name: String
        public var usage: String
        public var summary: String
        public var args: [String]      // positional argument names
        public var flags: [FlagSpec]
        public var outputSchema: String
        public var exitCodes: [String: Int]
    }

    public struct FlagSpec: Codable {
        public var name: String
        public var type: String       // "bool" | "string" | "int"
        public var description: String
        public var `default`: String?
    }

    /// All commands gimme supports. Single source of truth for the agent contract.
    public static let commands: [CommandSpec] = [
        .init(name: "install", usage: "gimme install <tool>[@version]", summary: "Install a tool (auto-detects .tool-versions/mise.toml with no args)", args: ["tool?"], flags: [
            .init(name: "--dry-run", type: "bool", description: "Plan without executing", default: "false"),
            .init(name: "--insecure", type: "bool", description: "Skip checksum verification", default: "false"),
            .init(name: "--from-mise", type: "bool", description: "Read mise/asdf config and install batch", default: "false"),
            .init(name: "--no-mise", type: "bool", description: "Disable auto-detection of mise config", default: "false")
        ], outputSchema: "{cmd,ok,...} or {cmd:install-from-mise,tools[],summary}", exitCodes: ["success":0, "usage":1, "install":2, "conflict":3]),
        .init(name: "uninstall", usage: "gimme uninstall <tool>[@version]", summary: "Remove a tool", args: ["tool"], flags: [
            .init(name: "--force", type: "bool", description: "Remove even if depended on", default: "false")
        ], outputSchema: "{cmd,ok,tool,version}", exitCodes: ["success":0, "usage":1, "install":2, "conflict":3]),
        .init(name: "update", usage: "gimme update [<tool>]|--all", summary: "Update one or all tools", args: ["tool?"], flags: [
            .init(name: "--all", type: "bool", description: "Update every non-pinned tool", default: "false"),
            .init(name: "--check", type: "bool", description: "Report outdated, do not update", default: "false")
        ], outputSchema: "{cmd,ok,updated[]}", exitCodes: ["success":0, "install":2]),
        .init(name: "use", usage: "gimme use <tool> <version>", summary: "Switch active version (no download)", args: ["tool","version"], flags: [], outputSchema: "{cmd,ok,tool,active}", exitCodes: ["success":0, "not_found":1]),
        .init(name: "pin", usage: "gimme pin <tool>[@version]", summary: "Pin a tool to a version", args: ["tool"], flags: [], outputSchema: "{cmd,ok,tool,pinned}", exitCodes: ["success":0]),
        .init(name: "unpin", usage: "gimme unpin <tool>", summary: "Remove a pin", args: ["tool"], flags: [], outputSchema: "{cmd,ok,tool}", exitCodes: ["success":0]),
        .init(name: "list", usage: "gimme list [--all]", summary: "List installed tools", args: [], flags: [
            .init(name: "--all", type: "bool", description: "Include not-installed formulae", default: "false"),
            .init(name: "--limit", type: "int", description: "Cap number of results", default: nil),
            .init(name: "--fields", type: "string", description: "Project specific fields", default: nil),
            .init(name: "--query", type: "string", description: "Filter expression", default: nil)
        ], outputSchema: "{cmd,ok,tools[]}", exitCodes: ["success":0]),
        .init(name: "search", usage: "gimme search <term>", summary: "Search formulae", args: ["term"], flags: [], outputSchema: "{cmd,ok,results[]}", exitCodes: ["success":0]),
        .init(name: "info", usage: "gimme info <tool>", summary: "Show formula details", args: ["tool"], flags: [], outputSchema: "{cmd,ok,formula,versions[],deps[]}", exitCodes: ["success":0, "not_found":1]),
        .init(name: "outdated", usage: "gimme outdated", summary: "Show tools with updates available", args: [], flags: [], outputSchema: "{cmd,ok,outdated[]}", exitCodes: ["success":0]),
        .init(name: "tap", usage: "gimme tap <add|remove|list> [url]", summary: "Manage formula sources", args: ["action","url?"], flags: [], outputSchema: "{cmd,ok,taps[]}", exitCodes: ["success":0, "usage":1]),
        .init(name: "doctor", usage: "gimme doctor", summary: "Health check", args: [], flags: [], outputSchema: "{cmd,ok,checks[]}", exitCodes: ["success":0]),
        .init(name: "config", usage: "gimme config <get|set> [key] [value]", summary: "Read/write config", args: ["action","key?","value?"], flags: [], outputSchema: "{cmd,ok,key,value?}", exitCodes: ["success":0, "usage":1]),
        .init(name: "introspect", usage: "gimme introspect [--command <name>]", summary: "Emit machine-readable CLI spec", args: [], flags: [
            .init(name: "--command", type: "string", description: "Scope to one command", default: nil)
        ], outputSchema: "{cmd,ok,schema_version,commands[]}", exitCodes: ["success":0]),
        .init(name: "man", usage: "gimme man", summary: "Emit groff man-page source to stdout", args: [], flags: [],
              outputSchema: "groff man source (raw text)", exitCodes: ["success":0]),
    ]

    /// Global flags applicable to every command.
    public static let globalFlags: [FlagSpec] = [
        .init(name: "--json", type: "bool", description: "Emit structured JSON output", default: "false"),
        .init(name: "--dry-run", type: "bool", description: "Plan mutations without executing", default: "false"),
        .init(name: "--yes", type: "bool", description: "Non-interactive confirm", default: "false"),
        .init(name: "--prefix", type: "string", description: "Override ~/.gimme location", default: "~/.gimme"),
        .init(name: "--tap", type: "string", description: "Restrict to one tap", default: nil),
        .init(name: "--verbose", type: "bool", description: "Debug logging", default: "false"),
        .init(name: "--no-color", type: "bool", description: "Disable color output", default: "false"),
    ]

    /// The full exit-code map (single source of truth).
    public static let exitCodes: [String: Int] = [
        "success": 0, "usage": 1, "not_found": 1,
        "install": 2, "network": 2, "checksum": 2, "permission": 2,
        "conflict": 3, "lock": 4, "unknown": 70
    ]

    /// Render the full spec (or one command) as a JSON-serializable object.
    public static func render(command: String? = nil) -> [String: Any] {
        let cmds: [CommandSpec]
        if let name = command {
            cmds = commands.filter { $0.name == name }
        } else {
            cmds = commands
        }
        let encoder = JSONEncoder()
        let cmdsJSON = cmds.compactMap { spec -> [String: Any]? in
            guard let data = try? encoder.encode(spec),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return obj
        }
        let globalData = try? encoder.encode(globalFlags)
        let globalJSON = (try? JSONSerialization.jsonObject(with: globalData ?? Data())) as? [[String: Any]] ?? []
        return [
            "cmd": "introspect",
            "ok": true,
            "schema_version": version,
            "commands": cmdsJSON,
            "global_flags": globalJSON,
            "exit_codes": exitCodes
        ]
    }

    /// Render a groff man-page source string for gimme. Generated from the same
    /// command/flag/exit-code data as `introspect`, so the man page stays in
    /// sync with the CLI surface automatically.
    public static func manpage() -> String {
        var lines: [String] = []
        lines.append(".TH GIMME 1 \"\(Self.today)\" \"gimme \(GimmeCoreVersion.value)\" \"gimme Manual\"")
        lines.append(".SH NAME")
        lines.append("gimme \\- a Swift\\-based package manager for macOS")
        lines.append(".SH SYNOPSIS")
        lines.append(".B gimme")
        lines.append("[\\fIGLOBAL OPTIONS\\fR]")
        lines.append("\\fICOMMAND\\fR [\\fIARGS\\fR] [\\fICOMMAND OPTIONS\\fR]")
        lines.append(".sp")
        lines.append(".B gimme")
        lines.append("\\fITOOL\\fR[@\\fIVERSION\\fR]")
        lines.append("\\(ba the install/update shortcut (signature UX)")
        lines.append("")
        lines.append(".SH DESCRIPTION")
        lines.append("gimme installs command\\-line tools via formulae (typed TOML manifests plus")
        lines.append("optionally a sandboxed Lua install script). It uses a versioned cellar with")
        lines.append("PATH shims, supports source\\-based and download\\-based installs, reads")
        lines.append(".IR .tool-versions / mise.toml ,")
        lines.append("and coexists with mise/asdf by deferring to tools they already manage.")
        lines.append("")
        lines.append(".SH GLOBAL OPTIONS")
        for f in globalFlags {
            lines.append(".TP")
            lines.append(".BR \"\(f.name)\" \" (\(f.type))\"")
            lines.append(f.description + (f.default.map { " (default: \\fI\($0)\\fR)" } ?? ""))
        }
        lines.append("")
        lines.append(".SH COMMANDS")
        for c in commands {
            lines.append(".SS \\fB\(c.name)\\fR")
            lines.append(".RS")
            lines.append(c.summary + ".")
            lines.append(".sp")
            lines.append("Usage: \\fB\(c.usage)\\fR")
            if !c.args.isEmpty {
                lines.append(".sp")
                lines.append("Arguments: " + c.args.joined(separator: ", "))
            }
            if !c.flags.isEmpty {
                lines.append(".sp")
                lines.append("Options:")
                for f in c.flags {
                    let dv = f.default.map { " (default: \\fI\($0)\\fR)" } ?? ""
                    lines.append(".RS")
                    lines.append("\\fB\(f.name)\\fR (\(f.type)) \\(em \(f.description)\(dv)")
                    lines.append(".RE")
                }
            }
            lines.append(".RE")
        }
        lines.append("")
        lines.append(".SH EXIT STATUS")
        for (cat, code) in exitCodes.sorted(by: { $0.value < $1.value }) {
            lines.append(".TP")
            lines.append(".B \(code)")
            lines.append("\\fI\(cat.uppercased())\\fR")
        }
        lines.append("")
        lines.append(".SH FILES")
        lines.append(".TP")
        lines.append(".B ~/.gimme/")
        lines.append("Default install prefix: bin/ (shims), cellar/<tool>/<ver>/, cache/, taps/, state/.")
        lines.append(".TP")
        lines.append(".B ~/.gimme/config.toml")
        lines.append("User configuration (behavior, cache, taps).")
        lines.append("")
        lines.append(".SH SEE ALSO")
        lines.append("Full documentation: \\fBhttps://gregnazario.github.io/gimme/\\fR (or your deployed site).")
        lines.append("Design spec and decision log: the \\fIDECISIONS.md\\fR and")
        lines.append("\\fIdocs/superpowers/specs/\\fR files in the source tree.")
        return lines.joined(separator: "\n")
    }

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Render a human-readable help block for one command (or the top-level
    /// help if `command` is nil). Used by `gimme <cmd> --help` and `gimme --help`.
    public static func help(command: String?) -> String {
        guard let name = command,
              let c = commands.first(where: { $0.name == name }) else {
            return topLevelHelp()
        }
        var lines: [String] = []
        lines.append("\(c.usage)")
        lines.append("")
        lines.append(c.summary + ".")
        if !c.args.isEmpty {
            lines.append("")
            lines.append("Arguments:")
            for a in c.args { lines.append("  \(a)") }
        }
        if !c.flags.isEmpty {
            lines.append("")
            lines.append("Options:")
            for f in c.flags {
                let dv = f.default.map { " [default: \($0)]" } ?? ""
                lines.append("  \(f.name)  (\(f.type))  \(f.description)\(dv)")
            }
        }
        lines.append("")
        lines.append("Global options: " + globalFlags.map { $0.name }.joined(separator: ", "))
        lines.append("Exit codes: " + exitCodes.sorted(by: { $0.value < $1.value })
                        .map { "\($0.value)=\($0.key)" }.joined(separator: ", "))
        lines.append("")
        lines.append("JSON output shape: \(c.outputSchema)")
        lines.append("Full docs: gimme man | man gimme | https://gregnazario.github.io/gimme/")
        return lines.joined(separator: "\n")
    }

    /// Top-level help (the `usage()` text mirrors this).
    public static func topLevelHelp() -> String {
        var lines: [String] = []
        lines.append("gimme \(GimmeCoreVersion.value) — a Swift-based package manager for macOS")
        lines.append("")
        lines.append("Usage:")
        lines.append("  gimme <tool>[@version]            install/update shortcut (signature UX)")
        for c in commands where c.name != "man" {
            let pad = max(0, 33 - c.name.count - 1)
            lines.append("  gimme \(c.name)\(String(repeating: " ", count: pad))\(c.summary)")
        }
        lines.append("")
        lines.append("Global flags: " + globalFlags.map { $0.name }.joined(separator: ", "))
        lines.append("Run `gimme <command> --help` for command details, or `gimme man` for the man page.")
        return lines.joined(separator: "\n")
    }
}
