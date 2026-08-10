# Ecosystems & Consolidation — Design

**Status:** Approved (design interview complete)
**Date:** 2026-08-10
**Builds on:** the v2 orchestrator (`docs/superpowers/specs/2026-08-07-gimmie-v2-orchestrator-design.md`)

---

## 1. Purpose

gimmie now supports 11 package managers, with 3 more coming. A tool like `esbuild` can be installed via bun, npm, pnpm, yarn, *and* deno — and most users accumulate the same package across several of them without realizing. There is today no single view that says "you have `esbuild` in both bun and npm — pick one."

This feature adds:

1. **Ecosystems** — a fixed classification of managers into language/tool buckets (JS, Python, Rust, …).
2. **Consolidation** — detection of same-package-same-ecosystem duplicates and a report that guides the user toward one preferred provider per ecosystem.
3. **Three new managers** — pipx (Python), aqua (System), ubi (System), bringing the total to 14.

Consolidation is **report + guide only** — gimmie never moves packages automatically. It prints the exact `gimme install` / `gimme uninstall` commands to run.

---

## 2. Decisions (locked during design interview)

| # | Decision | Choice |
|---|---|---|
| 1 | Ecosystem definition | **Fixed buckets** (JS, Python, Rust, Go, Ruby, PHP, System, Other). gimme owns the mapping. |
| 2 | Duplicate detection | **Same name, same ecosystem.** Same name across *different* ecosystems is not a duplicate (different builds). |
| 3 | Consolidation UX | **Report + guide.** No auto-migration. Print the commands; the user runs them. |
| 4 | Recommended provider | **Per-ecosystem preference** (`gimme config set ecosystem.js bun`), independent of the install-priority list. |
| 5 | New managers | **pipx, aqua, ubi** (14 total). |
| 6 | Scan scope | **All ecosystems**, always report (clean ecosystems listed compactly). |
| 7 | Architecture | **Static `Ecosystem` map + standalone `Consolidator`.** Ecosystem membership is metadata on `ManagerID` (a static extension), not a `PackageManager` protocol requirement. The consolidator is pure logic over already-fetched installed lists. |

---

## 3. Ecosystem Model

A new `Ecosystem` type classifies managers into fixed buckets. Lives in a new file `Sources/GimmeCore/Ecosystem.swift`, separate from `PackageManager` and `ManagerID`.

```swift
public enum Ecosystem: String, Hashable, Codable, CaseIterable {
    case js, python, rust, go, ruby, php, system, other

    public var displayName: String {
        switch self {
        case .js: return "JavaScript"
        case .python: return "Python"
        case .rust: return "Rust"
        case .go: return "Go"
        case .ruby: return "Ruby"
        case .php: return "PHP"
        case .system: return "System / native"
        case .other: return "Other"
        }
    }

    /// Which managers belong to this ecosystem. Inverse of `ManagerID.ecosystem`.
    public var managers: [ManagerID] { ManagerID.allCases.filter { $0.ecosystem == self } }
}

public extension ManagerID {
    /// The ecosystem this manager belongs to (fixed classification). Metadata,
    /// not a PackageManager protocol requirement.
    var ecosystem: Ecosystem {
        switch self {
        case .bun, .npm, .pnpm, .yarn, .deno: return .js
        case .uv, .pipx:                      return .python
        case .cargo:                          return .rust
        case .go:                             return .go
        case .gem:                            return .ruby
        case .composer:                       return .php
        case .homebrew, .aqua, .ubi:          return .system
        }
    }
}
```

### Ecosystem bucket assignments (14 managers)

| Ecosystem | Managers |
|---|---|
| **JavaScript** | bun, npm, pnpm, yarn, deno |
| **Python** | uv, pipx |
| **Rust** | cargo |
| **Go** | go |
| **Ruby** | gem |
| **PHP** | composer |
| **System / native** | homebrew, aqua, ubi |
| **Other** | _(none — fallback for future managers without a clear home)_ |

**Notes:**

- **`deno` is in JS** despite its own registry (JSR). For consolidation it competes with the npm family for the same CLI tools — putting it in JS means gimmie flags `file-server` installed via both deno and npm.
- **aqua + ubi are in System** alongside Homebrew. They install native binaries from GitHub releases with no language affinity, so they correctly flag duplicates against Homebrew (e.g. `bat` via both brew and aqua).
- **`other` exists as a safety net** so any future manager without a clear home doesn't break the model — it just won't consolidate against anything.

---

