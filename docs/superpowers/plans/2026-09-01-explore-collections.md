# Explore — Curated Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Explore spec — `docs/superpowers/specs/2026-09-01-explore-collections-design.md`: a curated "Explore" sidebar section (5 collections × 8–10 tools) with push drill-down and the shared install flow.

**Architecture:** Pure-GUI feature. Static collection data in a new GimmeUI file; one new `ExploreView` (cards grid → `NavigationStack` push → tool rows); `SidebarSection` + ContentView detail switch + ⌘R routing gain the new section. Zero GimmeCore changes.

**Tech Stack:** SwiftUI (NavigationStack — macOS 13 floor), no new dependencies.

## Global Constraints

- English only; Conventional Commits; no AI attribution.
- GUI has no automated tests — verify by building `app/GimmeApp`'s bundle (`sh app/build-app.sh`) and launching the binary directly (never `open`, never click "Update Now").
- All 42 curated names already validated against `brew info --json=v2` (2026-09-01; `delta` → `git-delta`); do not rename entries without re-validating.
- GimmeCore must remain untouched; `swift test` must stay at 302/302.

### Task 1: Data + ExploreView + wiring

**Files:**
- Create: `Sources/GimmeUI/ExploreCollections.swift`
- Create: `Sources/GimmeUI/Views/ExploreView.swift`
- Modify: `Sources/GimmeUI/ContentView.swift` (`SidebarSection` enum ~lines 3–23, detail switch ~line 42)
- Modify: `Sources/GimmeUI/GimmeApp.swift` (`refreshCurrentSection` ~line 368)

**Interfaces:**
- Consumes: `store.installedPackageIDs: Set<String>` and `SearchHit.id == "manager:name"` (shipped 2026-08-29); `DetailSheet(package: .searchable(hit))`; `ManagerBadge`; `GimmeApp.accent`.
- Produces: `SidebarSection.explore`; `ExploreCollections.all: [ExploreCollection]`; `ExploreTool.searchHit: SearchHit`.

- [ ] **Step 1: Create the data file**

Create `Sources/GimmeUI/ExploreCollections.swift`:

