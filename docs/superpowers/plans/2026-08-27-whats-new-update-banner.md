# What's New + Update Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface release notes ("What's New") in the CLI and GUI self-update flows, and add an always-visible update banner with a direct Update Now button.

**Architecture:** `SelfUpdate.Release` gains an optional `notes` field decoded from the GitHub release `body` (same fetch, no new network call). `release.yml` switches to `--notes-from-tag` so the annotated tag message becomes that body. The GUI replaces the plain update alert with a What's New sheet and adds a slim banner pinned atop the detail column whenever `GimmeStore.pendingUpdate` is set.

**Tech Stack:** Swift 5.9 / SwiftPM (GimmeCore, gimme, GimmeUI targets), SwiftUI, XCTest with stubbed `HTTPClient`/`ProcessRunning` seams, GitHub Actions (`gh` CLI).

**Spec:** `docs/superpowers/specs/2026-08-27-whats-new-update-banner-design.md`

## Global Constraints

- macOS 13 floor, SwiftPM tools 5.9, **no external dependencies**.
- English only in all code, comments, and copy.
- TDD for GimmeCore; tests must inject stub `http:`/`process:` seams (enforced by `TestIsolationTests`). No real network in tests.
- GUI has no automated tests (v1 decision) — verified by building (`just app`) and launching. During manual verification **never click Update Now** (it replaces the running app bundle — a real mutation); visual check + What's New sheet only.
- **Do not commit.** AGENTS.md: "Commit or push only when the user asks." Task boundaries below are the commit boundaries to use if the user later asks.

---

### Task 1: `Release.notes` in GimmeCore (TDD)

**Files:**
- Modify: `Sources/GimmeCore/SelfUpdate.swift:9-19` (Release), `:48-55` (GHRelease), `:59-72` (latestRelease)
- Test: `Tests/GimmeTests/SelfUpdateTests.swift` (add to `SelfUpdateTests`, after `testLatestReleaseNilOnFailure`)

