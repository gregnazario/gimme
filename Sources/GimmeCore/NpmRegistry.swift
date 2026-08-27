import Foundation

/// Shared npm registry URL construction for the npm-family adapters
/// (bun, npm, pnpm, yarn). Kept in one place because the registry has
/// contract details that are easy to get wrong:
/// - the search endpoint takes a `text` parameter, not `q`;
/// - the query must be percent-encoded (scoped names contain `@`, and
///   multi-word queries contain spaces, which would otherwise produce an
///   invalid URL).
enum NpmRegistry {
    static func searchURL(query: String) -> URL {
        var comps = URLComponents(string: "https://registry.npmjs.org/-/v1/search")!
        comps.queryItems = [
            URLQueryItem(name: "text", value: query),
            URLQueryItem(name: "size", value: "25")
        ]
        return comps.url!
    }

    /// The dist-tags document for a package — the lightest way to learn the
    /// latest version (measured ~180 B vs multi-MB for a full packument, which
    /// is what `info()` needs but `outdated()` never did).
    static func distTagsURL(for name: String) -> URL {
        // Scoped names ("@babel/core") must have their "/" percent-encoded —
        // bare, it would parse as a path segment and the endpoint would 404.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        return URL(string: "https://registry.npmjs.org/-/package/\(encoded)/dist-tags")!
    }

    /// How long a package's dist-tags answer stays fresh on disk. One lookup
    /// per package per window across ALL npm-family adapters (they share the
    /// `npm-registry:latest:` key namespace). Precedent: App Store lookups
    /// cache 6 h, self-update 12 h.
    static let latestTTLSeconds = 3600

    private struct DistTags: Decodable { let latest: String? }

    /// Latest version of a package via the dist-tags endpoint, cached through
    /// `indexCache` (nil disables caching — tests — but still fetches).
    /// forceRefresh bypasses the cache read (and overwrites the entry).
    /// Returns nil on any failure; callers skip the package rather than flag it.
    static func latestVersion(of name: String, http: HTTPClient, indexCache: Cache?,
                              forceRefresh: Bool = false) async -> String? {
        let key = "npm-registry:latest:\(name)"
        if !forceRefresh,
           let indexCache, let cached = indexCache.get(key, ttlSeconds: latestTTLSeconds, as: String.self) {
            return cached
        }
        guard let doc: DistTags = try? await http.getJSON(distTagsURL(for: name).absoluteString, as: DistTags.self),
              let latest = doc.latest else { return nil }
        indexCache?.set(key, value: latest)
        return latest
    }
}