```swift
import Foundation
import GimmeCore

/// Curated starter collections for Explore (spec: 2026-09-01-explore-
/// collections-design). Compile-time data — adding a tool is a one-line diff.
/// Every name is validated against `brew info --json=v2` before it lands
/// here (2026-09-01); a stale entry fails gracefully in DetailSheet.
struct ExploreTool: Identifiable, Hashable {
    let name: String
    let summary: String
    let manager: ManagerID
    var id: String { "\(manager.rawValue):\(name)" }
    /// Bridge into the shared DetailSheet install flow.
    var searchHit: SearchHit {
        SearchHit(name: name, manager: manager, summary: summary, latestVersion: "")
    }
}

struct ExploreCollection: Identifiable, Hashable {
    let name: String
    let blurb: String
    let icon: String        // SF Symbol on the card
    let tools: [ExploreTool]
    var id: String { name }
}

enum ExploreCollections {
    static let all: [ExploreCollection] = [
        ExploreCollection(name: "CLI Essentials", blurb: "The terminal upgrades nearly everyone keeps.", icon: "terminal", tools: [
            ExploreTool(name: "fzf", summary: "Fuzzy finder for shell history, files, and anything", manager: .homebrew),
            ExploreTool(name: "ripgrep", summary: "Blazing-fast search that respects .gitignore", manager: .homebrew),
            ExploreTool(name: "bat", summary: "cat with syntax highlighting and a git gutter", manager: .homebrew),
            ExploreTool(name: "fd", summary: "Simple, fast alternative to find", manager: .homebrew),
            ExploreTool(name: "eza", summary: "Modern ls replacement with colors and icons", manager: .homebrew),
            ExploreTool(name: "zoxide", summary: "Smarter cd that learns your habits", manager: .homebrew),
            ExploreTool(name: "htop", summary: "Interactive process viewer", manager: .homebrew),
            ExploreTool(name: "dust", summary: "Disk usage analyzer with a treemap view", manager: .homebrew),
            ExploreTool(name: "starship", summary: "Fast, customizable prompt for any shell", manager: .homebrew),
            ExploreTool(name: "tldr", summary: "Community cheat sheets for every command", manager: .homebrew),
        ]),
        ExploreCollection(name: "JSON & Data", blurb: "Query, reshape, and move data from the shell.", icon: "curlybraces", tools: [
            ExploreTool(name: "jq", summary: "The classic command-line JSON processor", manager: .homebrew),
            ExploreTool(name: "yq", summary: "jq-style queries for YAML, XML, and TOML", manager: .homebrew),
            ExploreTool(name: "fx", summary: "Interactive JSON viewer and terminal debugger", manager: .homebrew),
            ExploreTool(name: "duckdb", summary: "In-process SQL database that queries files", manager: .homebrew),
            ExploreTool(name: "xh", summary: "Friendly, fast HTTPie-style requests in one binary", manager: .homebrew),
            ExploreTool(name: "httpie", summary: "Human-friendly HTTP client for API testing", manager: .homebrew),
            ExploreTool(name: "aria2", summary: "Resumable, parallel multi-protocol downloads", manager: .homebrew),
            ExploreTool(name: "visidata", summary: "Spreadsheet-like terminal UI for tabular data", manager: .homebrew),
        ]),
        ExploreCollection(name: "Git & GitHub", blurb: "See more, type less, diff smarter.", icon: "arrow.triangle.branch", tools: [
            ExploreTool(name: "gh", summary: "GitHub CLI — PRs, issues, and releases", manager: .homebrew),
            ExploreTool(name: "lazygit", summary: "Terminal UI for git you can actually learn", manager: .homebrew),
            ExploreTool(name: "git-delta", summary: "Syntax-highlighting pager for git diffs", manager: .homebrew),
            ExploreTool(name: "tig", summary: "Text-mode interface for git history", manager: .homebrew),
            ExploreTool(name: "difftastic", summary: "Structural diff that understands syntax", manager: .homebrew),
            ExploreTool(name: "git-lfs", summary: "Large file support for git repos", manager: .homebrew),
            ExploreTool(name: "glab", summary: "GitLab CLI — the gh equivalent for GitLab", manager: .homebrew),
            ExploreTool(name: "gitui", summary: "Blazing-fast terminal UI for git", manager: .homebrew),
        ]),
        ExploreCollection(name: "GUI Apps", blurb: "Hand-picked Mac apps, installed by brew.", icon: "macwindow", tools: [
            ExploreTool(name: "rectangle", summary: "Window snapping and keyboard tiling (GUI app)", manager: .homebrew),
            ExploreTool(name: "raycast", summary: "Launcher and command palette (GUI app)", manager: .homebrew),
            ExploreTool(name: "iterm2", summary: "The macOS terminal, supercharged (GUI app)", manager: .homebrew),
            ExploreTool(name: "stats", summary: "Menu-bar system monitor (GUI app)", manager: .homebrew),
            ExploreTool(name: "appcleaner", summary: "Thorough app uninstaller (GUI app)", manager: .homebrew),
            ExploreTool(name: "keka", summary: "Archive extractor and compressor (GUI app)", manager: .homebrew),
            ExploreTool(name: "maccy", summary: "Clipboard history manager (GUI app)", manager: .homebrew),
            ExploreTool(name: "meetingbar", summary: "Menu-bar calendar for your next meeting (GUI app)", manager: .homebrew),
        ]),
        ExploreCollection(name: "Documents & Media", blurb: "Convert, compress, and transcode anything.", icon: "doc.richtext", tools: [
            ExploreTool(name: "ffmpeg", summary: "Convert, stream, and mangle audio/video", manager: .homebrew),
            ExploreTool(name: "imagemagick", summary: "Create, edit, and convert images from the CLI", manager: .homebrew),
            ExploreTool(name: "pandoc", summary: "Convert documents between markup formats", manager: .homebrew),
            ExploreTool(name: "yt-dlp", summary: "Download video and audio from the web", manager: .homebrew),
            ExploreTool(name: "poppler", summary: "PDF utilities — pdftotext, pdftoppm, and friends", manager: .homebrew),
            ExploreTool(name: "sevenzip", summary: "7-Zip archiver with high compression ratios", manager: .homebrew),
            ExploreTool(name: "mkvtoolnix", summary: "Inspect and remux Matroska files", manager: .homebrew),
            ExploreTool(name: "handbrake", summary: "Open-source video transcoder (GUI app)", manager: .homebrew),
        ]),
    ]
}
```

