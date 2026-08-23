# Update-Finished Notifications — Design

**Status:** Approved in interview (background-only, one summary per run)
**Date:** 2026-08-22
**Builds on:** the v2 orchestrator spec; App Store updates adapter (2026-08-21)

---

## 1. Purpose

When an update run finishes while Gimme is not the active window, the user has
no signal — mas-driven App Store updates can take minutes, brew upgrades
compile, and by then the user has switched to something else. This adds one
macOS notification per finished run: a single Update reports its own result,
Update All reports a summary. Feedback while Gimme is frontmost stays as-is
(in-app Done/Failed badges) — no redundant banners.

Decisions locked in the design interview (2026-08-22):

| # | Decision | Choice |
|---|---|---|
| 1 | When to notify | **Background only** — posted only when Gimme is not the active app. |
| 2 | Granularity | **One summary per run.** Single update → its own notification; Update All → one "finished" summary, never per-package banners. |

## 2. Mechanism

`UserNotifications` (`UNUserNotificationCenter`) — the only non-deprecated
macOS API. The app is a proper bundle (`io.gregnazario.gimme`) and not
sandboxed, so no entitlements are needed; only an authorization prompt.

New file `Sources/GimmeUI/UpdateNotifier.swift` — owned by `GimmeStore`:

- **Authorization, contextual:** `requestAuthorizationIfNeeded()` is awaited
  at the start of `GimmeStore.upgrade(_:)` and `GimmeStore.updateAll()` —
  the system prompt appears at the first Update action, not at launch.
  Requests `.alert` only (no sound, no badges, no critical). After a denial
  the system never re-prompts and gimme never nags; every post checks
  `getNotificationSettings()` and skips silently unless authorized.
- **Posting, background-only:** `runFinished(updated:failed:)` posts one
  notification if `NSApp.isActive == false` at completion time. If Gimme is
  frontmost, it posts nothing (the on-screen badges are the feedback).
  Non-bundle context (raw SwiftPM binary via `swift run`, where Apple's API
  raises) is detected via `Bundle.main.bundleIdentifier == nil` and skips
  silently.
- **Content:**
  - Single success: title "gimme", body "`<name>` updated to `<version>`"
    (version = the outdated row's latestVersion).
  - Single failure: body "`<name>` update failed — `<error first line>`".
  - Update All: body "Updates finished — N updated, M failed"; if M > 0 the
    first failure's package + error line is appended.
  - All notifications are silent banners (no `.sound`).
- **Click-to-focus:** the notification's default action activates Gimme. A
  minimal `AppDelegate: NSObject, NSApplicationDelegate,
  UNUserNotificationCenterDelegate` is added and wired with
  `@NSApplicationDelegateAdaptor` in `GimmeApp`; `didReceive` calls
  `NSApp.activate(ignoringOtherApps: true)`. `willPresent` returns `.banner`
  for the rare case a post races window focus.

## 3. Wiring

`GimmeStore` constructs `UpdateNotifier()` alongside its `Gimme` engine:

- `upgrade(_ pkg:)`: request authorization up front; on completion (success
  or failure) call `runFinished` with the single-entry result.
- `updateAll()`: request authorization up front; call `runFinished` once with
  the `UpdateSummary` counts after the run completes — including the
  failure-only case.

Notification strings mention no manager internals beyond package names;
errors are single-line-ized (first line, truncated ~120 chars) so a brew
stderr dump can't produce a three-foot banner.

## 4. Known simplification

For App Store updates that fell back to opening the app's App Store page, the
engine reports success, so the summary counts them as "updated". The wording
stays generic ("Updates finished") rather than claiming installs; surfacing
"handed off to the App Store" distinctly would require an engine-level result
enum — deliberately out of scope.

## 5. Testing

Per the repo's v1 decision the GUI has no automated tests; the testable
surface here is thin (two strings and an if). Verification: build all
targets, launch the app, trigger an update with Gimme unfocused and confirm
the banner + click-to-focus. The non-bundle guard keeps `swift run GimmeUI`
crash-free.

## 6. Out of scope (v1)

- CLI notifications (terminal output already exists).
- Sounds, badge counts, notification actions beyond click-to-focus.
- Per-package progress banners during Update All.
- A Preferences toggle (revisit if the background-only default annoys).
