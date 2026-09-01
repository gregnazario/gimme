# gimme Explore — Curated Collections (query-less browsing) — Design

**Status:** Design approved in brainstorming 2026-09-01; built same session
**Date:** 2026-09-01
**Builds on:** search findability (2026-08-29) — reuses `installedPackageIDs`,
row layout, and the DetailSheet install flow; v2 orchestrator design
(2026-08-07) — gimme stays a pure orchestrator, curation is data in this
repo, not a fetched content pipeline.

---

## 1. Purpose

Search answers "find me X" — but only when the user already has an X in
mind. The second half of the findability work (decomposed 2026-08-29,
deferred then) is query-less browsing: a newcomer opens gimme and asks
"what's worth installing?" This adds one curated **Explore** sidebar section
with a handful of themed collections and one-tap access to the existing
install flow.

Decisions (2026-09-01; presented with recommended defaults, Greg approved):

| # | Decision | Choice |
|---|---|---|
| 1 | Data home | **Static Swift file in GimmeUI** (`ExploreCollections.swift`) — compile-time, no bundle-resource or network plumbing; adding a tool is a one-line diff reviewed like code. |
| 2 | Drill-down navigation | **`NavigationStack` push inside the detail column** with a toolbar Back button (nav policy §2), sheet only for per-package detail (§1). |
| 3 | Entry shape | Every tool is `(manager: .homebrew, name, summary)` — install routes deterministically; all 42 names validated against `brew info --json=v2` at implementation time (delta → `git-delta`; GUI Apps are casks, routed by the same `brew install <name>`). |
| 4 | Collections | Five themed sets, 8–10 tools each: CLI Essentials (10), JSON & Data (8), Git & GitHub (8), GUI Apps (8), Documents & Media (8). |

Alternatives considered: bundled JSON (resource-loading plumbing for no
gain over a Swift literal); remote JSON fetched from the repo with a bundled
fallback (content updates without app releases — rejected for now: network
path + fallback complexity in a surface that should always render offline;
revisit if collections churn often); a `gimme explore` CLI verb (YAGNI —
collections are a visual browse surface).

## 2. Data model (GimmeUI/ExploreCollections.swift)

```swift
struct ExploreTool: Identifiable, Hashable {
    let name: String
    let summary: String
    let manager: ManagerID          // always .homebrew today
    var id: String { "\(manager.rawValue):\(name)" }
    var searchHit: SearchHit { SearchHit(name: name, manager: manager,
                                         summary: summary, latestVersion: "") }
}

struct ExploreCollection: Identifiable, Hashable {
    let name: String
    let blurb: String
    let icon: String                // SF Symbol on the card
    let tools: [ExploreTool]
    var id: String { name }
}

enum ExploreCollections {
    static let all: [ExploreCollection] = [ …5 collections… ]
}
```

`searchHit` bridges into the existing `DetailSheet(package: .searchable(hit))`
install flow with zero engine changes. `Hashable` + `Identifiable` satisfy
`navigationDestination(for:)` and list identity.

## 3. UI (GimmeUI/Views/ExploreView.swift, ContentView wiring)

- `SidebarSection` gains `.explore` (icon `sparkles`), inserted between
  `.browse` and `.managers`; ContentView's detail switch adds
  `.explore: ExploreView()`. `refreshCurrentSection` treats it like
  Preferences (⌘R no-op).
- **Cards view** (the section root): `NavigationStack` wrapping a
  `LazyVGrid` (`adaptive`, ~240 pt cards). Each card: SF Symbol icon,
  collection name, blurb, tool count — a `NavigationLink(value:)`.
- **Collection view** (pushed): toolbar Back (automatic), two-line tool
  rows identical to Browse — badge, name, version blank, ✓-installed badge
  from `store.installedPackageIDs`, summary `lineLimit(1)` — tap opens
  `DetailSheet(package: .searchable(hit))` (✕ + Esc per policy §1).
  Curated order stands; no ranking.
- Navigation policy audit: sidebar = §3 (no back), push = §2 (Back),
  detail sheet = §1 (✕ + Esc). No dead ends.

## 4. Content (v1, all `.homebrew`)

- **CLI Essentials** (`terminal`): fzf, ripgrep, bat, fd, eza, zoxide, htop,
  dust, starship, tldr
- **JSON & Data** (`curlybraces`): jq, yq, fx, duckdb, xh, httpie, aria2,
  visidata
- **Git & GitHub** (`arrow.triangle.branch`): gh, lazygit, git-delta, tig,
  difftastic, git-lfs, glab, gitui
- **GUI Apps** (`macwindow`, casks): rectangle, raycast, iterm2, stats,
  appcleaner, keka, maccy, meetingbar — summaries say "(GUI app)"
- **Documents & Media** (`doc.richtext`): ffmpeg, imagemagick, pandoc,
  yt-dlp, poppler, sevenzip, mkvtoolnix, handbrake

One-line descriptions hand-written per tool; all names machine-validated
against brew (2026-09-01). Maintenance: edit the Swift file; a wrong name
fails gracefully (DetailSheet errors on info/install).

## 5. Testing

- GUI has no automated tests (v1 decision): verify by build + launch —
  open Explore, push a collection, confirm ✓ badge on an installed tool,
  open a DetailSheet, Back returns to the grid, sidebar switch is clean.
- No GimmeCore changes at all, so the existing suite must stay green
  untouched (asserted before/after).
- Name validation is the scriptable check (done pre-implementation):
  `brew info --json=v2 <names>` must resolve every entry.

## 6. Out of scope / future

- Remote content refresh (collections updating without an app release) —
  revisit only if content churn makes releases painful.
- User-defined collections; a CLI surface for collections; popularity data
  (never — no honest source for a pure orchestrator).
