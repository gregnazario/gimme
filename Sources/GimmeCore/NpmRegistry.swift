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
}
