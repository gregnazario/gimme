import Foundation

/// Detects whether a tool is currently managed by mise or asdf, by resolving
/// it on PATH, realpathing the result, and checking if it lives under a known
/// mise/asdf shims directory. Does NOT require mise to be installed: if none
/// of the candidate shim dirs exist or the tool isn't on PATH, returns nil.
///
/// gimme's own shim dir (`~/.gimme/bin`) is always excluded from consideration
/// so gimme never detects itself.
public struct MiseDetector {
    public enum Manager: String, Equatable {
        case mise
        case asdf
    }

    public let paths: GimmePaths
    public let environment: [String: String]

    public init(paths: GimmePaths, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.environment = environment
    }

    /// Does mise or asdf currently manage `tool`?
    public func isManaged(byManager tool: String) -> Bool {
        owner(of: tool) != nil
    }

    /// Which manager owns `tool`, if any?
    public func owner(of tool: String) -> Manager? {
        guard let resolved = resolveOnPath(tool) else { return nil }
        // Compare the PATH-resolved candidate (standardized, NOT symlink-followed
        // to the final binary) against the shim dirs. The signal is "the PATH
        // entry points at something *inside* a shims dir" — following the
        // symlink all the way out would lose that signal.
        let candidateStd = resolved.standardizedFileURL.path
        let dirs = candidateShimDirs()
        for dir in dirs {
            let dirStd = dir.standardizedFileURL.path
            if candidateStd.hasPrefix(dirStd + "/") {
                return .mise  // dir came from mise candidates below
            }
        }
        for dir in candidateAsdfDirs() {
            let dirStd = dir.standardizedFileURL.path
            if candidateStd.hasPrefix(dirStd + "/") {
                return .asdf
            }
        }
        return nil
    }

    // MARK: - internals

    /// mise shim directories (in priority order): $MISE_DATA_DIR/shims, then
    /// the default ~/.local/share/mise/shims. Only existing dirs are returned.
    private func candidateShimDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [URL] = []
        if let dataDir = environment["MISE_DATA_DIR"] {
            candidates.append(URL(fileURLWithPath: dataDir).appendingPathComponent("shims"))
        }
        candidates.append(URL(fileURLWithPath: home)
            .appendingPathComponent(".local/share/mise/shims"))
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// asdf shim directory: ~/.asdf/shims (no env override). Included only if it exists.
    private func candidateAsdfDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".asdf/shims")
        return FileManager.default.fileExists(atPath: dir.path) ? [dir] : []
    }

    /// Search PATH for an executable named `tool`, excluding gimme's own bin.
    /// Returns the resolved file URL (the PATH entry + tool name) or nil.
    private func resolveOnPath(_ tool: String) -> URL? {
        let pathEnv = environment["PATH"] ?? ""
        let gimmeBinStd = paths.bin.standardizedFileURL.path
        for dir in pathEnv.split(separator: ":").map(String.init) {
            let dirURL = URL(fileURLWithPath: dir).standardizedFileURL
            // Exclude gimme's own shim dir so we never detect ourselves.
            if dirURL.path == gimmeBinStd { continue }
            let candidate = dirURL.appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
