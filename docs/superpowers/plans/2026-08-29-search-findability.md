# Search Findability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the search findability spec — `docs/superpowers/specs/2026-08-29-search-findability-design.md`: a shared exact-match-first ranking, a `gimme find` CLI verb, and a Browse overhaul (always-all search, descriptions, installed checks).

**Architecture:** One pure ranking helper in GimmeCore (`SearchRanking.rank`), consumed by both the new CLI verb and the GUI Browse; `Gimme.search` itself is untouched. Browse drops its scope toggle (always all managers) and gains a client-side manager filter.

**Tech Stack:** Swift 5.9 / SwiftPM, macOS 13 floor, no external dependencies, XCTest.

## Global Constraints

- English only; Conventional Commits; no AI attribution in commits.
- TDD for all GimmeCore changes; GUI has no automated tests (v1 decision) — verify by building `app/Gimme.app` and launching.
- Never run mutating verbs against the real machine; `search`/`find` smoke tests are read-only but must run from a **release** build (`swift build -c release`) — Little Snitch blocks `.build/debug` network.
- Test isolation is enforced: tests never construct real adapters (`defaultRegistry`, `URLSessionHTTPClient` are scanned for); use stub managers.
- Live smoke of the GUI must not click "Update Now" anywhere in the app (it performs a real self-update).

### Task 0: Land the pending audit fixes

The working tree carries three verified fixes from the 2026-08-29 audit (uncommitted). Later tasks touch the same files (`GimmeApp.swift`, `install.md`), so they must land first or per-task commits won't be atomic.

**Files:**
- Modify (already edited, uncommitted): `Sources/GimmeUI/GimmeApp.swift`, `Sources/GimmeUI/Views/UpdateSheet.swift`, `Sources/GimmeUI/UpdateNotifier.swift`, `docs-site/docs/install.md`

**Interfaces:**
- Produces: `GimmeStore.selfUpdateError: String?` and `UpdateNotifier.isAnyWindowOnScreen: Bool` (used by nothing in this plan, but they must be committed before Task 3 edits the same file).

- [ ] **Step 1: Verify the tree state**

Run: `git status --short && swift test 2>&1 | tail -3`
Expected: modified `Sources/GimmeUI/GimmeApp.swift`, `Sources/GimmeUI/UpdateNotifier.swift`, `Sources/GimmeUI/Views/UpdateSheet.swift`, `docs-site/docs/install.md`; `Executed 291 tests, with 0 failures`.

- [ ] **Step 2: Commit the three fixes separately**

```bash
git add Sources/GimmeUI/GimmeApp.swift Sources/GimmeUI/Views/UpdateSheet.swift
git commit -m "fix: show self-update failures inline in the What's New sheet"
git add Sources/GimmeUI/UpdateNotifier.swift Sources/GimmeUI/GimmeApp.swift
git commit -m "fix: gate the update-available notification on window visibility, not isActive"
git add docs-site/docs/install.md
git commit -m "docs: uninstall note for v1-era ~/.gimme installs"
```

Note: the first two commits each carry part of `GimmeApp.swift` — that is expected; the sheet-error routing and the notification gate are separable hunks and both are already verified. If `git add` refuses (already-staged hunks), commit the whole `GimmeApp.swift` change in the first commit and drop the second `git add` line.

---

### Task 1: `SearchRanking` (GimmeCore, TDD)

**Files:**
- Create: `Sources/GimmeCore/SearchRanking.swift`
- Create: `Tests/GimmeTests/SearchRankingTests.swift`

**Interfaces:**
- Consumes: `SearchHit` (`name: String`, `manager: ManagerID`, `summary: String`, `latestVersion: String` — `PackageManager.swift:106`).
- Produces: `SearchRanking.rank(_ hits: [SearchHit], query: String, managerPriority: [String]) -> [SearchHit]` — exact name match > name prefix > name substring > summary substring, ties by index in `managerPriority` (unknown managers last), then by name ascending. Empty/whitespace query returns input unchanged.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GimmeTests/SearchRankingTests.swift`:

```swift
import XCTest
@testable import GimmeCore

final class SearchRankingTests: XCTestCase {
    private func hit(_ name: String, _ manager: ManagerID,
                     summary: String = "", version: String = "1.0") -> SearchHit {
        SearchHit(name: name, manager: manager, summary: summary, latestVersion: version)
    }

    func testExactMatchBeatsSubstring() {
        let ranked = SearchRanking.rank(
            [hit("jqlang", .cargo, summary: "jq bindings"),
             hit("jq", .homebrew, summary: "lightweight and flexible JSON processor")],
            query: "jq", managerPriority: ["cargo", "homebrew"])
        XCTAssertEqual(ranked.first?.name, "jq")
    }

