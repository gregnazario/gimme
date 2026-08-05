import Foundation

/// Security helper: validate that a path a formula/script supplied resolves to
/// a location inside an allowed root directory. Prevents path-traversal escapes
/// via absolute paths, `..`, or symlink redirection.
///
/// Use for any destination a sandboxed formula or declarative `steps` formula
/// can influence (extract targets, install_dir destinations, mkdir, copy `to`).
public enum PathContainment {
    /// Returns true iff `path` (after standardizing and resolving symlinks on
    /// the existing portion) is `root` or nested under it.
    ///
    /// `path` may not yet exist; we standardize its lexically-resolvable prefix
    /// and compare against `root`'s standardized path. This catches absolute
    /// paths, `..` traversal, and `${prefix}/../etc`-style escapes.
    public static func isContained(_ path: URL, under root: URL) -> Bool {
        let rootStd = root.standardizedFileURL.path
        // Resolve as much of `path` as exists (resolves symlinks on the prefix
        // that already exists), then standardize the rest.
        let resolved = resolvingExistingPrefix(path)
        let pathStd = resolved.standardizedFileURL.path
        return pathStd == rootStd || pathStd.hasPrefix(rootStd + "/")
    }

    /// Reject a path component name if it could traverse out of a directory
    /// when used as a filename (`..`, absolute, or path separators).
    public static func isSafeComponent(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return false }
        if name.contains("/") { return false }
        // Backslash is a path separator on some systems; reject to be safe.
        if name.contains("\\") { return false }
        if name.hasPrefix(".") {
            // Allow dotted files like ".bashrc" but reject ".." (already above).
            // No additional restriction needed.
        }
        return true
    }

    /// Walk `path` upward while components exist on disk, resolving symlinks;
    /// stop at the first nonexistent ancestor and return the path standardized.
    private static func resolvingExistingPrefix(_ path: URL) -> URL {
        let fm = FileManager.default
        var current = path.standardizedFileURL
        // If the file exists, resolvingSymlinksInPath gives the true target.
        if fm.fileExists(atPath: current.path) {
            return current.resolvingSymlinksInPath()
        }
        // Otherwise, find the deepest existing ancestor, resolve it, then
        // re-append the missing tail. This handles the common case of a
        // destination path whose parent exists but the final component doesn't.
        var missing: [String] = []
        while !fm.fileExists(atPath: current.path) {
            missing.insert(current.lastPathComponent, at: 0)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }  // root
            current = parent
        }
        if fm.fileExists(atPath: current.path) {
            current = current.resolvingSymlinksInPath()
        }
        for part in missing { current.appendPathComponent(part) }
        return current
    }
}