**Interfaces:**
- Produces: `SelfUpdate.Release.notes: String?` (new stored property; `init(tag:version:assets:notes: String? = nil)` — default keeps every existing `Release(...)` call site compiling), and `latestRelease()` now populates it from the GitHub `body` field.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/GimmeTests/SelfUpdateTests.swift` in the "release parsing" MARK:

```swift
    func testLatestReleaseParsesNotes() async {
        http.byURL["https://api.github.com/repos/gregnazario/gimme/releases/latest"] = Data(#"""
        {"tag_name":"v2.4.1","body":"## Faster fetches\n- per-package latest-version cache","assets":[]}
        """#.utf8)
        let release = await sut().latestRelease()
        XCTAssertEqual(release?.notes, "## Faster fetches\n- per-package latest-version cache")
    }

    func testLatestReleaseNotesNilWhenBodyAbsent() async {
        http.byURL["https://api.github.com/repos/gregnazario/gimme/releases/latest"] = Data(#"""
        {"tag_name":"v2.4.1","assets":[]}
        """#.utf8)
        let release = await sut().latestRelease()
        XCTAssertNil(release?.notes)
    }

    /// Cache entries written before `notes` existed lack the key; decoding
    /// an optional must not fail on them (12 h disk cache round-trip).
    func testReleaseDecodesCacheEntriesWrittenBeforeNotesExisted() throws {
        let json = #"{"tag":"v2.4.0","version":"2.4.0","assets":{"gimme-darwin-arm64.tar.gz":"https://example.com/a"}}"#
        let decoded = try JSONDecoder().decode(SelfUpdate.Release.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, "2.4.0")
        XCTAssertNil(decoded.notes)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SelfUpdateTests`
Expected: FAIL — `value of type 'SelfUpdate.Release' has no member 'notes'` (compile error in first two tests).

- [ ] **Step 3: Implement**

In `Sources/GimmeCore/SelfUpdate.swift`, change `Release` to:

```swift
    public struct Release: Equatable, Codable {
        public let tag: String               // "v2.3.0"
        public let version: String           // "2.3.0"
        public let assets: [String: String]  // asset name → browser_download_url
        /// Release notes (the GitHub release body). Nil when absent — older
        /// releases, or a cache entry written before this field existed.
        public let notes: String?

        public init(tag: String, version: String, assets: [String: String], notes: String? = nil) {
            self.tag = tag
            self.version = version
            self.assets = assets
            self.notes = notes
        }
    }
```

Change `GHRelease` to add the body field:

```swift
    private struct GHRelease: Decodable {
        let tag_name: String?
        let body: String?
        let assets: [Asset]?
        struct Asset: Decodable {
            let name: String?
            let browser_download_url: String?
        }
    }
```

Change the `latestRelease()` return line:

```swift
        return Release(tag: tag, version: version, assets: assets, notes: doc.body)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SelfUpdateTests`
Expected: PASS (all, including the pre-existing parsing/checksum/CLI tests).

---

### Task 2: release workflow uses the tag message as notes

**Files:**
- Modify: `.github/workflows/release.yml:166-175` (Create GitHub Release step)

**Interfaces:**
- Consumes: annotated tag messages (already the release-process convention — `tag.gpgSign=true`).
- Produces: release `body` = tag annotation text, which Task 1 surfaces as `Release.notes`.

- [ ] **Step 1: Change the flag**

Replace the `gh release create` invocation's `--generate-notes` line with `--notes-from-tag` and a comment:

```yaml
      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          # --notes-from-tag: the annotated tag message IS the release body —
          # it surfaces as "What's New" in `gimme update --self` and the GUI.
          # Annotated tags are already mandatory (a lightweight tag fails here
          # loudly instead of shipping empty notes).
          gh release create "$GITHUB_REF_NAME" \
            --title "gimme ${{ steps.version.outputs.version }}" \
            --notes-from-tag \
            gimme-darwin-arm64.tar.gz \
            GimmeUI-darwin-arm64.tar.gz \
            SHA256SUMS
```

- [ ] **Step 2: Sanity-check the flag exists on the runner's gh**

Run: `gh version && gh release create --help | grep -A1 "notes-from-tag"`
Expected: gh ≥ 2.59 and the flag documented. (No test run — first release exercises it.)

---

### Task 3: CLI prints What's New during self-update

**Files:**
- Modify: `Sources/gimme/main.swift:271-286` (`runSelfUpdate`)

**Interfaces:**
- Consumes: `SelfUpdate.Release.notes` (Task 1).
- Produces: console output only — no signature changes.

- [ ] **Step 1: Add the notes block**

In `runSelfUpdate()`, after `print("updating to \(release.version)…")` and before the `let executable = …` line, insert:

```swift
        if let notes = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            print("What's new:")
            for line in notes.components(separatedBy: .newlines) {
                print("  \(line)")
            }
        }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: BUILD SUCCEEDED. (Glue over the tested parse; no executable-target test harness exists. Read-only live check: `.build/debug/gimme update --self` prints "up to date" plus — once a `--notes-from-tag` release exists — the notes block on a real update; never run it expecting a mutation.)

---

### Task 4: GimmeStore — banner state + sheet flag + notification copy

**Files:**
- Modify: `Sources/GimmeUI/GimmeApp.swift:156-195` (self-update state + `checkForUpdates`)
- Modify: `Sources/GimmeUI/UpdateNotifier.swift:30-32` (stale doc comment)

**Interfaces:**
- Consumes: `SelfUpdate.Release.notes` (via `pendingUpdate`).
- Produces for Task 5: `store.pendingUpdate: SelfUpdate.Release?` (now also set by the background check when `config.notifyUpdates`), `store.showUpdateSheet: Bool` (new `@Published`), existing `store.updateSelf(_:)`, `store.isSelfUpdating`.

- [ ] **Step 1: Add the published flag**

Next to `pendingUpdate` (GimmeApp.swift ~line 163) add:

```swift
    /// Presents the What's New / Update Now sheet (manual check or banner).
    @Published var showUpdateSheet = false
```

- [ ] **Step 2: Rewrite the tail of `checkForUpdates` and its doc comment**

Replace the current doc comment and the `if manual { … } else if …` block (lines ~169-194) with:

```swift
    /// Latest-release check. `manual` (menu item) bypasses the 12 h cache,
    /// reports the result, and opens the What's New sheet when an update
    /// exists; the background launch check raises the in-app banner (and
    /// posts a notification) only while `notifyUpdates` is on.
    func checkForUpdates(manual: Bool) async {
```

(fetch/cache logic unchanged; then:)

```swift
        if manual {
            pendingUpdate = release
            showUpdateSheet = true
        } else if config.notifyUpdates {
            pendingUpdate = release
            notifier.post(title: "gimme",
                body: "gimme \(release.version) available — update from the gimme app")
        }
```

- [ ] **Step 3: Fix the stale UpdateNotifier doc comment**

`Sources/GimmeUI/UpdateNotifier.swift` lines ~30-32 say there is "no in-app surface announcing it" — that described the pre-banner world. Rewrite the sentence to: the banner (`UpdateBanner`) is the in-app surface; the notification still fires because a user in another app sees nothing otherwise.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: BUILD SUCCEEDED (no consumers of `showUpdateSheet` yet — Task 5 adds them; unused-warning is acceptable for one task, or build after Task 5 if it bothers).

---

### Task 5: GUI — UpdateBanner, UpdateSheet, mount, replace alert

**Files:**
- Create: `Sources/GimmeUI/Views/UpdateBanner.swift`
- Create: `Sources/GimmeUI/Views/UpdateSheet.swift`
- Modify: `Sources/GimmeUI/ContentView.swift:36-46` (mount banner in detail column)
- Modify: `Sources/GimmeUI/GimmeApp.swift:27-39` (replace the "Update gimme?" alert with the sheet presentation)

**Interfaces:**
- Consumes: Task 4's `pendingUpdate`, `showUpdateSheet`, `updateSelf(_:)`, `isSelfUpdating`; `GimmeApp.accent`.
- Produces: `UpdateBanner` / `UpdateSheet` views (internal to GimmeUI).

- [ ] **Step 1: Create `UpdateBanner.swift`**

```swift
import SwiftUI
import GimmeCore

/// Slim banner pinned atop the detail column whenever an update is pending
/// (background launch check or manual check). "Update Now" runs the verified
/// self-update in place; ✕ hides the banner until the next background check
/// (12 h TTL) re-raises it.
struct UpdateBanner: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(GimmeApp.accent)
            if let release = store.pendingUpdate {
                Text("gimme \(release.version) is available")
                    .fontWeight(.medium)
                Text("(you have \(GimmeVersion.current))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isSelfUpdating {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary)
            } else {
                Button("What's New") { store.showUpdateSheet = true }
                Button("Update Now") {
                    if let release = store.pendingUpdate {
                        Task { await store.updateSelf(release) }
                    }
                }
                .buttonStyle(.borderedProminent)
                Button {
                    store.pendingUpdate = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide until the next check")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
```

- [ ] **Step 2: Create `UpdateSheet.swift`**

Header pattern copied from `AboutGimme` (✕ wired to `.cancelAction` — navigation policy §1):

```swift
import SwiftUI
import GimmeCore

/// What's New + Update Now confirmation for a pending release (navigation
/// policy §1: sheet with a visible ✕, Esc to dismiss; Later dismisses
/// without acting; Update Now acts then relaunches).
struct UpdateSheet: View {
    @EnvironmentObject var store: GimmeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Update gimme?").font(.title2).fontWeight(.semibold)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding()
            Divider()
            if let release = store.pendingUpdate {
                content(release)
            } else {
                Text("No update information is available.")
                    .foregroundStyle(.secondary)
                    .padding(24)
            }
        }
        .frame(width: 460, height: 420)
    }

    private func content(_ release: SelfUpdate.Release) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("gimme \(release.version) is available — you have \(GimmeVersion.current). The app downloads, verifies, and relaunches itself.")
                .foregroundStyle(.secondary)
            Text("What's New").font(.headline)
            notesBody(release)
            Spacer()
            HStack {
                Spacer()
                Button("Later") { dismiss() }
                if store.isSelfUpdating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Updating…")
                    }
                    .padding(.horizontal, 8)
                } else {
                    Button("Update Now") {
                        Task { await store.updateSelf(release) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
    }

    /// Tag-message notes rendered as inline markdown (whitespace preserved).
    /// Empty/missing notes (old cache entry, pre-notes release) fall back to
    /// a link to the releases page.
    @ViewBuilder
    private func notesBody(_ release: SelfUpdate.Release) -> some View {
        let trimmed = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Release notes are on GitHub.")
                    .foregroundStyle(.secondary)
                Link("github.com/gregnazario/gimme/releases",
                     destination: URL(string: "https://github.com/gregnazario/gimme/releases")!)
            }
        } else {
            ScrollView {
                if let attributed = try? AttributedString(
                    markdown: trimmed,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(trimmed).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 220)
        }
    }
}
```

- [ ] **Step 3: Mount the banner in `ContentView`**

Replace the `detail:` closure (ContentView.swift:36-46) with:

```swift
        } detail: {
            VStack(spacing: 0) {
                if store.pendingUpdate != nil {
                    UpdateBanner()
                    Divider()
                }
                switch store.sidebarSelection {
                case .installed:     InstalledView()
                case .updates:       UpdatesView()
                case .browse:        BrowseView()
                case .managers:      PackageManagersView()
                case .consolidate:   ConsolidateView()
                case .preferences:   PreferencesView()
                case .activity:      ActivityView()
                }
            }
        }
```

- [ ] **Step 4: Replace the alert with the sheet in `GimmeApp`**

Delete the `.alert("Update gimme?", …)` modifier (GimmeApp.swift:27-39) and add next to the other sheets:

```swift
                .sheet(isPresented: $store.showUpdateSheet) {
                    UpdateSheet()
                }
```

(Sheets inherit the environment from the presentation context — same as `ReportIssueView()`.)

- [ ] **Step 5: Build everything**

Run: `swift build`
Expected: BUILD SUCCEEDED, no warnings about the removed alert binding.

---

### Task 6: Verification

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: all PASS, including `TestIsolationTests` (new tests use stub seams only).

- [ ] **Step 2: Build + launch the app bundle**

Run: `just app && open app/Gimme.app`
Expected: app launches. Because the dev version is `2.0.0-dev` < latest release (v2.4.0) and `notifyUpdates` defaults on, the banner appears at the top of the detail column after the (cached, ≤12 h) check resolves. **Do not click Update Now** (it replaces the local `app/Gimme.app` — a real mutation). Verify visually:
  - Banner: "gimme <latest> is available (you have 2.0.0-dev)" with What's New / Update Now / ✕.
  - What's New opens the sheet; notes render (v2.4.0's body is still the old auto-generated list — expected until the first `--notes-from-tag` release); ✕ and Esc dismiss.
  - Banner ✕ hides it.
  - If the banner doesn't appear: check `~/.config/gimme/config.toml` for `notifyUpdates = false` and whether the 12 h cache serves an older check; delete the cache entry or run a manual Check for Updates… to confirm the sheet.

- [ ] **Step 3: Read-only CLI check**

Run: `.build/debug/gimme update --self`
Expected: "gimme 2.0.0-dev" → "up to date (latest release: …)" or the notes printout — read-only path only; the debug binary is older than latest, so **expect it would want to update — do not confirm/proceed if it prompts** (it doesn't: `update --self` updates without asking, so prefer checking with a release-built binary that reports up to date, or skip this step if the local binary is behind).
