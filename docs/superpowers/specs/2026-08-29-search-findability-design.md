# gimme Search Findability — Design ("what is this, and who has it")

**Status:** Design approved in brainstorming 2026-08-29; spec pending review
**Date:** 2026-08-29
**Builds on:** v2 orchestrator design (2026-08-07), fetch performance
(2026-08-27) — search results ride the existing per-manager search APIs,
caches, and concurrency.

---

## 1. Purpose

gimme can already search every manager (`Gimme.search`, the GUI Browse
section, `gimme search [--all]`), but the experience doesn't answer the two
questions a user actually has:

1. **What is this thing?** The GUI result list shows manager badge + name +
   version only — `SearchHit.summary` (the description every adapter already
   populates) is never displayed. The CLI prints it; the GUI hides it.
2. **Who has it?** Both surfaces default to the *first priority manager only*
   (`all: false`). Typing `jq` in Browse shows nothing but Homebrew unless
   the user knows to flip "All managers". And nothing ranks an exact name
   match ("I want the command `jq`") above substring noise.

This spec covers the search overhaul only. Query-less browsing (curated
Explore collections) was split out during brainstorming and is a future spec.

Decisions (2026-08-29):

| # | Decision | Choice |
|---|---|---|
| 1 | CLI shape for find-by-command | **New `gimme find` verb** (user-picked) — all managers, exact matches ranked first. `gimme search` keeps its scoped default. |
| 2 | GUI default search scope | **Always all managers** (recommended option taken — question posed, unanswered). Toggle removed; a manager filter narrows. |
| 3 | Ranking location | **Pure `SearchRanking` helper in GimmeCore** (recommended) — shared by CLI and GUI, unit-testable. Presentation layers never sort. |

Alternatives considered: flipping `gimme search`'s default to all managers
(rejected — v2.4.0 already spent the behavior-change budget on bare
`upgrade`; a distinct verb is discoverable without breaking muscle memory);
keeping the GUI toggle at default-on (weaker version of always-all — the
unified-namespace pitch argues every search should be cross-manager);
ranking inside adapters (rejected — managers don't see each other's
results); ranking duplicated in each client (rejected — drift, untestable).

## 2. Engine — `SearchRanking` (GimmeCore)

New pure helper, no I/O, no state:

```swift
public enum SearchRanking {
    /// Rank hits for a query: exact name match first, then prefix, then
    /// substring (name before description). Ties break by manager priority
    /// (config.priority order, unknown managers last), then by name.
    /// An empty (or whitespace-only) query returns hits unmodified.
    public static func rank(_ hits: [SearchHit],
                            query: String,
                            managerPriority: [String]) -> [SearchHit]
}
```

- Tiers (case-insensitive, query trimmed):
  1. name == query
  2. name hasPrefix query
  3. name contains query
  4. summary contains query
- Stable secondary sort: manager priority index (position in
  `config.priority`; managers absent from the list sort last, in arrival
  order), then name ascending.
- **No cross-manager dedupe.** Seeing `jq` under homebrew, cargo, and npm is
  the answer to "who has it".
- `Gimme.search` is unchanged — `find` is `search(all: true)` + `rank`.
  Callers pass `gimme.config.priority`.

## 3. CLI — `gimme find`

- `gimme find <query>` — searches **all** capable managers (the `all: true`
  path that `search --all` uses today), applies `SearchRanking` with
  `config.priority`, prints the same line format as `search`:
  `[manager] name version — summary`. `--json` emits the same `SearchHit`
  array in ranked order. Missing query → usage error, same style as
  `search`. `--refresh` passes through; unknown `--flags` already hard-error
  (CLIArgs).
- `gimme search` is untouched: scoped default, `--all` opt-in, same output.
- Top-level usage text gains a `find` line (`gimme find <query>   search
  every manager, best match first`).

## 4. GUI — Browse

- **Scope:** the "All managers" toggle is removed. `runSearch` always calls
  `gimme.search(all: true, …)`, then applies `SearchRanking` before
  publishing `searchResults`. `store.searchAll` is deleted; a new
  `@Published var browseManagerFilter: ManagerID?` (nil = all) narrows the
  *displayed* results client-side — filtering never triggers a refetch.
- **Filter picker:** a compact `Picker` next to the search field —
  "All managers" plus one entry per manager that is search-capable *and*
  currently installed/available (`capabilities.contains(.search)` crossed
  with the launch `statuses` availability, so no dead ends are offered).
- **Result rows, two lines:**
  - Line 1: `ManagerBadge`, name (medium weight), version (secondary), and —
    when `(manager, name)` matches an entry in the already-loaded
    `store.installed` — a small "✓ installed" check. No extra queries; the
    installed list is loaded at launch.
  - Line 2: `summary`, secondary color, `lineLimit(1)`.
- **Ranking in the list:** exact matches pin to the top, so typing `jq`
  answers "which managers provide jq" at a glance.
- **Empty state:** keeps the current placeholder plus three tappable example
  chips (`jq`, `http server`, `terminal file manager`) that fill the field
  and run the search. Search still fires on Submit / button only — no
  per-keystroke network calls.
- **Detail flow unchanged:** tapping a row still opens `DetailSheet`.
- Navigation policy: Browse is a sidebar section (rule 3, no back button);
  the detail sheet keeps its ✕/Esc affordances (rule 1) — no changes needed.

## 5. Docs

- `man/gimme.1`: `find` verb in the synopsis and verbs list.
- tldr page: `gimme find` example.
- docs-site CLI reference: `find` entry; the Browse/install page blurb
  mentions cross-manager search with ranked exact matches.

## 6. Testing

- `SearchRankingTests` (GimmeCore, TDD): tier ordering; case-insensitivity;
  trimmed-query handling; tiebreak by manager priority then name; empty
  query passthrough; empty-hit-list passthrough.
- `CLIArgsTests`: `find` parses positional query, `--json`, `--refresh`;
  unknown flag hard-error (covered generically, asserted for `find`).
- Engine `search` is untouched — existing tests stand unchanged.
- GUI (v1 no-automated-tests decision): build + launch, search `jq` —
  verify brew `jq` ranks first, summaries render, ✓-installed appears on an
  installed package, the manager filter narrows without refetching, and the
  example chips run a search.

## 7. Out of scope / future

- **Explore (query-less browsing):** curated starter collections as a repo
  data file + Explore section — separate spec, carries a content-maintenance
  cost the rest of gimme avoids.
- **Per-adapter matching upgrades:** some managers match names only
  (RubyGems, pipx); brew/npm/cargo are already keyword-aware. Leveling the
  laggards is future work, not this spec.
- **Semantic / "tool for job X" search and popularity data:** no source of
  truth a pure orchestrator can honestly query; not pursued.
