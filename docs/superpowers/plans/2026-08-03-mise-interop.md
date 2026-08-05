# gimme Mise/asdf Interop Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add mise/asdf config reading + coexistence to gimme: `gimme install`
auto-detects `.tool-versions`/`mise.toml`, installs supported unmanaged tools,
skips tools already managed by mise/asdf, with a structured batch JSON shape.

**Architecture:** A new `Sources/GimmeCore/mise/` module (4 files) layered on
the existing foundation — consumes `Installer`, `GimmeError`, `GimmePaths`,
`Schema`, the TOML parser. CLI integration via the existing `Gimme` runner and
`install` command; no new subcommands.

**Tech Stack:** Swift 6 / SwiftPM, XCTest. No new dependencies.

## Global Constraints

- macOS only; reuses `GimmePaths`, `Host`, `Installer`, `Resolver`.
- `swift test` must pass after every task. New `mise/` module ≥90% coverage.
- Commits: one per task, conventional-commit format, never attribute AI.
- All temp work under `--prefix`; tests never touch real `~/.gimme`.

## File Structure

```
Sources/GimmeCore/mise/
  MiseVersionSpec.swift     # spec grammar: exact/fuzzy/latest/alias/prefix/unsupported
  MiseConfig.swift          # parse .tool-versions + mise.toml [tools]; walk + merge
  MiseDetector.swift        # is a tool managed by mise/asdf? PATH resolve + realpath
  MiseIntegration.swift     # orchestrator: read -> filter -> install; batch result
Tests/GimmeTests/
  MiseVersionSpecTests.swift
  MiseConfigTests.swift
  MiseDetectorTests.swift
  MiseIntegrationTests.swift
  MiseCLISnapshotTests.swift  # batch JSON shape via real binary
```

Modifies: `Sources/GimmeCore/Gimme.swift` (install command dispatch + flags),
`Sources/GimmeCore/agent/Introspect.swift` (new flags), `Sources/gimme/main.swift`
(arg parsing for `--from-mise`/`--no-mise`).

---

## Task 1: MiseVersionSpec

**Files:** `Sources/GimmeCore/mise/MiseVersionSpec.swift`, `Tests/GimmeTests/MiseVersionSpecTests.swift`

**Interfaces:**
- Produces `public struct MiseVersionSpec: Equatable` with `raw: String`, `kind: Kind`,
  `public static func parse(_ s: String) -> MiseVersionSpec`, and
  `func toGimmeQuery(tool: String) -> String?` (nil for unsupported).
- `Kind`: `exact(Version)`, `fuzzyMajor(Int)`, `latest`, `alias(String)`,
  `prefix(Int, Int)`, `unsupported(String)`.

- [ ] Write failing tests covering: exact `20.0.0`, fuzzy `20`/`3`, `latest`, `lts`(alias), `prefix:1.19`, `ref:master`(unsupported), `path:./x`(unsupported), `sub-2:lts`(unsupported), and `toGimmeQuery` for each.
- [ ] Implement `MiseVersionSpec.swift`.
- [ ] `swift test --filter MiseVersionSpecTests` passes.
- [ ] Commit.

## Task 2: MiseConfig (parse + walk + merge)

**Files:** `Sources/GimmeCore/mise/MiseConfig.swift`, `Tests/GimmeTests/MiseConfigTests.swift`

**Interfaces:**
- `public struct ToolRequest: Equatable { tool: String; spec: MiseVersionSpec }`
- `public enum MiseConfig`:
  - `static func parseToolVersions(_ text: String) -> [ToolRequest]`
  - `static func parseMiseToml(_ data: Data) throws -> [ToolRequest]`
  - `static func discover(startingAt cwd: URL) -> (requests: [ToolRequest], source: String?)` — walk up to `.git`/root, merge (closer wins per-tool).

- [ ] Write failing tests: parse `.tool-versions` (comments, blank lines, malformed); parse `mise.toml` `[tools]` (string + inline-table values); discover walks up and merges with closer-wins.
- [ ] Implement `MiseConfig.swift`.
- [ ] `swift test --filter MiseConfigTests` passes.
- [ ] Commit.

## Task 3: MiseDetector (PATH resolve + realpath)

**Files:** `Sources/GimmeCore/mise/MiseDetector.swift`, `Tests/GimmeTests/MiseDetectorTests.swift`

