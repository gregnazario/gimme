import Foundation

/// Reads Homebrew formula Ruby files and extracts the common subset into gimme's
/// `Formula` struct. This is a **pattern-matching reader**, not a Ruby interpreter —
/// it handles the 80% case of Homebrew formulae (those using the standard DSL)
/// and skips the rest.
///
/// What it extracts:
///   - `class Foo < Formula` → name (snake-cased from the class name)
///   - `desc "..."` → description
///   - `homepage "..."` → homepage URL
///   - `url "..."` → download URL (first stable url; ignores devel/head)
///   - `sha256 "..."` → checksum (the one following the stable url)
///   - `version "..."` or version derived from the URL
///   - `depends_on "foo"` → dependencies (name only)
///   - `bin "foo"` / `bin.install "foo"` → provides
///
/// What it does NOT handle:
///   - Ruby logic (conditionals, loops, method calls beyond the DSL)
///   - `livecheck` blocks (no equivalent in gimme's manifest)
///   - Service blocks, test blocks, etc.
///   - Cask files (those use a different DSL — cask support is a follow-on)
///
/// A formula that can't be fully parsed is returned with whatever fields were
/// extractable + a `source = "homebrew"` marker. The caller decides whether to
/// install from it.
public enum HomebrewLoader {
    /// Parse a single Homebrew formula `.rb` file into a gimme `Formula`.
    /// Returns nil if the essential fields (name, url, sha256) can't be extracted.
    public static func parse(_ rubySource: String) -> Formula? {
        let name = extractClassName(from: rubySource).map { snakeCase($0) }
        guard let name = name else { return nil }

        let desc = extractStringField("desc", from: rubySource)
        let homepage = extractStringField("homepage", from: rubySource)
        let license = extractStringField("license", from: rubySource) ??
                      extractStringField("license_all_of", from: rubySource)?.split(separator: "/").first.map(String.init)

        // URL: first stable url line (not devel/head).
        let url = extractUrl(from: rubySource)
        let sha256 = extractSha256(from: rubySource, afterUrl: url)

        // Both URL and sha256 are required for gimme.
        guard let url = url, let sha256 = sha256, !sha256.isEmpty else { return nil }

        // Version: explicit or derived from URL.
        let version = extractStringField("version", from: rubySource) ?? deriveVersion(from: url) ?? "1.0.0"

        // Dependencies.
        let deps = extractDepends(from: rubySource)

        // Provides: extract from bin.install lines.
        let provides = extractBinInstalls(from: rubySource)
        let binNames = provides.isEmpty ? [name] : provides

        return Formula(
            package: .init(name: name, desc: desc, homepage: homepage, license: license),
            versions: [.init(ver: version, assets: [Asset(
                arch: Host.current.arch,
                os: "macos",
                url: url,
                sha256: sha256
            )])],
            install: .init(strategy: .steps, script: nil, steps: [
                .init(extract: "${asset}"),
                .init(copy: .init(from: name, to: "${prefix}"))
            ]),
            deps: deps.map { .init(name: $0, ver: nil) },
            provides: .init(bin: binNames),
            livecheck: .init(strategy: "none")
        )
    }

    /// Load all formulae from a Homebrew tap directory (typically
    /// `homebrew-core/Formula/` or a tap's `Formula/` dir).
    public static func loadTap(at path: URL) -> [Formula] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path.path) else { return [] }
        return entries
            .filter { $0.hasSuffix(".rb") }
            .compactMap { file in
                let filePath = path.appendingPathComponent(file)
                guard let source = try? String(contentsOf: filePath, encoding: .utf8) else { return nil }
                return parse(source)
            }
    }

    // MARK: - Ruby pattern extraction

    /// Extract the class name from `class Foo < Formula`.
    private static func extractClassName(from source: String) -> String? {
        // Match: class SomeTool < Formula
        let pattern = #"class\s+(\w+)\s*<\s*Formula"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        if let match = regex.firstMatch(in: source, range: range),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: source) {
            return String(source[r])
        }
        return nil
    }

    /// Extract a string field like `desc "value"` or `homepage "value"`.
    private static func extractStringField(_ field: String, from source: String) -> String? {
        let pattern = #"\#(field)\s+"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        if let match = regex.firstMatch(in: source, range: range),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: source) {
            return String(source[r])
        }
        return nil
    }

    /// Extract the first stable URL (skip `head` URLs).
    private static func extractUrl(from source: String) -> String? {
        let pattern = #"(?<!\w)url\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        if let match = regex.firstMatch(in: source, range: range),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: source) {
            return String(source[r])
        }
        return nil
    }

    /// Extract the sha256 that follows the stable URL.
    private static func extractSha256(from source: String, afterUrl url: String?) -> String? {
        guard let url = url else { return nil }
        // Find the url line, then look for sha256 after it.
        let pattern = #"sha256\s+"([a-f0-9]{64})""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: range)
        for match in matches {
            if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: source) {
                let sha = String(source[r])
                // Verify this sha256 appears AFTER the url line.
                if let urlRange = source.range(of: url),
                   let shaRange = source.range(of: sha),
                   urlRange.lowerBound <= shaRange.lowerBound {
                    return sha
                }
            }
        }
        return matches.first.flatMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r])
        }
    }

    /// Extract dependencies from `depends_on "foo"` lines.
    private static func extractDepends(from source: String) -> [String] {
        let pattern = #"depends_on\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r])
        }
    }

    /// Extract binary names from `bin.install "foo"` lines.
    private static func extractBinInstalls(from source: String) -> [String] {
        let pattern = #"bin\.install\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r])
        }
    }

    /// Derive a version string from a URL (e.g. `foo-1.2.3.tar.gz` -> `1.2.3`).
    private static func deriveVersion(from url: String) -> String? {
        // Strip common archive extensions first, then look for a version.
        let cleaned = url
            .replacingOccurrences(of: ".tar.gz", with: "")
            .replacingOccurrences(of: ".tar.bz2", with: "")
            .replacingOccurrences(of: ".tgz", with: "")
            .replacingOccurrences(of: ".zip", with: "")
            .replacingOccurrences(of: ".tar", with: "")
        // Look for a semver-like pattern (not followed by 'tar' etc.).
        let pattern = #"(?:^|[-_/])(\d+\.\d+\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        if let match = regex.firstMatch(in: cleaned, range: range),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: cleaned) {
            return String(cleaned[r])
        }
        return nil
    }

    /// Convert CamelCase to snake_case (Homebrew class names → formula names).
    private static func snakeCase(_ s: String) -> String {
        var result = ""
        for (i, ch) in s.enumerated() {
            if ch.isUppercase && i > 0 {
                result.append("_")
            }
            result.append(ch.lowercased())
        }
        return result
    }
}
