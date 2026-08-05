import Foundation

/// Manages the on-disk cellar: `~/.gimme/cellar/<tool>/<version>/`.
/// The cellar is the source of truth — state files are derived from it.
///
/// `Cellar` is a class (reference type) so that `StateStore` can hold a stable
/// reference to it for self-healing. `scanAll` is NOT memoized across calls:
/// receipts can be written by paths outside this class's mutations (the install
/// atomicity backup, tests, external tools), so a memo would risk staleness.
/// If profiling shows `scanAll` is hot, the safe caching boundary is one
/// logical command, with explicit invalidation hooks added at every writer.
public final class Cellar {
    public let paths: GimmePaths

    public init(paths: GimmePaths) { self.paths = paths }

    /// The install prefix for a tool@version.
    public func prefix(for tool: String, version: String) -> URL {
        paths.cellar.appendingPathComponent(tool).appendingPathComponent(version)
    }

    /// All installed version dirs for a tool (names only), sorted highest-first.
    public func installedVersions(for tool: String) -> [String] {
        let dir = paths.cellar.appendingPathComponent(tool)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return entries
            .filter { FileManager.default.isDirectory(dir.appendingPathComponent($0)) }
            .sorted { (Version($0) ?? Version("0")!) > (Version($1) ?? Version("0")!) }
    }

    /// Read the receipt for an installed tool@version, if present.
    public func receipt(for tool: String, version: String) -> Receipt? {
        Receipt.read(from: prefix(for: tool, version: version))
    }

    /// Is the tool installed (at any version, or a specific one)?
    public func hasInstalled(_ tool: String, version: Version? = nil) -> Bool {
        guard let v = version else { return !installedVersions(for: tool).isEmpty }
        return installedVersions(for: tool).contains { Version($0) == v }
    }

    /// Atomic commit: move a staged prefix into the cellar via rename.
    /// If the target already exists, remove it first (re-install same version).
    public func commit(staged: URL, tool: String, version: String) throws {
        let target = prefix(for: tool, version: version)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: staged, to: target)
    }

    /// Remove a specific installed version.
    public func remove(tool: String, version: String) throws {
        let target = prefix(for: tool, version: version)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    /// Full cellar scan: every (tool, version, receipt) triple. Used to rebuild
    /// derived state and for `gimme list`.
    public func scanAll() -> [(tool: String, version: String, receipt: Receipt?)] {
        guard let tools = try? FileManager.default.contentsOfDirectory(atPath: paths.cellar.path) else {
            return []
        }
        var out: [(String, String, Receipt?)] = []
        for tool in tools.sorted() {
            let toolDir = paths.cellar.appendingPathComponent(tool)
            guard FileManager.default.isDirectory(toolDir) else { continue }
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: toolDir.path) else {
                continue
            }
            for version in versions {
                let vDir = toolDir.appendingPathComponent(version)
                guard FileManager.default.isDirectory(vDir) else { continue }
                out.append((tool, version, Receipt.read(from: vDir)))
            }
        }
        return out
    }

    /// The list of tools installed (unique names).
    public func installedTools() -> [String] {
        guard let tools = try? FileManager.default.contentsOfDirectory(atPath: paths.cellar.path) else {
            return []
        }
        return tools.filter { FileManager.default.isDirectory(paths.cellar.appendingPathComponent($0)) }
            .sorted()
    }
}

extension FileManager {
    /// Is the given URL a directory?
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
