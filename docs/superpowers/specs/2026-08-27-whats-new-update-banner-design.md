# gimme What's New + Update Banner — Design

**Status:** Approved via recommended defaults (interview questions unanswered →
recommended options taken, per session pattern; see decision table)
**Date:** 2026-08-27
**Builds on:** self-update (2026-08-22), update notifications (2026-08-22),
release process (tag-driven GitHub releases)

---

## 1. Purpose

Self-update ships a version number and nothing else: the GUI shows a two-line
alert, the CLI prints "updating to X…", and release notes (the GitHub release
body) are fetched in the same JSON but never parsed. The only entry points are
the gimme app menu and — when `notifyUpdates` is on — a macOS notification;
there is no in-app surface announcing an available update
(`UpdateNotifier.swift`'s doc comment says as much). This adds:

1. **What's New** — release notes surfaced in the update flow (GUI sheet, CLI
   print).
2. **An always-visible update banner** — pinned at the top of the detail
   column whenever an update is pending, with a direct **Update Now** button.

Decisions (2026-08-27; questions posed, unanswered → recommended):

| # | Decision | Choice |
|---|---|---|
| 1 | Notes source | **Annotated tag message** — release.yml switches `--generate-notes` → `--notes-from-tag`. Tag subjects are already hand-written ("v2.3.2 — checksummed downloads…"); bigger releases get fuller tag bodies. |
| 2 | Update button home | **Banner across all sections** (top of the detail column), not an Updates-only card. |

Alternatives considered: rendering GitHub's auto-generated commit list
(machine-flavored, zero curation); a curated CHANGELOG.md (most control, most
maintenance — revisit if tag bodies prove too terse); an Updates-view-only
card (invisible from other sections); banner + card (redundant).

## 2. Data — `Release.notes` (GimmeCore/SelfUpdate.swift)

- `GHRelease` (private) gains `let body: String?` — already present in the
  `releases/latest` JSON, just never decoded.
- `Release` gains `public let notes: String?` with `notes: String? = nil`
  defaulted in `init`. Optional keeps it backward-compatible with the 12 h
  disk cache (`Cache` Codable round-trip: old entries decode with `notes =
  nil` — synthesized `decodeIfPresent` semantics) and with every existing
  `Release(...)` call site in tests / CLIToolInstaller.
- No extra network call: notes ride the existing `releases/latest` fetch.
  `notes == nil` (old cache entry, or a release whose tag carried no message)
  → UI falls back to a plain "see GitHub" line; the CLI prints nothing.

## 3. Release workflow — `--notes-from-tag`

`release.yml`'s `gh release create` replaces `--generate-notes` with
`--notes-from-tag`: the annotated tag message becomes the release body, which
§2 then surfaces everywhere. Annotated tags are already the release-process
convention (`tag.gpgSign=true`); gh falls back to the commit message only for
a lightweight tag, which the process doesn't produce anyway.

## 4. GUI — banner, sheet, progress

**Store (`GimmeStore`):**
- Background launch check (`checkForUpdates(manual: false)`) now sets
  `pendingUpdate` (drives the banner) in addition to posting the
  notification. Both stay gated by `config.notifyUpdates` — the toggle keeps
  meaning "don't tell me about updates"; turning it off removes banner +
  notification, never the manual menu check.
- New `@Published var showUpdateSheet = false`. Manual check with an update
  found sets it (direct response to the user's action); the banner's
  **What's New** button sets it.
- The existing "Update gimme?" **alert is replaced** by the sheet.

**Banner (`Views/UpdateBannerView.swift`, mounted in `ContentView` above the
section switch):** slim HStack on a `.bar` material — icon, "gimme 2.4.1 is
available" (current version secondary), **What's New** (opens the sheet),
**Update Now** (`.borderedProminent`, compact), ✕ (clears `pendingUpdate`;
the 12 h-TTL background check re-raises it later). While `isSelfUpdating` the
buttons disable and it shows a small progress indicator + "Updating…" —
today's flow has zero visible feedback.

**Sheet (`Views/UpdateSheet.swift`, nav policy §1 — Close/Cancel):** header
"Update gimme?" with ✕ wired to `.cancelAction` (Esc), subtitle "gimme 2.4.1
is available (you have 2.4.0)", What's New body rendered as markdown
(`AttributedString(markdown:)`) in a scroll view, **Update Now**
(`.borderedProminent`, progress state while updating), **Later** dismisses
without acting. Update succeeds → the app already relaunches itself.

**Sheet environment gotcha (found in verification):** sheets presented in
`GimmeApp` (outside `ContentView().environmentObject(store)`) do not receive
the store on macOS 26 — accessing it crashes (`EnvironmentObject.error()`).
`UpdateSheet` must inject `.environmentObject(store)` at the presentation
site. This also exposed a **latent shipped bug**: "Report an Issue…" crashed
in its `.onAppear` the same way (the form rendered, then the app died on the
first store access); it gets the same one-line fix.

**Notification copy & delivery:** "gimme menu → Check for Updates…" →
"update from the gimme app" (the banner is now the in-app surface the
notification lacked). The update-available post also becomes background-only
(like run summaries): `UpdateNotifier.post` now skips while gimme is
frontmost, since the banner already announces it there — this retires the
"no in-app surface" rationale in that method's doc comment.

## 5. CLI — `gimme update --self`

After the newer-version guard and before downloading, print the notes when
present:

```
updating to 2.4.1…
What's new:
  <tag message body, whitespace-trimmed>
```

No change to the up-to-date / failure paths.

## 6. Testing

- `SelfUpdateTests`: extend the release-parsing stub JSON with `body` and
  assert `notes`; absent `body` → `notes == nil`; old cache-format decode
  (no `notes` key) → `nil` round-trip.
- Workflow change verified by inspection (YAML; first release exercises it).
- Banner/sheet per v1 GUI policy: no automated UI tests; verify by building
  and launching the app. CLI print is glue over the tested parse.

## 7. Out of scope

- Post-update "you're now on X" What's New surfacing (the sheet shows notes
  *before* updating; after relaunch there's nothing pending to show).
- Update channels / beta opt-in, delta updates, auto-update without a click.
- CHANGELOG.md or docs-site notes pages (revisit if tag bodies prove too
  terse for the sheet).
