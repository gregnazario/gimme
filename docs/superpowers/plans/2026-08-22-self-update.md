# gimme Self-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** gimme updates itself from its own GitHub releases — `gimme update --self` (CLI) and Check for Updates… (GUI, fully automatic in-app swap).

**Architecture:** `SelfUpdate` core (GimmeCore, injected HTTP/process) parses `releases/latest` and drives download/verify/replace; `DottedVersion` centralizes version ordering; CLI flag + GUI menu/alerts/swap-script consume it.

**Spec:** `docs/superpowers/specs/2026-08-22-self-update-design.md`
**Status:** implemented 2026-08-22 (c2d440a) — 245 tests green; live-verified: a dev binary self-updated to the real v2.2.0 release end-to-end.

## Tasks (completed)

- [x] `DottedVersion` extraction (AppStoreManager delegates; tests moved)
- [x] `SelfUpdate` core: `latestRelease()`, `isNewer`, `updateCLI` (download → real tar extract → `--version` verify → atomic replace; declines unwritable targets with install.sh guidance), `downloadApp` (extract + Info.plist version verify)
- [x] 8 unit tests (real tar.gz fixtures; the stub process delegates tar to a real runner)
- [x] CLI: `--self` flag, `runSelfUpdate`, help text
- [x] GUI: Check for Updates… menu, confirm alert, `updateSelf` (staged download → detached `pkill/rm/cp/open` swap → terminate), 12 h-cached launch check + notification (gated `notifyUpdates`); `UpdateNotifier.post` for informational (not background-gated) banners
- [x] Live verification + ship loop

## Notes for future changes

- Asset names: `SelfUpdate.cliAssetName` / `appAssetName` (compile-time arch).
- Dev builds report `2.0.0-dev`, so the GUI on a dev install will always offer the latest release — expected until the next tag.
- Replacing a *running* app requires the pkill-first dance; the swap script lives in `GimmeStore.updateSelf`.