    func testPrefixBeatsSubstring() {
        let ranked = SearchRanking.rank(
            [hit("jqlang", .cargo), hit("jqp", .homebrew)],
            query: "jq", managerPriority: ["cargo", "homebrew"])
        XCTAssertEqual(ranked.first?.name, "jqp")
    }

    func testNameMatchBeatsDescriptionMatch() {
        let ranked = SearchRanking.rank(
            [hit("prettier", .npm, summary: "opinionated code formatter"),
             hit("formatjson", .homebrew)],
            query: "format", managerPriority: ["npm", "homebrew"])
        XCTAssertEqual(ranked.first?.name, "formatjson")
    }

    func testQueryIsCaseInsensitiveAndTrimmed() {
        let ranked = SearchRanking.rank(
            [hit("jqtest", .homebrew), hit("jq", .cargo)],
            query: "  JQ ", managerPriority: ["homebrew", "cargo"])
        XCTAssertEqual(ranked.first?.name, "jq")
    }

    func testTiebreakByManagerPriority() {
        let hits = [hit("jq", .cargo), hit("jq", .homebrew)]
        XCTAssertEqual(
            SearchRanking.rank(hits, query: "jq", managerPriority: ["homebrew", "cargo"]).first?.manager,
            .homebrew)
        XCTAssertEqual(
            SearchRanking.rank(hits, query: "jq", managerPriority: ["cargo", "homebrew"]).first?.manager,
            .cargo)
    }

    func testUnknownManagerSortsLast() {
        let ranked = SearchRanking.rank(
            [hit("jq", .deno), hit("jq", .homebrew)],
            query: "jq", managerPriority: ["homebrew"])
        XCTAssertEqual(ranked.first?.manager, .homebrew)
    }

    func testNameTiebreakWhenPriorityEqual() {
        let ranked = SearchRanking.rank(
            [hit("zq", .deno), hit("aq", .ubi)],
            query: "q", managerPriority: ["homebrew"])
        XCTAssertEqual(ranked.first?.name, "aq")
    }

    func testEmptyQueryReturnsInputUnchanged() {
        let hits = [hit("jqlang", .cargo), hit("jq", .homebrew)]
        XCTAssertEqual(SearchRanking.rank(hits, query: "", managerPriority: ["homebrew"]), hits)
        XCTAssertEqual(SearchRanking.rank(hits, query: "   ", managerPriority: ["homebrew"]), hits)
    }

