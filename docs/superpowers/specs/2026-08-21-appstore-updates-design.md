# App Store Updates — Design

**Status:** Proposed (awaiting review)
**Date:** 2026-08-21
**Builds on:** the v2 orchestrator (`docs/superpowers/specs/2026-08-07-gimme-v2-orchestrator-design.md`)

---

## 1. Purpose

gimme shows updates for Homebrew, Go, uv, Cargo, bun, npm, pnpm, yarn, RubyGems,
Composer, Deno, pipx, aqua, and ubi — but says nothing about Mac App Store apps,
which update through a channel none of those managers can see. On a typical Mac
that is dozens of apps (Slack, Telegram, Xcode, UTM, Magnet…) silently drifting
out of date unless the user happens to open the App Store.

This feature adds a fifteenth adapter, `AppStoreManager`, that surfaces App
Store apps in the unified Installed/Updates views and triggers their updates —
**updates only**. No install, uninstall, search, or info.

Facts established on the design machine (2026-08-21):

- `mas` is **not** installed, so the read path must not depend on it.
- 25 App Store apps are detectable via `Contents/_MASReceipt/receipt` in their
  `.app` bundles across `/Applications`.
- The public iTunes Lookup API works without auth for version comparison
  (verified live: local Slack 4.51.180 vs store 4.51.191 — actually outdated).

---

## 2. Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Scope | **Updates only** — list, outdated, upgrade. No install/uninstall/search/info. |
| 2 | Update trigger | **Hybrid** — `mas upgrade <id>` when `mas` exists; otherwise open the app's App Store page. |
| 3 | Architecture | **Receipt scan + iTunes Lookup API** for the entire read path; `mas` used opportunistically only for the write path. |
| 4 | Storefront | `country=us` (what `mas` uses; versions are global except in rare region-locked cases). |
| 5 | Detection bias | **Never false-flag.** An app that can't be resolved or compared is skipped, not marked outdated. |
| 6 | Ecosystem | App Store joins the **System** ecosystem bucket for consolidation display. |

Decisions 1–3 were made in the design interview; 4–6 are design-level defaults
from the interview recommendation, called out here for review.

---

## 3. `ManagerID` additions

New case `appstore` in `ManagerID` (15 total):

- `displayName` → `"App Store"`
- `iconName` → `"app.badge.fill"` (the update-badge look; available since SF Symbols 2, so safe on the macOS 13 floor)
- `ecosystem` → `.system`

Capabilities advertised by the adapter: `[.list, .outdated, .upgrade]`. The
engine and GUI already gate per-manager actions on capabilities, so App Store
apps are installable nowhere and searchable nowhere — they simply appear in
Installed and Updates.

`isAvailable()` returns **true always** (it requires only `/Applications`).
There is no `bootstrap()` — nothing to install; `version()` returns nil.

---

## 4. Read path — detection & outdated

### 4.1 Installed enumeration (`listInstalled`)

Shallow scan of two directories: `/Applications` and `~/Applications`
(injectable in the initializer as `applicationDirs: [URL]`, which is also how
tests get hermetic fixtures). `/System/Applications` is **not** scanned — its
apps carry no MAS receipts.

For each `*.app` bundle:

1. `Contents/_MASReceipt/receipt` must exist — the definitive Mac App Store
   marker. Non-MAS apps (Chrome, Homebrew casks, drag-installed) are skipped
   without any further I/O.
2. Read `Contents/Info.plist` for `CFBundleDisplayName`/`CFBundleName` (name)
   and `CFBundleShortVersionString` (version), plus `CFBundleIdentifier` for
   the store lookup. Apps with unreadable plists are skipped.

`InstalledPackage.name` is the human app name (e.g. "Slack") so the unified
namespace reads naturally. The bundle ID is re-derived at action time (§5);
`PackageRef(name:)` also accepts a bundle ID for CLI precision.

### 4.2 Update detection (`outdated`)

For each installed app, one request:

```
GET https://itunes.apple.com/lookup?bundleId=<CFBundleIdentifier>&country=us
```

- `resultCount == 0` → app is gone from the store (pulled/renamed): **skip**,
  never flag. Same for network/decode failures — per-app `try?`, mirroring
  PipxManager, so one bad lookup can't fail the whole refresh.
- Otherwise compare `results[0].version` against the local version with a
  segment-wise numeric comparison ("4.51.180" < "4.51.191"). Non-numeric
  segments fall back to string-equality semantics; **incomparable-but-equal
  strings are treated as current** (decision 5: gimme has a history of
  permanent-outdated bugs; bias against false flags).
- The response also yields `trackId` and `trackName`, which feed the upgrade
  path.