## 4. The Consolidator + Report

A pure type that operates on already-fetched installed-package lists. No I/O of its own.

### Types

```swift
/// Per-ecosystem recommended provider, separate from the install priority list.
/// Persisted in config.toml under [ecosystems].
public struct EcosystemPreferences: Codable, Equatable {
    public var preferences: [Ecosystem: ManagerID]
    public init(_ preferences: [Ecosystem: ManagerID] = [:]) { self.preferences = preferences }

    /// The recommended manager for an ecosystem, or a sensible default if unset.
    public func recommended(for ecosystem: Ecosystem) -> ManagerID {
        preferences[ecosystem] ?? ecosystem.managers.first ?? .homebrew
    }
}

/// A package installed in more than one manager within the same ecosystem.
public struct Duplicate: Identifiable, Equatable {
    public let name: String
    public let ecosystem: Ecosystem
    public let installed: [InstalledPackage]   // every manager that has it
    public let recommendedManager: ManagerID   // from preferences
    public var id: String { "\(ecosystem.rawValue):\(name)" }

    /// The packages to migrate AWAY from (everything except the recommended).
    public var toRemove: [InstalledPackage] { installed.filter { $0.manager != recommendedManager } }
}

/// A single migration step the user should run: install into recommended,
/// then uninstall from the others.
public struct MigrationStep: Equatable {
    public let duplicate: Duplicate
    public let installCommand: String?        // nil if recommended already has it
    public let uninstallCommands: [String]
}

public struct ConsolidationReport: Codable, Equatable {
    public let duplicates: [Duplicate]        // empty if clean
    public let steps: [MigrationStep]         // one per duplicate
    public let cleanEcosystems: [Ecosystem]   // ecosystems with no dups (reported too)
    public var hasDuplicates: Bool { !duplicates.isEmpty }
}
```

### `Consolidator`

```swift
public struct Consolidator {
    public let preferences: EcosystemPreferences

    public init(preferences: EcosystemPreferences) { self.preferences = preferences }

    /// Build the full report over already-fetched installed lists.
    public func report(for installed: [InstalledPackage]) -> ConsolidationReport
}
```

### Algorithm (pure, no surprises)

```
report(for installed):
  1. Group installed packages by (ecosystem, name).
     - ecosystem comes from each package's manager via ManagerID.ecosystem.
  2. For each group with >1 distinct manager → it's a Duplicate.
       recommendedManager = preferences.recommended(for: ecosystem).
  3. Build a MigrationStep per duplicate:
       - installCommand = recommended.has(package) ? nil
                         : "gimme install \(name) --from \(recommended)"
       - uninstallCommands = toRemove.map { "gimme uninstall \(name) --from \($0.manager)" }
  4. duplicates sorted by (ecosystem, name).
  5. cleanEcosystems = Ecosystem.allCases with no duplicates.
  6. return ConsolidationReport.
```

### Key design points

1. **Pure over fetched data.** `Consolidator` never queries managers directly — it takes the `[InstalledPackage]` that `Gimme.list` already produced (and cached). So `gimme consolidate` is fast on repeat runs and never re-spawns subprocesses. The consolidator is trivially testable with synthetic input.

2. **"Same name, same ecosystem" is enforced at the grouping step.** Two `esbuild` entries (bun + npm) group together → duplicate. `ripgrep` in Homebrew vs Cargo land in *different* groups (different ecosystems) → not a duplicate.

3. **Migration commands are real gimme commands, not raw `npm uninstall`.** The user runs `gimme uninstall esbuild --from npm`, which goes through the same resolver + adapter. No special "migration mode" path in the engine; the report is just text that tells you what to run.

4. **The recommended manager is computed, not stored per-duplicate.** Changing `ecosystem.js` from bun to pnpm is reflected on the next `gimme consolidate` immediately.

5. **Install command is conditional.** If the recommended manager already has the package, only uninstall commands are emitted — don't tell someone to install what they already have.

---

## 5. Config

`config.toml` gains an `[ecosystems]` table. Separate from `priority` (install routing) — different concern.

```toml
# ~/.config/gimme/config.toml
priority = ["homebrew", "go", "uv", ...]     # existing — install routing

[ecosystems]                                  # NEW — consolidation targets
js = "bun"
python = "uv"
system = "homebrew"
# rust, go, ruby, php unset → default to the first manager in the bucket
```

`Config` gains:

```swift
public var ecosystems: EcosystemPreferences
```

