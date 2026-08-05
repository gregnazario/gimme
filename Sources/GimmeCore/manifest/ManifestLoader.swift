import Foundation

/// Loads `formula.toml` from a directory into a `Formula`.
public enum ManifestLoader {
    public static let filename = "formula.toml"

    /// Decode a Formula from raw TOML bytes.
    public static func decode(_ data: Data) throws -> Formula {
        do {
            return try TOMLDecoder().decode(Formula.self, from: data)
        } catch {
            throw GimmeError.usage("invalid formula manifest: \(error)")
        }
    }

    /// Load from a directory containing `formula.toml`.
    public static func load(directory: URL) throws -> Formula {
        let file = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw GimmeError.usage("no \(filename) in \(directory.path)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw GimmeError.usage("could not read \(file.path): \(error)")
        }
        return try decode(data)
    }

    /// Validate a formula: every asset must declare sha256 (design §3), and
    /// every name that flows into a shim script or path component (package name,
    /// version strings, provided bin names) must be filename/shell-safe so a
    /// malicious tap can't inject into the generated shim or escape via `..`.
    public static func validate(_ formula: Formula) throws {
        try NameSafety.checkFormulaName(formula.name, kind: "package name")
        for v in formula.versions {
            try NameSafety.checkFormulaName(v.ver, kind: "version")
            for asset in v.assets where asset.sha256.isEmpty {
                throw GimmeError.usage(
                    "formula \(formula.name) version \(v.ver): asset \(asset.url) missing sha256")
            }
        }
        for bin in formula.provides.bin {
            try NameSafety.checkFormulaName(bin, kind: "provides.bin entry")
        }
    }
}

/// SECURITY: validate that names which become path components AND shell-script
/// fragments (tool, version, bin) contain no `/`, no shell metacharacters, no
/// `..`, no whitespace, no quotes — so they can't break out of the cellar path
/// or inject into the generated shim script.
public enum NameSafety {
    /// Characters allowed in tool/version/bin names: alphanumerics plus a small
    /// set of punctuation that's safe in both filenames and unquoted shell.
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")

    /// True iff `name` is safe to use as a path component and to interpolate
    /// into a shim script without escaping.
    public static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Throw a usage error if `name` is unsafe; `kind` labels it in the message.
    public static func checkFormulaName(_ name: String, kind: String) throws {
        guard isSafe(name) else {
            throw GimmeError.usage(
                "unsafe \(kind) '\(name)': only letters, digits, and . _ + - allowed")
        }
    }
}
