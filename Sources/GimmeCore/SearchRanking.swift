import Foundation

/// Ranks cross-manager search hits so exact command-style matches surface
/// first — "who has jq?" should answer at a glance, not bury the exact hit
/// under substring noise. Pure: no I/O, no state. Shared by `gimme find`
/// (CLI) and Browse (GUI); presentation layers never sort search results.
public enum SearchRanking {
    /// Tier order: exact name match, name prefix, name substring, summary
    /// substring. Ties break by position in `managerPriority` (managers not
    /// in the list sort last, in arrival order), then by name. No dedupe —
    /// seeing a name under several managers IS the "who has it" answer.
    /// An empty or whitespace-only query returns the input unmodified.
    public static func rank(_ hits: [SearchHit],
                            query: String,
                            managerPriority: [String]) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return hits }
        func tier(_ h: SearchHit) -> Int {
            let name = h.name.lowercased()
            if name == q { return 0 }
            if name.hasPrefix(q) { return 1 }
            if name.contains(q) { return 2 }
            if h.summary.lowercased().contains(q) { return 3 }
            return 4
        }
        func priorityIndex(_ h: SearchHit) -> Int {
            managerPriority.firstIndex(of: h.manager.rawValue) ?? managerPriority.count
        }
        return hits.sorted {
            let (ta, tb) = (tier($0), tier($1))
            if ta != tb { return ta < tb }
            let (pa, pb) = (priorityIndex($0), priorityIndex($1))
            if pa != pb { return pa < pb }
            return $0.name < $1.name
        }
    }
}