The existing TOML decoder handles the nested table. Unset ecosystems fall back to `ecosystem.managers.first`.

---

## 6. CLI Surface

Two new verbs + extensions to `config`:

```
gimme consolidate                    # scan all ecosystems, report duplicates + commands
gimme consolidate --json             # machine-readable ConsolidationReport
gimme config set ecosystem.js bun    # set the JS consolidation target
gimme config set ecosystem.python uv
gimme config show ecosystems         # show current per-ecosystem preferences
```

### `gimme consolidate` output (human)

Example — `esbuild` in bun+npm, `prettier` in npm+pnpm:

```
Consolidation report — 2 duplicates found.

JavaScript:
  esbuild
    installed via: bun, npm
    recommended:    bun
    to consolidate:
      gimme uninstall esbuild --from npm

  prettier
    installed via: npm, pnpm
    recommended:    bun
    to consolidate:
      gimme install prettier --from bun
      gimme uninstall prettier --from npm
      gimme uninstall prettier --from pnpm

Rust:       clean (no duplicates)
Go:         clean
Python:     clean
Ruby:       clean
PHP:        clean
System:     clean

Run the commands above to consolidate. No changes are made automatically.
```

When clean:

```
No duplicates found across any ecosystem. ✅

JavaScript: 9 packages across 2 managers (bun, npm)
Python:     4 packages across 1 manager (uv)
...
```

**Notes:**

- **Verb is `consolidate`, not `migrate`** — "migrate" implies it does the move; "consolidate" correctly implies report + guide. The output ends with an explicit reminder that no changes are made automatically.
- Every duplicate shows the full picture: which managers have it, the recommendation, and the exact commands. The user copies/pastes.
- Clean ecosystems are listed too (always report), but compactly — one line each.
- `--json` emits the `ConsolidationReport` struct directly for scripting/IDE integration.

### `config` validation

`gimme config set ecosystem.<id> <manager>` validates that the manager belongs to that ecosystem — `gimme config set ecosystem.js gem` is rejected with a clear error ("gem is in the Ruby ecosystem, not JavaScript"). `gimme config show ecosystems` lists current preferences + defaults.

---

## 7. New Managers (pipx, aqua, ubi)

Each follows the existing adapter pattern (TDD, `PackageManager` conformance, binary resolution via `BinaryResolver`).

### `PipxManager` — Python ecosystem

| Op | How |
|---|---|
| `search`/`info` | PyPI JSON API (`pypi.org/pypi/<name>/json`), shared with uv |
| `list` | `pipx list --json` → `{venvs: {name: {Package: {package_version, ...}}, ...}}` |
| `install` | `pipx install <pkg>` |
| `uninstall` | `pipx uninstall <pkg>` |
| `upgrade` | `pipx upgrade <pkg>` |
| `outdated` | compare each installed to PyPI latest (same approach as uv) |

Bootstrap: `brew install pipx` or `python3 -m pip install pipx`. Per-tool isolated venvs (same model as uv tool; pipx is the original).

### `AquaManager` — System ecosystem

