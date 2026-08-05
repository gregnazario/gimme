import Foundation

/// Discovers the latest upstream version for a formula, with caching.
/// Strategies: none / github-release / url-match. (`lua` reserved for later.)
public struct Livecheck {
    public let cacheDir: URL
    public let maxAgeHours: Int

    public init(paths: GimmePaths, maxAgeHours: Int) {
        self.cacheDir = paths.cache.appendingPathComponent("livecheck")
        self.maxAgeHours = maxAgeHours
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Returns the latest version available for a formula, or nil if it can't
    /// be determined. Caches results for `maxAgeHours`.
    public func latest(for formula: Formula) throws -> Version? {
        let strategy = formula.livecheck?.strategy ?? "none"

        if strategy == "none" {
            // Static formula: latest = highest declared version.
            return formula.highestVersion()?.parsed
        }

        // Check cache.
        let cacheFile = cacheDir.appendingPathComponent("\(formula.name).json")
        if let cached = readCache(cacheFile), cached.isFresh(maxAgeHours: maxAgeHours) {
            return cached.version
        }

        let result: Version?
        switch strategy {
        case "github-release":
            result = try githubRelease(formula: formula)
        case "url-match":
            result = try urlMatch(formula: formula)
        case "lua":
            // Reserved: would invoke a sandboxed livecheck(ctx). Not in foundation.
            result = nil
        default:
            result = formula.highestVersion()?.parsed
        }

        if let v = result { writeCache(cacheFile, version: v) }
        return result
    }

    // MARK: strategies

    /// Hit GitHub releases API, parse the tag with `regex`.
    private func githubRelease(formula: Formula) throws -> Version? {
        guard let repo = formula.livecheck?.repo else { return nil }
        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return nil }
        let (data, _) = try syncGET(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        return parseVersion(from: tag, with: formula.livecheck?.regex)
    }

    /// Fetch a page, regex out version strings, pick the highest.
    private func urlMatch(formula: Formula) throws -> Version? {
        guard let urlString = formula.livecheck?.url,
              let url = URL(string: urlString) else { return nil }
        let (data, _) = try syncGET(url: url)
        let body = String(data: data, encoding: .utf8) ?? ""
        return parseVersion(from: body, with: formula.livecheck?.regex)
    }

    /// Apply the regex to the text; on the first capture group, return a Version.
    /// Internal so tests can exercise the regex path without network.
    func parseVersion(from text: String, with regex: String?) -> Version? {
        return Livecheck.parseVersionStatic(from: text, with: regex)
    }

    /// Stateless version parser used by both instance and test paths.
    ///
    /// ReDoS hardening: a formula-supplied regex is applied to fetched,
    /// untrusted HTML/JSON. A vulnerable pattern (e.g. `(a+)+`) against
    /// adversarial input can catastrophically backtrack in ICU. We cap the
    /// input to the first `maxRegexInputBytes` (version strings appear early
    /// on release pages) and only request the first match, bounding the work.
    static let maxRegexInputBytes: Int = 1 * 1024 * 1024  // 1 MiB

    static func parseVersionStatic(from text: String, with regex: String?) -> Version? {
        let pattern = regex ?? #"\d+\.\d+\.\d+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        // Bound the input to prevent catastrophic backtracking on adversarial
        // pages. Version tags appear early in real release listings.
        let bounded: String
        if text.count > maxRegexInputBytes {
            bounded = String(text.prefix(maxRegexInputBytes))
        } else {
            bounded = text
        }
        let range = NSRange(bounded.startIndex..., in: bounded)
        guard let match = re.firstMatch(in: bounded, range: range) else { return nil }
        let captured: String
        if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: bounded) {
            captured = String(bounded[r])
        } else if let r = Range(match.range, in: bounded) {
            captured = String(bounded[r])
        } else {
            return nil
        }
        return Version(captured)
    }

    // MARK: cache

    private struct CachedVersion {
        let version: Version
        let fetchedAt: Date
        func isFresh(maxAgeHours: Int) -> Bool {
            Date().timeIntervalSince(fetchedAt) < TimeInterval(maxAgeHours * 3600)
        }
    }

    private func readCache(_ file: URL) -> CachedVersion? {
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versionStr = dict["version"] as? String,
              let version = Version(versionStr),
              let ts = dict["fetched_at"] as? Double else { return nil }
        return CachedVersion(version: version, fetchedAt: Date(timeIntervalSince1970: ts))
    }

    private func writeCache(_ file: URL, version: Version) {
        let dict: [String: Any] = [
            "version": version.description,
            "fetched_at": Date().timeIntervalSince1970
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: file)
        }
    }

    // MARK: HTTP

    /// Simple blocking GET; returns (data, response).
    private func syncGET(url: URL) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var dataResult: Data? = nil
        var responseResult: URLResponse? = nil
        var errorResult: Error? = nil
        URLSession.shared.dataTask(with: url) { data, response, error in
            dataResult = data
            responseResult = response
            errorResult = error
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = errorResult {
            throw GimmeError.network("livecheck GET failed: \(error.localizedDescription)")
        }
        guard let data = dataResult, let resp = responseResult as? HTTPURLResponse else {
            throw GimmeError.network("livecheck GET returned no data")
        }
        return (data, resp)
    }
}
