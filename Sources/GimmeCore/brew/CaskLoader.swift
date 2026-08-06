import Foundation

/// Reads Homebrew Cask Ruby files and extracts the cask metadata into a gimme
/// Formula. Casks install GUI `.app` bundles from `.dmg`/`.zip` archives — a
/// different install flow from CLI formulae.
///
/// What it extracts:
///   - `cask "foo" do` → name
///   - `version "..."` → version
///   - `url "..."` → download URL (handles `#{version}` interpolation)
///   - `sha256 "..."` → checksum (handles arch-specific hashes)
///   - `name "..."` → human-readable name → desc
///   - `desc "..."` → description (if present)
///   - `homepage "..."` → homepage
///   - `app "Foo.app"` → the .app bundle name inside the archive
///
/// Arch handling: casks with `on_arm`/`on_intel` blocks or `arch:` hashes are
/// resolved to the current host's architecture automatically.
public struct CaskInfo: Equatable {
    public let name: String           // cask token (e.g. "visual-studio-code")
    public let displayName: String?   // from `name` stanza
    public let desc: String?          // from `desc` stanza
    public let homepage: String?
    public let version: String
    public let url: String
    public let sha256: String
    public let appName: String?       // from `app "Foo.app"` — the bundle to install

    public init(name: String, displayName: String?, desc: String?, homepage: String?,
                version: String, url: String, sha256: String, appName: String?) {
        self.name = name; self.displayName = displayName; self.desc = desc
        self.homepage = homepage; self.version = version; self.url = url
        self.sha256 = sha256; self.appName = appName
    }
}

public enum CaskLoader {
    /// Parse a Homebrew Cask `.rb` file. Returns nil if essential fields can't
    /// be extracted (name, url, sha256).
    public static func parse(_ rubySource: String, host: Host = .current) -> CaskInfo? {
        guard let name = extractCaskName(from: rubySource) else { return nil }

        // Handle arch: determine which block to read from (on_arm vs on_intel).
        let isArm = host.arch == "arm64"

        // Version: check on_arm/on_intel blocks first, then top-level.
        let version = extractFromArchBlock(from: rubySource, arm: isArm, field: "version")
            ?? extractStringField("version", from: rubySource)
        guard let version = version else { return nil }

        // URL: resolve #{version} interpolation.
        let url = extractFromArchBlock(from: rubySource, arm: isArm, field: "url")
            ?? extractUrlField(from: rubySource)
        guard let url = url?.interpolatingVersion(version) else { return nil }

        // sha256: handle arch-specific hashes.
        let sha = extractSha256(from: rubySource, arm: isArm, version: version)
        guard let sha = sha, !sha.isEmpty else { return nil }

        let displayName = extractStringField("name", from: rubySource)
        let desc = extractStringField("desc", from: rubySource)
        let homepage = extractStringField("homepage", from: rubySource)
        let appName = extractAppField(from: rubySource)

        return CaskInfo(
            name: name, displayName: displayName, desc: desc ?? displayName,
            homepage: homepage, version: version, url: url, sha256: sha, appName: appName)
    }

    /// Load all casks from a directory (typically `Casks/` inside a homebrew tap).
    public static func loadCasks(at path: URL, host: Host = .current) -> [CaskInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path.path) else { return [] }
        return entries
            .filter { $0.hasSuffix(".rb") }
            .compactMap { file in
                let filePath = path.appendingPathComponent(file)
                guard let source = try? String(contentsOf: filePath, encoding: .utf8) else { return nil }
                return parse(source, host: host)
            }
    }

    // MARK: - Ruby pattern extraction

    /// Extract the cask token from `cask "foo" do`.
    private static func extractCaskName(from source: String) -> String? {
        let pattern = #"cask\s+"([^"]+)"\s+do"#
        return firstMatch(pattern: pattern, group: 1, in: source)
    }

    /// Extract a simple string field like `version "1.2.3"`.
    private static func extractStringField(_ field: String, from source: String) -> String? {
        let pattern = #"\#(field)\s+"([^"]*)""#
        return firstMatch(pattern: pattern, group: 1, in: source)
    }

    /// Extract a url field (handles both `url "..."` and `url "...", ...`).
    private static func extractUrlField(from source: String) -> String? {
        let pattern = #"url\s+"([^"]+)""#
        return firstMatch(pattern: pattern, group: 1, in: source)
    }

    /// Extract sha256. Handles both block syntax (on_arm/on_intel with sha256 inside)
    /// and hash syntax (sha256 arm: "...", intel: "...").
    private static func extractSha256(from source: String, arm: Bool, version: String) -> String? {
        // 1. Try extracting from on_arm/on_intel block first.
        //    extractFromArchBlock returns the FIELD VALUE directly (already extracted
        //    via extractStringField), so if it's 64 hex chars, return it.
        if let blockSha = extractFromArchBlock(from: source, arm: arm, field: "sha256") {
            // extractFromArchBlock returns the raw value from `sha256 "value"`.
            if blockSha.count == 64 && blockSha.allSatisfy({ $0.isHexDigit }) {
                return blockSha
            }
            // If it has the full `sha256 "..."` line, extract again.
            if let sha = firstMatch(pattern: #""([a-f0-9]{64})""#, group: 1, in: blockSha) {
                return sha
            }
        }
        // 2. Try arch-specific hash syntax: sha256 arm: "...", intel: "..."
        let archKey = arm ? "arm" : "intel"
        let archPattern = #"\#(archKey):\s*"?([a-f0-9]{64})"?"#
        if let sha = firstMatch(pattern: archPattern, group: 1, in: source) {
            return sha
        }
        // 3. Simple: sha256 "..."
        return firstMatch(pattern: #"sha256\s+"([a-f0-9]{64})""#, group: 1, in: source)
    }

    /// Extract `app "Foo.app"` → "Foo.app".
    private static func extractAppField(from source: String) -> String? {
        let pattern = #"app\s+"([^"]+\.app)""#
        return firstMatch(pattern: pattern, group: 1, in: source)
    }

    /// Extract a field from an `on_arm`/`on_intel` block.
    private static func extractFromArchBlock(from source: String, arm: Bool, field: String) -> String? {
        let blockName = arm ? "on_arm" : "on_intel"
        // Use regex to capture the block contents: `on_arm do\n  ... \nend`
        let pattern = #"\#(blockName)\s+do\b([\s\S]*?)\bend"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: source) else { return nil }
        let block = String(source[r])
        if field == "url" {
            return extractUrlField(from: block)
        }
        return extractStringField(field, from: block)
    }

    /// Run a regex and return the first capture group.
    private static func firstMatch(pattern: String, group: Int, in source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        if let match = regex.firstMatch(in: source, range: range),
           match.numberOfRanges > group,
           let r = Range(match.range(at: group), in: source) {
            return String(source[r])
        }
        return nil
    }
}

private extension String {
    /// Resolve `#{version}` interpolation in a cask URL.
    func interpolatingVersion(_ version: String) -> String {
        replacingOccurrences(of: "#{version}", with: version)
    }
}