- [ ] **Step 2: Create ExploreView**

Create `Sources/GimmeUI/Views/ExploreView.swift`:

```swift
import SwiftUI
import GimmeCore

/// Query-less discovery: curated collections of worth-installing tools.
/// Cards grid → push into a collection (nav policy §2, toolbar Back);
/// tapping a tool opens the shared DetailSheet (§1). Curated order stands —
/// no ranking.
struct ExploreView: View {
    @State private var selected: SearchHit?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
                          spacing: 12) {
                    ForEach(ExploreCollections.all) { collection in
                        NavigationLink(value: collection) {
                            ExploreCard(collection: collection)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Explore")
            .navigationDestination(for: ExploreCollection.self) { collection in
                CollectionView(collection: collection)
            }
        }
        .sheet(item: $selected) { hit in DetailSheet(package: .searchable(hit)) }
    }
}

private struct ExploreCard: View {
    let collection: ExploreCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: collection.icon)
                .font(.title)
                .foregroundStyle(GimmeApp.accent)
            Text(collection.name).fontWeight(.semibold)
            Text(collection.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            Text("\(collection.tools.count) tools")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CollectionView: View {
    @EnvironmentObject var store: GimmeStore
    let collection: ExploreCollection
    @State private var selected: SearchHit?

    var body: some View {
        List(collection.tools) { tool in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    ManagerBadge(manager: tool.manager)
                    Text(tool.name).fontWeight(.medium)
                    if store.installedPackageIDs.contains(tool.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("Installed")
                    }
                }
                Text(tool.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { selected = tool.searchHit }
        }
        .navigationTitle(collection.name)
        .sheet(item: $selected) { hit in DetailSheet(package: .searchable(hit)) }
    }
}
```

Note: the sheet must be attached *inside* the pushed `CollectionView` (a sheet attached to the root `NavigationStack` works too, but per-view attachment keeps state local and avoids the macOS 26 environment-object ordering traps — `DetailSheet` receives its store via the app-level environment chain, which survived the 2026-08-27 sheet fix for ContentView-hosted sheets).

- [ ] **Step 3: Wire the sidebar**

In `Sources/GimmeUI/ContentView.swift`, add the enum case between `.browse` and `.managers` (declaration order drives sidebar order):

```swift
    case browse = "Browse"
    case explore = "Explore"
    case managers = "Package Managers"
```

add to `icon`:

```swift
        case .browse:        return "magnifyingglass"
        case .explore:       return "sparkles"
        case .managers:      return "shippingbox"
```

and in the detail switch:

```swift
                case .browse:        BrowseView()
                case .explore:       ExploreView()
                case .managers:      PackageManagersView()
```

In `Sources/GimmeUI/GimmeApp.swift` (`refreshCurrentSection`), route ⌘R to the no-op:

```swift
        case .explore, .preferences, .activity: break
```

- [ ] **Step 4: Build + sweep**

Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep "Executed .* tests" | tail -1`
Expected: `Build complete!`; `Executed 302 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/GimmeUI/ExploreCollections.swift Sources/GimmeUI/Views/ExploreView.swift Sources/GimmeUI/ContentView.swift Sources/GimmeUI/GimmeApp.swift
git commit -m "feat: Explore section — curated collections with one-tap install"
```

---

### Task 2: GUI verification

**Files:** none (verification only; commit fixups if the drive finds bugs).

- [ ] **Step 1: Build + launch the dev bundle**

Run: `sh app/build-app.sh 2>&1 | tail -1`, then execute `app/Gimme.app/Contents/MacOS/GimmeUI` directly (never `open` — production may be running). Confirm alive after 5 s.

- [ ] **Step 2: Drive the UI**

With the app frontmost (activate if needed): sidebar shows **Explore** between Browse and Package Managers. Click Explore (cliclick at the row's coordinates from AX bounds). Verify: five cards with icons/blurbs/tool counts; click **CLI Essentials** → pushes with a toolbar **Back**; rows show summaries and a ✓ on any installed tool (e.g. `jq` in JSON & Data); click a tool → DetailSheet with ✕/Esc; Esc closes; Back returns to the grid; switch sidebar sections and back — no state weirdness. Quit the dev instance (SIGTERM), confirm production untouched.

- [ ] **Step 3: Report**

State real test numbers and what the drive showed; note anything that needed fixing.
