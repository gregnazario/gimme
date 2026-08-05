import Foundation

/// Manages PATH shims in `~/.gimme/bin/`. Each shim is a tiny executable that
/// exec's the active version's real binary, so the user adds `~/.gimme/bin`
/// to PATH once and version switches are instant.
public struct ShimManager {
    public let paths: GimmePaths

    public init(paths: GimmePaths) { self.paths = paths }

    /// Path of the shim for a given binary name.
    public func shimPath(for bin: String) -> URL {
        paths.bin.appendingPathComponent(bin)
    }

    /// (Re)write shims for a tool's binaries, pointing at the given version.
    /// SECURITY: tool/version/bin are validated before use — they become both
    /// path components (under cellar/<tool>/<version>/bin/<bin>) and fragments
    /// of a generated shell script, so they must be filename/shell-safe.
    public func activate(tool: String, version: String, bins: [String]) throws {
        try NameSafety.checkFormulaName(tool, kind: "shim tool")
        try NameSafety.checkFormulaName(version, kind: "shim version")
        try FileManager.default.createDirectory(at: paths.bin, withIntermediateDirectories: true)
        for bin in bins {
            try NameSafety.checkFormulaName(bin, kind: "shim bin")
            let shim = shimPath(for: bin)
            let script = shimScript(tool: tool, version: version, bin: bin)
            try script.write(to: shim, atomically: true, encoding: .utf8)
            // chmod +x
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: shim.path)
        }
    }

    /// Remove shims for the given binaries.
    public func deactivate(bins: [String]) throws {
        for bin in bins {
            let shim = shimPath(for: bin)
            if FileManager.default.fileExists(atPath: shim.path) {
                try FileManager.default.removeItem(at: shim)
            }
        }
    }

    /// The shim script content: resolve the prefix-relative cellar binary.
    /// `$GIMME_PREFIX` overrides the install location (for tests/isolation).
    private func shimScript(tool: String, version: String, bin: String) -> String {
        let defaultPrefix = paths.prefix.path
        return """
        #!/bin/sh
        # gimme shim for \(tool)@\(version) -> \(bin)
        GIMME_PREFIX="${GIMME_PREFIX:-\(defaultPrefix)}"
        exec "$GIMME_PREFIX/cellar/\(tool)/\(version)/bin/\(bin)" "$@"

        """
    }
}
