# gimme Self-Update — Design

**Status:** Approved in interview (scope: both CLI + GUI; full-auto in-app update)
**Date:** 2026-08-22
**Builds on:** release process (tag-driven GitHub releases), Version.swift CI sed,
notifications (2026-08-22)

---

## 1. Purpose

gimme updates every package manager on the Mac but not itself. The CLI is
replaced only by re-running install.sh; the app only by re-downloading a DMG
that isn't even published to releases yet. This adds first-class self-update
for both surfaces, driven by the existing tag-driven GitHub releases.

Decisions (interview 2026-08-22; scope question unanswered → recommended
"both" per session pattern):

| # | Decision | Choice |
|---|---|---|
| 1 | Surfaces | **Both** — `gimme update --self` (CLI) and Check for Updates… (GUI). |
| 2 | GUI behavior | **Fully automatic in-app update** (download → verify → swap → relaunch), not just an open-the-page link. |
| 3 | Update source | `api.github.com/repos/gregnazario/gimme/releases/latest` (public, no auth). |
| 4 | Update check | GUI checks on launch, 12 h disk-cached; CLI checks only when asked. |

## 2. Shared core — `Sources/GimmeCore/SelfUpdate.swift`

`final class SelfUpdate` with injected `HTTPClient` + `ProcessRunning`
(tested with stubs like every adapter):

- `struct Release { tag, version, assets: [name: url] }` —
  `latestRelease()` fetches and parses `releases/latest`; any failure
  returns nil (never crashes a launch path).
- `DottedVersion.isOlder(_:than:)` — the dot-segment numeric comparison now
  living in `AppStoreManager.isOlder` moves to a shared helper (new file
  `VersionCompare.swift`); AppStoreManager delegates to it, tests move with
  the logic.
- `func updateCLI(at executablePath: URL, progress: ((String) -> Void)?) async throws -> String`:
  download `gimme-darwin-<arch>.tar.gz` (arch from `uname -m` equivalent —
  `ProcessInfo.processInfo` hardware translation), extract with
  `/usr/bin/tar -xzf` into a temp dir, **verify** the extracted binary's
  `--version` output contains the expected version, `chmod 755`, then
  atomic `rename()` over the executable path. Non-writable target →
  `GimmeError.operationFailed` with the install.sh fallback as the message.
- `func downloadApp(to dir: URL, expectVersion: String) async throws -> URL`:
  download `GimmeUI-darwin-<arch>.tar.gz`, extract, verify the bundle's
  `CFBundleShortVersionString` matches, return the extracted `.app` URL.

## 3. CLI — `gimme update --self`

`--self` flag on the existing `update` verb. Flow: print current version →
check latest → up-to-date message or the updateCLI dance with streamed
progress lines → final "updated to X". Dev builds (`…-dev`) are upgradeable
like any other version (explicit user intent). Help text gains the flag.

## 4. GUI — Check for Updates… + automatic swap

- **gimme menu → "Check for Updates…"** (after About). Runs the check
  (bypassing cache when invoked manually) and either reports up-to-date via
  alert or asks to update (alert with Update / Cancel — policy table row 2:
  built-in OK/Cancel).
- **Update flow** (`GimmeStore.updateSelf()`): download + verify via core →
  stage the new `.app` in a temp dir → spawn a detached `/bin/sh -c`
  swap script: `pkill -x GimmeUI; sleep 1; rm -rf <target>; cp -R <staged>
  <target>; open <target>` → `NSApp.terminate`. The swap script runs after
  the app exits (children survive a normal exit); any pre-swap failure keeps
  the running app untouched. Target = the running bundle's path
  (`Bundle.main.bundleURL`) so dev copies in `app/` update in place too.
- **Background launch check:** on `loadAll`, if cached check is stale (>12 h)
  and `config.notifyUpdates`, post one notification "gimme <v> available —
  gimme menu → Check for Updates…". No interactive prompts on launch.

## 5. Known limitation (documented, accepted)

GitHub-release assets are CI-built (ad-hoc signed) until notarization is
configured; the in-app path is a curl-style download (URLSession sets no
quarantine), so Gatekeeper is not involved. When signed/notarized artifacts
are later uploaded as the same asset names, the updater uses them unchanged.
Binaries owned by another package manager (root-owned paths) are declined
with guidance, not fought.

## 6. Testing

Core is fully unit-tested with stub HTTP/process: release parsing, version
ordering (via the shared DottedVersion tests), CLI happy path (asserts
download URL, tar invocation, version verification call, rename target),
unwritable-target decline, app download+version-verify, version-mismatch
abort. GUI verified by build + launch per repo policy.

## 7. Out of scope (v1)

- Delta/patch updates, update channels (beta), auto-update without a click,
  `gimme update` bundling self+packages (self stays explicit via --self).
- Publishing the signed DMG to releases (separate release-process work).
