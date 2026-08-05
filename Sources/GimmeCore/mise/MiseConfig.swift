import Foundation

/// A single tool request parsed from mise/asdf config: a tool name + spec.
public struct ToolRequest: Equatable {
    public let tool: String
    public let spec: MiseVersionSpec
    public init(tool: String, spec: MiseVersionSpec) {
        self.tool = tool; self.spec = spec
    }
}

/// Parses `.tool-versions` (asdf) and `mise.toml` `[tools]` (mise) and
/// discovers config by walking up from a cwd, merging with closer-wins.
public enum MiseConfig {
    /// Parse asdf `.tool-versions` text. Malformed lines are dropped silently
    /// (a name-only line is malformed — a spec is required).
    public static func parseToolVersions(_ text: String) -> [ToolRequest] {
        var out: [ToolRequest] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                .map { String($0) }
            guard parts.count >= 2 else { continue }  // need name + spec
            let tool = parts[0]
            let specRaw = parts[1]
            out.append(ToolRequest(tool: tool, spec: MiseVersionSpec.parse(specRaw)))
        }
        return out
    }

    /// Parse `mise.toml` `[tools]` section into requests. Other sections ignored.
    public static func parseMiseToml(_ data: Data) throws -> [ToolRequest] {
        let root = try TOML.parseData(data)
        guard let tools = root.table("tools") else { return [] }
        var out: [ToolRequest] = []
        for (name, value) in tools.children {
            let specRaw: String
            if let s = value.asString {
                specRaw = s
            } else if let tbl = value.asTable, let v = tbl.string("version") {
                specRaw = v
            } else {
                continue  // unrecognized value shape -> skip
            }
            out.append(ToolRequest(tool: name, spec: MiseVersionSpec.parse(specRaw)))
        }
        return out
    }

    /// Walk up from `cwd` looking for `.tool-versions` and `mise.toml`, stopping
    /// at the first directory containing `.git` (project root) or the filesystem
    /// root. Merge results: closer-to-cwd wins per-tool, different tools accumulate.
    /// Returns the merged requests and a human-readable source label, or
    /// (empty, nil) if no config was found.
    public static func discover(startingAt cwd: URL) -> (requests: [ToolRequest], source: String?) {
        let fm = FileManager.default
        // Collect config files from cwd upward, in order from cwd -> up.
        // Cap the walk depth defensively so a deep tree without .git can't
        // traverse the whole filesystem.
        var found: [(URL, [ToolRequest])] = []
        var dir: URL = cwd.standardizedFileURL
        var reachedGitRoot = false
        var depth = 0
        let maxDepth = 64
        while depth < maxDepth {
            let tv = dir.appendingPathComponent(".tool-versions")
            if fm.fileExists(atPath: tv.path), let data = try? Data(contentsOf: tv),
               let text = String(data: data, encoding: .utf8) {
                let reqs = parseToolVersions(text)
                if !reqs.isEmpty { found.append((tv, reqs)) }
            }
            let mt = dir.appendingPathComponent("mise.toml")
            if fm.fileExists(atPath: mt.path), let data = try? Data(contentsOf: mt),
               let reqs = try? parseMiseToml(data) {
                if !reqs.isEmpty { found.append((mt, reqs)) }
            }
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                reachedGitRoot = true
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }  // filesystem root
            dir = parent
            depth += 1
        }
        _ = reachedGitRoot  // (walk stops at .git, root, or depth cap)

        if found.isEmpty { return ([], nil) }

        // Merge: iterate found in reverse (outermost first) so closer entries
        // overwrite on collision. Preserve first-seen order for stable output.
        var merged: [String: ToolRequest] = [:]
        var order: [String] = []
        for (_, reqs) in found.reversed() {
            for req in reqs {
                if merged[req.tool] == nil { order.append(req.tool) }
                merged[req.tool] = req
            }
        }
        let requests = order.map { merged[$0]! }
        let source = found.first?.0.lastPathComponent
        return (requests, source)
    }

    private static func stripComment(_ line: String) -> String {
        // Drop from the first `#` to end of line.
        if let i = line.firstIndex(of: "#") { return String(line[..<i]) }
        return line
    }
}