    func testEmptyHits() {
        XCTAssertEqual(SearchRanking.rank([], query: "jq", managerPriority: ["homebrew"]), [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SearchRankingTests 2>&1 | tail -5`
Expected: FAIL — "cannot find 'SearchRanking' in scope".

- [ ] **Step 3: Implement**

Create `Sources/GimmeCore/SearchRanking.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SearchRankingTests 2>&1 | tail -3`
Expected: PASS — `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Full suite + commit**

Run: `swift test 2>&1 | tail -3`
Expected: PASS (300 tests: 291 + 9 new).

```bash
git add Sources/GimmeCore/SearchRanking.swift Tests/GimmeTests/SearchRankingTests.swift
git commit -m "feat: SearchRanking — exact-match-first ranking for cross-manager hits"
```

---

### Task 2: `gimme find` (CLI)

**Files:**
- Modify: `Sources/gimme/main.swift` (verb dispatch after `case "search"` at line ~143, and `printHelp()` at line ~294)
- Modify: `Tests/GimmeTests/CLIArgsTests.swift` (append two tests)

**Interfaces:**
- Consumes: `SearchRanking.rank` (Task 1), `Gimme.search(query:all:refresh:)`, `Gimme.config.priority: [String]`, `CLIArgs` (`positional`, `json`, `refresh`).
- Produces: `gimme find <query>` — all managers, ranked; supports `--json`, `--refresh`; unknown `--flags` hard-error via existing CLIArgs rules.

- [ ] **Step 1: Write the argument-parsing tests**

Append to `Tests/GimmeTests/CLIArgsTests.swift` (inside the existing XCTestCase class):

```swift
    func testParseFindVerb() throws {
        let p = try CLIArgs.parse(["find", "jq", "--json"])
        XCTAssertEqual(p.verb, "find")
        XCTAssertEqual(p.positional, ["jq"])
        XCTAssertTrue(p.json)
        XCTAssertFalse(p.all)  // find is all-managers by definition, not via --all
    }

    func testFindRejectsUnknownFlag() {
        XCTAssertThrowsError(try CLIArgs.parse(["find", "jq", "--bogus"]))
    }
```

- [ ] **Step 2: Run tests to verify the state**

Run: `swift test --filter CLIArgsTests 2>&1 | tail -3`
Expected: PASS — parsing is generic, so these pass immediately (regression guard for the flag rules `find` relies on; the new dispatch itself is exercised in Step 5's live smoke).

- [ ] **Step 3: Add the verb dispatch**

In `Sources/gimme/main.swift`, directly after the `case "search":` block, add:

```swift
        case "find":
            guard let q = p.positional.first else { throw GimmeError.usage("usage: gimme find <query>") }
            let hits = try await gimme.search(query: q, all: true, refresh: p.refresh)
            let ranked = SearchRanking.rank(hits, query: q, managerPriority: gimme.config.priority)
            if p.json { print((try? JSONEncoder().encode(ranked)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]") }
            else { ranked.forEach { print("[\($0.manager.rawValue)] \($0.name) \($0.latestVersion) — \($0.summary)") } }
```

- [ ] **Step 4: Add the help line**

In `printHelp()`, directly under the `gimme search <query> [--all]` line, add:

```
          gimme find <query>                 (every manager, best match first)
```

- [ ] **Step 5: Build release + live smoke (read-only)**

Run:
```bash
swift build -c release 2>&1 | tail -1
.build/release/gimme find jq | head -5
.build/release/gimme search jq | head -3
```
Expected: build completes; `find` prints hits from multiple managers with a line `… jq …` from homebrew (or another exact match) **first**; `search` output is unchanged in shape. Both are read-only network/subprocess calls from a release binary (Little Snitch allows `.build/release`).

- [ ] **Step 6: Full suite + commit**

Run: `swift test 2>&1 | tail -3` — Expected: PASS.

```bash
git add Sources/gimme/main.swift Tests/GimmeTests/CLIArgsTests.swift
git commit -m "feat: gimme find — ranked search across every manager"
```

---

### Task 3: Browse overhaul (GUI)

**Files:**
- Modify: `Sources/GimmeUI/GimmeApp.swift` — `GimmeStore`: delete `@Published var searchAll` (line ~126), add `browseManagerFilter`, `searchableManagers`, `filteredSearchResults`, `installedPackageIDs`; rewrite `runSearch` (~line 429).
- Modify: `Sources/GimmeUI/Views/BrowseView.swift` — full body rewrite.

**Interfaces:**
- Consumes: `SearchRanking.rank` (Task 1); `Gimme.ManagerStatus` (`id`, `displayName`, `available`, `enabled`); `SearchHit.id == "\(manager.rawValue):\(name)"` and the same `id` format on `InstalledPackage`; `gimme.registryLookup(_:) -> (any PackageManager)?` with `.capabilities.contains(.search)`.
- Produces: `GimmeStore.browseManagerFilter: ManagerID?`, `searchableManagers: [Gimme.ManagerStatus]`, `filteredSearchResults: [SearchHit]`, `installedPackageIDs: Set<String>`, and `runSearch(_ query: String)` now always all-managers + ranked.

- [ ] **Step 1: Update the store**

In `GimmeApp.swift`, delete the line `@Published var searchAll = false` and its trailing comment (if any), then add next to `searchResults`:

```swift
    /// Browse manager filter (nil = all). Narrows displayed results only —
    /// filtering never refetches.
    @Published var browseManagerFilter: ManagerID?
```

Rewrite `runSearch`:

```swift
    func runSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        lastQuery = query
        do {
            let hits = try await gimme.search(query: query, all: true, refresh: false)
            searchResults = SearchRanking.rank(hits, query: query, managerPriority: config.priority)
        } catch { showError(error) }
    }
```

Add these three computed properties near `runSearch`:

```swift
    /// Managers that can answer a Browse search right now (search-capable,
    /// enabled, installed) — the filter picker's options.
    var searchableManagers: [Gimme.ManagerStatus] {
        managerStatuses.filter { s in
            s.available && s.enabled
                && (gimme.registryLookup(s.id)?.capabilities.contains(.search) ?? false)
        }
    }

    /// Browse results narrowed by the manager filter (client-side only).
    var filteredSearchResults: [SearchHit] {
        guard let filter = browseManagerFilter else { return searchResults }
        return searchResults.filter { $0.manager == filter }
    }

    /// "manager:name" ids of installed packages, for the ✓ on result rows.
    var installedPackageIDs: Set<String> { Set(installed.map { $0.id }) }
```

Then sweep for stragglers:

Run: `grep -rn "searchAll" Sources/`
Expected: no hits (the toggle and the store property were the only users).

- [ ] **Step 2: Rewrite BrowseView**

Replace the entire content of `Sources/GimmeUI/Views/BrowseView.swift` with:

```swift
import SwiftUI
import GimmeCore

struct BrowseView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var query = ""
    @State private var selected: SearchHit?
    /// Tappable empty-state examples — each fills the field and searches.
    private let examples = ["jq", "http server", "terminal file manager"]

    var body: some View {
        VStack {
            HStack {
                TextField("Search packages…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.runSearch(query) } }
                Picker("Manager", selection: $store.browseManagerFilter) {
                    Text("All managers").tag(ManagerID?.none)
                    ForEach(store.searchableManagers, id: \.id) { s in
                        Text(s.displayName).tag(ManagerID?.some(s.id))
                    }
                }
                .frame(width: 170)
                Button {
                    Task { await store.runSearch(query) }
                } label: {
                    if store.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Search")
                    }
                }
                .disabled(store.isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            let shown = store.filteredSearchResults
            if store.isSearching && shown.isEmpty {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                VStack(spacing: 12) {
                    Text(store.searchResults.isEmpty
                         ? "Search packages across every manager — try:"
                         : "No results from this manager.")
                        .foregroundStyle(.secondary)
                    if store.searchResults.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(examples, id: \.self) { example in
                                Button(example) {
                                    query = example
                                    Task { await store.runSearch(example) }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            ManagerBadge(manager: hit.manager)
                            Text(hit.name).fontWeight(.medium)
                            Text(hit.latestVersion).foregroundStyle(.secondary)
                            if store.installedPackageIDs.contains(hit.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .help("Installed")
                            }
                        }
                        if !hit.summary.isEmpty {
                            Text(hit.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = hit }
                }
            }
        }
        .navigationTitle("Browse")
        .sheet(item: $selected) { hit in DetailSheet(package: .searchable(hit)) }
    }
}
```

- [ ] **Step 3: Build + sweep**

Run: `swift build 2>&1 | tail -2`
Expected: `Build complete!` — a compile error here means a stale `searchAll` reference (check `PreferencesView`, `UpdatesView`).

---

### Task 4: Docs

**Files:**
- Modify: `man/gimme.1` (verbs list — after the `search` entry)
- Modify: `tldr-pages/pages/common/gimme.md` (after the `gimme search` example)
- Modify: `docs-site/docs/reference/cli.md` (after the `search` entry)

**Interfaces:** none — documentation of the Task 2 verb.

- [ ] **Step 1: Man page**

In `man/gimme.1`, locate the `search` entry (a `.TP` block). Immediately after it, add:

```roff
.TP
.B find <query>
Search every capable manager at once, exact name matches ranked first.
```

- [ ] **Step 2: tldr page**

In `tldr-pages/pages/common/gimme.md`, after the `gimme search {{query}}` example block, add:

```
- Search every manager with the best match first:

`gimme find {{query}}`
```

- [ ] **Step 3: Site CLI reference**

In `docs-site/docs/reference/cli.md`, locate the `search` entry and add a matching `find` entry directly after it:

```markdown
### `gimme find <query>`

Searches every capable manager at once (no `--all` needed) and ranks exact
name matches first — the fastest answer to "which managers provide `jq`?".
Accepts `--json` and `--refresh`.
```

Then, in any site page that presents `gimme search` as the way to look up packages (`quickstart.md`, `index.md` — grep to find them), append one line right after the search mention:

```markdown
Prefer a cross-manager lookup with the best match first? `gimme find <query>`
searches every manager at once.
```

Then lint the man page if mandoc is available:

Run: `mandoc -T lint man/gimme.1 2>&1 | head -5`
Expected: no new warnings versus before the edit.

- [ ] **Step 4: Commit**

```bash
git add man/gimme.1 tldr-pages/pages/common/gimme.md docs-site/docs/reference/cli.md
git commit -m "docs: gimme find in man page, tldr, and site CLI reference"
```

(Any quickstart/index edit lands in the same commit — add those files to the `git add` list.)

---

### Task 5: End-to-end verification

**Files:** none (verification only; commit fixups if the GUI check surfaces bugs).

- [ ] **Step 1: Full test suite**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, `0 failures`.

- [ ] **Step 2: Build the app bundle and launch it**

Run: `sh app/build-app.sh 2>&1 | tail -1` then launch the dev bundle binary directly (`app/Gimme.app/Contents/MacOS/GimmeUI`) — do NOT `open` it (the production app may be running; same bundle id would just activate that copy). Expected: app launches and stays alive.

- [ ] **Step 3: Exercise Browse via accessibility**

In the running dev instance: switch to Browse, tap the example chip `jq`. Verify: results include multiple managers, an exact `jq` match ranks first, rows show one-line summaries, an installed package shows the ✓, and the manager picker narrows the list without a spinner (no refetch). Quit the dev instance when done (never click "Update Now").

- [ ] **Step 4: Report**

State the real `swift test` numbers and what the GUI check showed.