Responses are cached per bundle ID for 6 h via the existing `Cache` (same
pattern and TTL as the Homebrew index; the adapter takes an `indexCache`
parameter and `defaultRegistry()` passes the same shared disk cache the
Homebrew adapter gets): first refresh costs ~25 requests,
subsequent refreshes are free. Concurrency mirrors PipxManager's task group —
unbounded, fine for tens of apps.

---

## 5. Write path — upgrade

`upgrade(PackageRef)`:

1. **Resolve.** If the name looks like a bundle ID
   (`*.*` with no spaces), match it directly against scanned apps; otherwise
   match the display name. Re-scan receipts to get the bundle ID, then the
   cached lookup for the `trackId`. Unresolvable → `GimmeError.notFoundInManagers`.
2. **Act.** If `BinaryResolver.resolve("mas")` is non-nil: run
   `mas upgrade <trackId>`. mas 7 requires root and prompts through sudo,
   which cannot work where there is no TTY (the GUI app) — when mas fails
   with sudo's "a terminal is required" signature, gimme retries once with
   `SUDO_ASKPASS` pointed at a generated helper (`~/.cache/gimme/
   sudo-askpass.sh`, 0700) that shows the native password dialog via
   osascript — the Homebrew pattern; the password goes to sudo only and is
   never stored. A retry failure or any other mas error (e.g. "not signed
   in") falls through to the fallback rather than erroring. Fallback:
   `open macappstore://apps.apple.com/app/id<trackId>` to land the App Store
   on the app's page, where the user clicks Update.
3. **Coalesce.** `updateAll` calls `upgrade()` once per outdated package, and
   N fallback opens would be obnoxious. The adapter keeps a timestamp guard:
   if it already opened an App Store URL in the last 10 seconds, further opens
   are skipped (the pane is already up). In-memory only — runs are short-lived.
   When `mas` is present every ID passes through serially, no guard applies.

Install/uninstall are not implemented (capabilities don't advertise them);
removing a MAS app is a drag-to-trash, not a package-manager op.

---

## 6. Surface (CLI + GUI)

**No new views, commands, or preferences.** Everything renders from the
registry-driven views that already exist:

- `gimme list` gains an `appstore:` section; `gimme outdated` gains App Store
  rows (on the design machine, Slack shows today).
- `gimme upgrade Slack` (or `gimme upgrade com.tinyspeck.slackmacgap`) and
  `gimme update` drive the hybrid path.
- GimmeUI's Installed and Updates sections show App Store apps with the new
  badge; Update All flows through the coalesced path.
- `gimme config disable appstore` works as with every other manager.
- The only code touchpoints outside the new adapter file: `ManagerID` enum,
  `Gimme.defaultRegistry()`, `Ecosystem` bucket, and (if colors are hardcoded
  per manager) `ManagerPalette` — the implementation plan verifies that list.

---

## 7. Testing strategy (in-process, no network — suite rule)

The adapter takes injected `HTTPClient`, `ProcessRunning`, and
`applicationDirs`, so every test is hermetic:

1. **Receipt scan:** temp dir with fake `.app` bundles (receipt + Info.plist;
   one non-MAS neighbor) → `listInstalled` returns exactly the MAS apps.
2. **Outdated matrix:** stubbed lookups for older / newer / equal / re-formatted
   ("1.0" vs "1.0.0" → current) / `resultCount == 0` / network-failure cases.
3. **Version comparison helper:** numeric segments, unequal lengths,
   non-numeric fallback.
4. **Upgrade:** with `mas` stubbed present → asserts `mas upgrade <id>` runs;
   absent → asserts exactly one `open` URL despite three consecutive upgrade
   calls (coalescing), and that the URL contains the right track ID.
5. **Cache:** second `outdated()` within TTL issues no HTTP calls.

Verification on a real machine (manual, per repo practice): `gimme outdated`
shows Slack as outdated today; `gimme upgrade Slack` with mas absent opens the
App Store on Slack's page.

---

## 8. Out of scope (v1)

- Install / uninstall / search / info for App Store apps (search via the iTunes
  Search API is a trivially additive follow-up if wanted later).
- macOS system software updates (`softwareupdate --list`) — different beast
  (sudo, restarts); not "App Store apps."
- Non-MAS GUI app update checks (Sparkle etc.).
- Bootstrapping `mas` automatically — it is used opportunistically only;
  users who want fully scripted updates can `brew install mas` themselves.
- Auto-updating anything without a click/confirm.

---

## 9. Build sequence (high-level — detailed plan to follow)

1. `ManagerID.appstore` + ecosystem bucket + palette (compile).
2. `AppStoreManager`: receipt scan → `listInstalled` (with tests).
3. Version compare + iTunes lookup + cache → `outdated` (with tests).
4. Hybrid `upgrade` + coalescing (with tests).
5. Wire into `defaultRegistry()`; end-to-end manual check on the design
   machine; README/manager-list docs touch-up.