| Op | How |
|---|---|
| `search` | Exact-existence only via `aqua list` / aqua's registry (no fuzzy search; like Go's proxy model). |
| `info` | Best-effort from aqua's registry metadata. |
| `list` | `aqua list` (installed packages) |
| `install` | `aqua install <owner/repo>` (imperative flow; declarative aqua.yaml is aqua's internal concern) |
| `uninstall` | `aqua rm <owner/repo>` |
| `outdated` | **Not supported.** aqua versions are pinned in config; `aqua update-aqua` updates aqua itself, not packages. |

Bootstrap: `brew install aquaproj/aqua/aqua`.

**Quirk:** aqua's model is declarative (`aqua.yaml`). The adapter models the standard imperative `aqua install`/`aqua list`/`aqua rm` flow; the declarative yaml is aqua's internal concern, not gimmie's.

### `UbiManager` — System ecosystem

| Op | How |
|---|---|
| `search` | **None.** ubi is a direct-download installer (`ubi --project owner/repo`); no registry, no search. `capabilities` omits `.search`. |
| `info` | GitHub repo lookup via the API (best-effort; subject to unauthenticated rate limits). |
| `list` | scan `~/.local/bin` for ubi-installed binaries. **Limitation:** ubi has no central manifest of what it installed; the adapter scans for known markers or tracks installs. Best-effort, like the Go adapter's GOBIN scan. |
| `install` | `ubi --project owner/repo [--tag v1.0]` |
| `uninstall` | `rm ~/.local/bin/<binary>` (like the Go adapter). |
| `outdated` | **Not supported.** |

Bootstrap: `brew install ubi` or `cargo install ubi`.

**Honest limitation:** ubi has no central manifest, so `list`/`outdated` are best-effort. Acceptable — same shape as the Go adapter.

### Wiring

- `ManagerID` gains `.pipx`, `.aqua`, `.ubi` (+ `displayName`, `iconName`, ecosystem per §3).
- `defaultRegistry()` includes all three.
- Default priority extended to 14 managers.
- CLI passthrough: `gimme pipx/aqua/ubi <args>`.
- `ManagerID.ecosystem`: pipx → `.python`, aqua → `.system`, ubi → `.system`.
- UI badge colors: pipx = `.teal`, aqua = `.mint`, ubi = `.brown`.

---

## 8. GUI Surface

Follows the AGENTS.md navigation policy (sidebar = root nav, no back button; details = sheet with close).

### New "Consolidate" sidebar section

```
├─ Consolidate       icon: "arrow.triangle.merge"
```

**Consolidate view:**
- Header: "Consolidation report" + a Refresh button + count ("N duplicates found" or "No duplicates ✅").
- For each ecosystem with duplicates: a section listing each `Duplicate` as a card — name, the managers that have it (as badges), the recommended one (highlighted), and the exact commands to run (read-only, selectable text). A "Copy commands" button per card.
- Clean ecosystems: collapsed summary line each.
- The whole report is **read-only** — no buttons that perform migration (per "report + guide"). The user copies commands or runs them in Terminal.

### Per-package detail sheet (existing) — small addition

If the opened package is part of a duplicate, show a "⚠ Also installed via: [npm], [pnpm]" line with a hint to run `gimme consolidate`.

### Ecosystem preferences in Preferences tab

The existing Preferences tab gains an "Ecosystems" section — one picker per ecosystem showing its managers, bound to `config.ecosystemPreferences`. Changing it updates the consolidation recommendation live.

---

## 9. Testing Strategy

- **`Ecosystem` tests** — every `ManagerID` maps to the expected ecosystem; `Ecosystem.managers` is the inverse; `other` is non-empty-safe.
- **`Consolidator` tests (the core)** — pure, with synthetic `[InstalledPackage]`:
  - Same name + same ecosystem across 2 managers → duplicate.
  - Same name + different ecosystems → not a duplicate.
  - 3+ managers → one duplicate with all three in `installed`.
  - Recommended manager honored from preferences; default when unset.
  - `installCommand` omitted when recommended already has the package.
  - Clean report when no duplicates; `cleanEcosystems` populated.
- **`EcosystemPreferences` tests** — TOML round-trip under `[ecosystems]`; default fallback to `ecosystem.managers.first`.
- **`config set ecosystem.*` validation** — rejects cross-ecosystem assignment.
- **Adapter tests (pipx/aqua/ubi)** — same pattern as existing adapters: stubbed Process + HTTP, binary override injection so tests don't depend on the dev machine.
- **CLI tests** — `gimme consolidate` formatting (human + `--json` schema); clean-report path.

---

## 10. Out of Scope (v1)

- **Auto-migration** (`gimme consolidate --apply`). Report + guide only for v1.
- **Cross-ecosystem duplicate detection.** `ripgrep` in Homebrew vs Cargo is not flagged.
- **aqua's declarative yaml model** as a first-class gimmie concept. Adapter uses the imperative flow.
- **ubi install tracking via gimmie state.** List is best-effort scan (v1); a tracked-install-state follow-up could make it exact.
- **Per-package registry-tag-based ecosystems.** Fixed buckets only.

---

## 11. Build Sequence (high-level — detailed plan to follow)

1. **Ecosystem model** — `Ecosystem` enum + `ManagerID.ecosystem` extension + tests.
2. **Three new adapters** — pipx, aqua, ubi (each TDD, same pattern as existing adapters).
3. **Wire new managers** — `ManagerID` cases, registry, priority, passthrough, UI colors, doctor.
4. **`EcosystemPreferences` + Config** — new config field, TOML `[ecosystems]` table, `config set/show` verbs.
5. **`Consolidator`** — pure logic + the report/steps types, fully tested with synthetic input.
6. **`gimme consolidate` CLI** — wiring into the dispatcher, human + `--json` output.
7. **GUI Consolidate tab** — new sidebar section, report cards, ecosystem pickers in Preferences, duplicate hint in detail sheet.
