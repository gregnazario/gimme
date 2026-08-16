import Foundation

/// Detects runtime version managers (mise, asdf) and lists what they manage.
///
/// These are intentionally NOT modeled as `PackageManager`s — they manage
/// *runtimes* (node@20, python@3.12), not CLI packages, and the conceptual fit
/// is poor (no search, version-pinned names, per-directory pinning). gimme
/// coexists with them via PATH augmentation; this detector makes them visible
/// in `doctor` so users understand the relationship.
public struct RuntimeManagerStatus: Equatable {
    public enum Kind: String, Equatable, Codable { case mise, asdf }
    public let kind: Kind
    public let path: String                       // resolved binary path
    public let runtimes: [RuntimeEntry]           // runtimes it manages

    public struct RuntimeEntry: Equatable, Codable {
        public let tool: String       // "node", "python", "go", ...
        public let version: String    // "20.10.0"
        public let source: String     // config source path (if known)
        public init(tool: String, version: String, source: String) {
            self.tool = tool; self.version = version; self.source = source
        }
    }

    public init(kind: Kind, path: String, runtimes: [RuntimeEntry]) {
        self.kind = kind; self.path = path; self.runtimes = runtimes
    }
}

/// Detects runtime version managers and enumerates their managed runtimes.
/// All network/subprocess-free beyond a local `mise ls` / `asdf list`.
public enum VersionManagerDetector {
    /// Detect mise and asdf, listing the runtimes each manages.
    public static func detect() async -> [RuntimeManagerStatus] {
        var out: [RuntimeManagerStatus] = []
        if let mise = await detectMise() { out.append(mise) }
        if let asdf = await detectAsdf() { out.append(asdf) }
        return out
    }

    private static func detectMise() async -> RuntimeManagerStatus? {
        guard let path = BinaryResolver.resolve("mise") else { return nil }
        // `mise ls` -> whitespace-separated columns: "tool  version  source  tag"
        let runner = ProcessRunner()
        let res = try? await runner.run(path, args: ["ls"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else {
            return RuntimeManagerStatus(kind: .mise, path: path, runtimes: [])
        }
        let runtimes = parseTable(res.stdout)
        return RuntimeManagerStatus(kind: .mise, path: path, runtimes: runtimes)
    }

    private static func detectAsdf() async -> RuntimeManagerStatus? {
        guard let path = BinaryResolver.resolve("asdf") else { return nil }
        let runner = ProcessRunner()
        let res = try? await runner.run(path, args: ["list"], env: nil, stream: nil)
        guard let res, res.exitCode == 0 else {
            return RuntimeManagerStatus(kind: .asdf, path: path, runtimes: [])
        }
        // asdf list output: "  nodejs 20.10.0" (indented "tool version").
        let runtimes = res.stdout.split(separator: "\n").compactMap { line -> RuntimeManagerStatus.RuntimeEntry? in
            let parts = String(line).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return nil }
            // asdf lists "plugin version"; some lines are plugin headers.
            if parts[0] == "*" { return nil }
            return RuntimeManagerStatus.RuntimeEntry(tool: parts[0], version: parts[1], source: "")
        }
        return RuntimeManagerStatus(kind: .asdf, path: path, runtimes: runtimes)
    }

    /// Parse whitespace-columnar output like mise's:
    ///   "node    20.10.0    ~/.config/mise/config.toml    latest"
    /// Takes the first column as tool, second as version, third as source.
    private static func parseTable(_ output: String) -> [RuntimeManagerStatus.RuntimeEntry] {
        output.split(separator: "\n").compactMap { line in
            let parts = String(line).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return nil }
            let tool = parts[0]
            let version = parts[1]
            let source = parts.count >= 3 ? parts[2] : ""
            // Skip mise header/separator lines.
            if tool == "Tool" || tool == "Version" || tool.isEmpty { return nil }
            return RuntimeManagerStatus.RuntimeEntry(tool: tool, version: version, source: source)
        }
    }
}