**Interfaces:**
- `public struct MiseDetector`:
  - `init(paths: GimmePaths, environment: [String:String] = ProcessInfo.processInfo.environment)`
  - `func isManaged(byManager tool: String) -> Bool`
  - `func owner(of tool: String) -> Manager?`
  - `public enum Manager: String { case mise, asdf }`

- [ ] Write failing tests using a temp fake-PATH with a temp "shims" dir + a symlink; verify detection of mise and asdf layouts; verify gimme's own bin dir is excluded; verify unmanaged tool returns nil.
- [ ] Implement `MiseDetector.swift` (which-style PATH walk, realpath via FileManager.resolvesSymlinksInPath, prefix check against `$MISE_DATA_DIR/shims`, `~/.local/share/mise/shims`, `~/.asdf/shims`).
- [ ] `swift test --filter MiseDetectorTests` passes.
- [ ] Commit.

## Task 4: MiseIntegration orchestrator

**Files:** `Sources/GimmeCore/mise/MiseIntegration.swift`, `Tests/GimmeTests/MiseIntegrationTests.swift`

**Interfaces:**
- `public struct MiseInstallResult: Equatable` with per-tool entries:
  `public struct ToolOutcome: Equatable { tool, spec, status: Status, version: String?, manager: Manager?, reason: String?, error: GimmeError? }`
  `public enum Status { case installed, alreadyCurrent, skippedManaged, skippedUnsupported, failed }`
- `public final class MiseIntegration`:
  - `init(world: World, detector: MiseDetector, cwd: URL)`
  - `func run(dryRun: Bool) -> MiseInstallResult`
  - `func toJSON() -> [String: Any]` with `cmd:"install-from-mise"`, `schema_version`, `source`, `tools[]`, `summary{installed,skipped,failed}`.

- [ ] Write failing integration test: drop `.tool-versions` in temp cwd with two tools (one installable via fixture, one unsupported `ref:`), assert install + skip outcomes; test `--dry-run` plans without installing.
- [ ] Implement `MiseIntegration.swift`.
- [ ] `swift test --filter MiseIntegrationTests` passes.
- [ ] Commit.

## Task 5: CLI integration (Gimme.run install + flags)

**Files:** modify `Sources/GimmeCore/Gimme.swift` (add `fromMise`/`noMise` to Options, dispatch batch in runInstall), modify `Sources/gimme/main.swift` (parse `--from-mise`/`--no-mise`).

**Interfaces:**
- `Gimme.Options` gains `fromMise: Bool`, `noMise: Bool`, `cwd: URL`.
- `runInstall` enters mise-reading mode when (no positional arg) AND (not `--no-mise`) AND (config discoverable); `--from-mise` forces it.

- [ ] Write failing tests in `MiseCLISnapshotTests` (in-process via `Gimme.run`): no-positional-arg auto-detect installs from `.tool-versions`; `--no-mise` opts out (prints usage / no batch); `--from-mise` forces; positional arg bypasses.
- [ ] Implement CLI wiring.
- [ ] `swift test --filter MiseCLISnapshotTests` passes.
- [ ] Commit.

## Task 6: doctor + introspect + final coverage

**Files:** modify `Sources/GimmeCore/Gimme.swift` (doctor check), `Sources/GimmeCore/agent/Introspect.swift` (`--from-mise`/`--no-mise` flags).

- [ ] Add doctor check reporting detected manager + gimme-installed tools it manages.
- [ ] Add the two flags to Introspect's `install` spec.
- [ ] Add subprocess snapshot test for `gimme install --json` in a temp cwd with `.tool-versions`.
- [ ] Measure coverage on `mise/`; add tests until ≥90%.
- [ ] `swift test` (full suite) green.
- [ ] Commit.

## Task 7: Document decisions

**Files:** `DECISIONS.md` at repo root.

- [ ] Record the decisions made during this work (mise spec parsing, detection strategy, coexistence policy, reserved follow-ons) with rationale.
- [ ] Commit.

---

## Self-Review

**Spec coverage:** §3 parsing → Tasks 1-2. §4 coexistence → Task 3. §5 result shape + CLI → Tasks 4-5. §5 doctor/introspect → Task 6. §7 testing → each task + Task 6 coverage. §6 reserved → not implemented (correct). Out-of-scope honored.

**Type consistency:** `MiseVersionSpec` shared by Tasks 1/2/4. `ToolRequest` shared by 2/4. `MiseDetector.Manager` shared by 3/4. `MiseInstallResult.ToolOutcome.Status` matches spec statuses exactly.

**Scope:** focused, one module, additive to foundation.
