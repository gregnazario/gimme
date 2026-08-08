# gimmie v2 — Orchestrator Design

**Status:** Approved (design interview complete)
**Date:** 2026-08-07
**Supersedes:** the entire native-pipeline architecture (manifests, TOML, Lua, cellar, stager, downloader, taps, cask installer, mise interop)

---

## 1. Purpose

gimmie is an all-in-one global package management system for macOS. It is a **pure orchestration layer**: it does not download, stage, build, or shelve anything itself. It drives real package managers (Homebrew, Go, uv, Cargo, bun) through a uniform interface, presenting them to the user as a single unified namespace.

gimmie ships as native Swift with two faces:

- a **CLI** (`gimme`) — flat verbs plus per-manager passthrough;
- a **SwiftUI macOS app** (`GimmeUI`) — rebuilt fresh around the orchestration layer.

Both faces share one engine (`GimmeCore`). There is no IPC boundary.

---

## 2. Decisions (locked during design interview)

| # | Decision | Choice |
|---|---|---|
| 1 | Existing native pipeline (manifests, TOML, Lua, cellar, stager, downloader, taps, cask installer) | **Delete entirely.** Pure orchestration. |
| 2 | Package addressing | **Unified namespace** — `gimme install <name>`. |
| 3 | Conflict resolution (name on multiple managers) | **Priority list + remember per-package.** |
| 4 | Managers in v1 | Homebrew, Go, uv (Python), Cargo, bun (npm). |
| 5 | Python model | **uv tool** — per-tool isolated venvs (pipx-style). |
| 6 | Nix | **Defer to v2.** Protocol designed so nix can slot in later. |
| 7 | CLI shape | **Flat verbs + passthrough** (`gimme brew <args>`). |
| 8 | Search | **Default-manager by default; `--all` opts into cross-manager fan-out.** |
| 9 | Missing managers | **Auto-bootstrap** — offer to install the backend, then proceed. |
| 10 | State | **Live query + TTL cache.** Never drifts; fast on repeat use. |
| 11 | GUI | **Full rebuild** of the SwiftUI app. |
| 12 | Backward compatibility | **Break freely.** Pre-1.0, no migration paths. |
| 13 | Backend I/O | **Best source per manager** (brew JSON API, Go proxy, PyPI, crates.io, npm registry; CLI where no machine API exists). |
| 14 | Core architecture | **Thin engine, fat adapters.** Small shared core; self-contained adapters each own their I/O. |

---

## 3. Architecture

### 3.1 Thin engine, fat adapters

The shared engine (`GimmeCore`) is deliberately small. It contains:

- the `PackageManager` protocol and shared types;
- the `Registry` (discovers and holds manager adapters);
- the `Resolver` (priority-list + remembered-prefs routing);
- the `Preferences` store (per-package remembered overrides);
- the `Cache` (TTL disk cache for live-query results);
- shared `Process` helper (streaming subprocess execution);
- shared `Bootstrap` runner;
- `Config`, `Paths`, `Host`, `Errors`.

The engine **never knows how** a manager installs things. It calls `manager.install(pkg)` and consumes the result. This avoids the leaky-abstraction failure mode where a generalized engine fills with `if manager == .go` branches — the exact scattered-logic mess the v1 codebase had, just relocated.

Each adapter is self-contained and owns its I/O strategy. "Best source per manager" (decision 13) means adapters are already bespoke by necessity; keeping the engine thin matches that reality.

### 3.2 Three seams

1. **`PackageManager` protocol** — every backend conforms. The single interface the engine and UI talk through.
2. **`Registry`** — discovers which managers are available (installed on the system), holds their adapter instances, exposes them by ID. The UI's "System"/"By Manager" view and `gimme doctor` read from here.
3. **`Resolver`** — given a package name, returns the manager to use (consults remembered prefs, then the priority list, filtering to managers that have the package).

### 3.3 Target layout (SwiftPM, single workspace)

```
Package.swift
Sources/
  GimmeCore/
    PackageManager.swift          # protocol + shared types (PackageRef, InstalledPackage, …)
    Registry.swift                # discovers + holds all manager adapters
    Resolver.swift                # priority-list + remembered-prefs routing
    Preferences.swift             # per-package "remember" store (TOML)
    Cache.swift                   # TTL disk cache for list/outdated/info
    Process.swift                 # shared subprocess helper (streaming, exit codes)
    Bootstrap.swift               # shared installer-runner for auto-bootstrap
    Config.swift                  # gimme config (priority list, enabled managers, cache TTL)
    Paths.swift, Host.swift       # kept from v1, trimmed
    Errors.swift                  # unified error types
    managers/
      HomebrewManager.swift       # fat adapter: brew JSON API + CLI
      GoManager.swift             # fat adapter: module proxy + `go install`
      UvManager.swift             # fat adapter: `uv tool install/list/upgrade`
      CargoManager.swift          # fat adapter: `cargo install --list` parse
      BunManager.swift            # fat adapter: `bun install -g` + JSON
  gimme/        # CLI (rebuilt: flat verbs + passthrough)
  GimmeUI/      # SwiftUI (rebuilt fresh around the protocol)
Tests/GimmeTests/  # protocol conformance tests + per-adapter tests
```

### 3.4 Target count

`Package.swift` drops from **6 targets to 3** (plus tests): `GimmeCore`, `gimme`, `GimmeUI`. The two C targets (`GimmeLua`, `CGimmeLuaSupport`) are removed along with the Lua engine.

### 3.5 What gets deleted

Gone entirely: `manifest/` (Formula, Asset, TOML, Strategy, ManifestLoader), `installer/` (the staged Installer), `downloader/`, `stager/`, `cellar/`, `shim/`, `taps/`, `mise/` (interop existed for the native pipeline), `agent/`, the vendored `GimmeLua` + `CGimmeLuaSupport` C targets, `taps/gimme-core/` (the bundled tap), and the cask DMG installer. `SystemManagers.swift` is replaced by `Registry.swift`. Roughly **half the current codebase** is removed.

### 3.6 Data flow (example: `gimme install ripgrep`)

```
CLI parses "install ripgrep"
  → Resolver.resolve("ripgrep", hint: nil)
       1. hint nil → skip
       2. Preferences.remembered("ripgrep") → nil → skip
       3. Config.priorityList = [brew, cargo, go, uv, bun]
          concurrently existence-check all priority managers (TaskGroup)
          among those that HAVE "ripgrep" → [brew, cargo]
          highest-priority → brew
       returns HomebrewManager
  → engine precondition: Homebrew.isAvailable()? yes → proceed
       (if no → Bootstrap flow: prompt, install brew, re-check)
  → Homebrew.install("ripgrep")  [brew JSON API for metadata, `brew install` for action]
  → stream progress to CLI/GUI
  → on success: Cache.invalidate("homebrew:list")
       (no preference recorded — no --from was used)
```

With `gimme install --from cargo ripgrep`, step 1 wins, cargo installs it, and on success `Preferences.remember("ripgrep", .cargo)` records the override.

---

## 4. The `PackageManager` Protocol

The contract every backend conforms to.

```swift
public protocol PackageManager {
    /// Stable identifier ("homebrew", "go", "uv", "cargo", "bun").
    var id: ManagerID { get }
    /// Human name + SF Symbol for the GUI.
    var displayName: String { get }
    var icon: String { get }            // SF Symbol name

    // — Capability discovery (not all managers support everything) —
    var capabilities: Set<Capability> { get }

    // — Presence & bootstrap —
    func isAvailable() -> Bool          // is the backend installed?
    func bootstrap() async throws       // install the backend itself (auto-bootstrap)

    // — Package operations —
    func install(_ package: PackageRef, options: InstallOptions) async throws -> InstallResult
    func uninstall(_ package: PackageRef) async throws
    func upgrade(_ package: PackageRef) async throws
    func listInstalled() async throws -> [InstalledPackage]
    func outdated() async throws -> [OutdatedPackage]
    func search(_ query: String) async throws -> [SearchHit]
    func info(_ package: PackageRef) async throws -> PackageInfo
}
```

### 4.1 Supporting types

```swift
public enum Capability: String {
    case install, uninstall, upgrade, list, outdated, search, info, bootstrap
}

public enum ManagerID: String, Hashable, Codable {
    case homebrew, go, uv, cargo, bun
}

public struct PackageRef: Hashable {
    public let name: String             // "ripgrep", "github.com/spf13/cobra", "@babel/core"
    public let managerHint: ManagerID?  // set when user used --from
}

public struct InstalledPackage: Identifiable {
    public let id: String               // manager-namespaced: "homebrew:ripgrep"
    public let name: String
    public let version: String
    public let manager: ManagerID
    public let installedAt: Date?
}

public struct OutdatedPackage: Identifiable {
    public let id: String               // manager-namespaced
    public let name: String
    public let installedVersion: String
    public let latestVersion: String
    public let manager: ManagerID
}

public struct SearchHit: Identifiable {
    public let id: String               // manager-namespaced
    public let name: String
    public let manager: ManagerID
    public let summary: String
    public let latestVersion: String
}

public struct PackageInfo {
    public let name: String
    public let manager: ManagerID
    public let latestVersion: String
    public let summary: String
    public let homepage: String?
    public let license: String?
    public let installedVersion: String?  // nil if not installed
    public let location: String?          // path on disk, if installed
}

public struct InstallOptions {
    public let version: String?         // pin to a specific version if supported
    public let yes: Bool                // non-interactive (skip prompts)
}

public struct InstallResult {
    public let package: InstalledPackage
    public let warnings: [String]       // e.g. "library package — no CLI entry"
}
```

### 4.2 Design points

1. **`PackageRef` carries an optional `managerHint`.** This is how `--from cargo` flows through the system — attached at the CLI boundary, honored by the Resolver, recorded as a remembered preference on success.

2. **`capabilities` is explicit.** Not every backend supports every operation. Go has no reliable `outdated` and no fuzzy `search`; the protocol does not pretend otherwise. The UI greys out unsupported actions per-manager.

3. **Everything is `async throws`.** Backends do real I/O. Concurrency is first-class; the resolver's existence checks run concurrently via a `TaskGroup`.

4. **Manager-namespaced IDs.** `InstalledPackage.id` is `"homebrew:ripgrep"`. The unified list never collides even when a name exists on two managers — `rg` on both brew and cargo shows as two distinct entries.

5. **`isAvailable()` before every operation.** The engine's single piece of wrapper logic: a thin precondition that triggers the Bootstrap flow when a manager is missing. Not a thick orchestration layer.

---

## 5. Resolver, Preferences, Cache

### 5.1 Resolver — `resolve(_ name:hint:)` algorithm

```
func resolve(_ name: String, hint: ManagerID?) -> ResolvedManager?
  1. If hint provided (--from X):
       verify X is available + has the package → return X
       else: error "X has no package '<name>'" (with alternatives if known)
  2. Else check Preferences.remembered(for: name) → if set & manager available → return it
  3. Else walk Config.priorityList (only managers that are available/installed):
       concurrently existence-check all available priority managers (TaskGroup)
       among those that HAVE the package, pick the highest-priority one
       return it
  4. If none have it → return nil ("no manager has '<name>'")
```

**Semantics:**

- **Existence check is exact-match, not fuzzy.** "Does manager X have a package *named* `ripgrep`?" — a cheap lookup against each manager's best source. Full fuzzy search is a separate, user-facing `gimme search` operation. This keeps the resolver fast and unambiguous.

- **Step 3 fans out concurrently, then applies priority ordering.** All priority managers are checked at once via a `TaskGroup`; the highest-ranked hit wins. Wall-clock latency is bounded by the slowest single check rather than the sum. The cache (below) makes repeated resolves cheap. *(Decision: concurrent fan-out, not sequential-with-early-exit — chosen for latency.)*

- **Remembered pref pointing to an unavailable manager falls back gracefully.** If you remembered `rg → cargo` but uninstalled rustup, the resolver skips it, falls through to the priority list, and the CLI prints a one-line notice: *"cargo no longer available; used homebrew instead."*

- **`--from` always wins and triggers remembering.** Explicit user intent overrides everything. On successful install via `--from X`, `Preferences.remember(name, X)` is called — **only** on explicit `--from`, never on a silent priority pick. This keeps remembered prefs signal-rich.

### 5.2 Preferences — the remembered-overrides store

Location: `~/.config/gimme/preferences.toml`

```toml
[overrides]
ripgrep = "cargo"
esbuild = "bun"
"github.com/spf13/cobra" = "go"
```

- **Separate from config.** `config.toml` holds the priority list + enabled managers (global setup). `preferences.toml` holds only per-package learned overrides. Splitting them means "reset my package choices" (`gimme forget --all`) doesn't touch priority config.
- **Operations:** `remember(name, manager)`, `forget(name)`, `forgetAll()`, `remembered(for:) -> ManagerID?`.
- **CLI verbs:** `gimme forget <name>` (clear one), `gimme forget --all` (clear all). Mirrored in the GUI as a per-package menu action and a "Forget all" in Preferences.
- **Keys use the raw package name** as the user typed it — including Go's `github.com/owner/repo` form. Names are namespaced to their manager implicitly via the override value, so no cross-manager collision.

### 5.3 Cache — live query + TTL

- **Source of truth is always live.** Gimmie never trusts a cache over querying the real manager for `list`/`outdated`/`info` *when the cache is stale*. The cache only avoids re-querying within its TTL window.

- **Disk-backed, keyed by `manager:operation`:**

  ```
  ~/.cache/gimme/
    homebrew:list.json        (TTL: 5 min)
    homebrew:outdated.json    (TTL: 5 min)
    cargo:list.json           (TTL: 5 min)
    homebrew:info:ripgrep.json (TTL: 1 hour)
    ...
  ```

- **Per-operation TTLs.** `list`/`outdated` are short (5 min) since they change when you install things; `info`/`search` are longer (1 hour) since package metadata rarely shifts. Tunable in config.

- **Invalidation on write.** After any `install`/`uninstall`/`upgrade`, the affected manager's `list` (and `outdated`) cache entries are invalidated immediately — gimmie won't show a stale list right after you changed it.

- **Bypass flags.** `--refresh` (force re-query, ignore cache; still writes fresh results) and `--no-cache` (don't read *or* write). The GUI exposes a "Refresh" button on each list view.

- **In-process vs cross-process.** CLI processes are short-lived, so an in-memory cache only helps within a single invocation (e.g., `gimme outdated` fanning out across 5 managers doesn't re-query brew twice). The disk cache is what makes cross-invocation speed (running `gimme list` twice in a row) fast.

---

## 6. The Five Adapters

Each adapter is fat — it owns its I/O strategy. All conform to `PackageManager`.

### 6.1 Homebrew (`homebrew`)

**Best source:** official JSON. `brew info --json=v2 <pkg>` for metadata; the `formulae.brew.sh` API (static JSON) for search/list without a local clone. Brew CLI for actions.

| Op | How |
|---|---|
| `search` | Query `formulae.brew.sh/api/formula.json` and `cask.json` — single JSON blobs of all packages; filter in-memory by name. Fast, no `brew search` subprocess. |
| `info` | `brew info --json=v2 <name>` (local, accurate) with API fallback. |
| `list` | `brew list --json=v2` (installed kegs + casks). |
| `outdated` | `brew outdated --json=v2`. |
| `install` | `brew install <name>` (formula) / `brew install --cask <name>` (GUI app). |
| `uninstall` | `brew uninstall <name>`. |
| `upgrade` | `brew upgrade <name>`. |

- **Casks are first-class.** A cask is just another package on the `homebrew` manager — `info` returns `kind: .formula` or `.cask`. The unified namespace treats them identically; the GUI shows a "GUI app" badge.
- **Capabilities:** full set.
- **Bootstrap:** `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`.
- **Quirk:** third-party `brew tap` is Homebrew-specific — punt to the passthrough (`gimme brew tap ...`). Not modeled in the unified layer in v1.

### 6.2 Go (`go`)

**Best source:** the module proxy at `proxy.golang.org`. There is no "package index"; packages are import paths, but the proxy gives version + existence info.

| Op | How |
|---|---|
| `search` | **No native fuzzy search.** Use the proxy's `@latest` endpoint as an existence check. `search` for Go returns a single exact-match hit or nothing. The user supplies a full import path (`gimme install github.com/spf13/cobra`). |
| `info` | `GET proxy.golang.org/<path>/@latest` → version; `@v/list` → versions. |
| `list` | Scan `$GOPATH/bin` (or `go env GOBIN` / `GOBIN`) — list binaries installed there. Go has no central manifest of installed tools; filesystem scan is the source of truth. |
| `outdated` | **Not supported in v1.** For each binary in GOBIN we don't reliably know its source import path, so we can't compare to upstream. The GUI shows Go tools without an "update available" badge. |
| `install` | `go install <import-path>@latest`. |
| `uninstall` | `rm $GOBIN/<binary>` (Go provides no uninstall command). Gimmie verifies the target is in GOBIN before deleting. |

- **Package names are import paths.** `github.com/spf13/cobra`, `golang.org/x/tools/gopls`. `PackageRef.name` carries the full path.
- **Capabilities:** `[install, uninstall, list, info, bootstrap]`. Notably **no `outdated`** and **no fuzzy `search`** (exact-existence only).
- **Bootstrap:** download from `go.dev/dl/` (official installer); or `brew install go` if Homebrew is present (preferred, faster path).

### 6.3 uv / Python (`uv`)

**Best source:** the `uv` CLI — clean, parseable output, source of truth for its own state. PyPI's JSON API (`pypi.org/pypi/<name>/json`) for search/info across the Python ecosystem.

| Op | How |
|---|---|
| `search` | Query PyPI via the JSON API. |
| `info` | PyPI JSON API → version, summary, homepage. |
| `list` | `uv tool list` (installed isolated tools). |
| `outdated` | For each `uv tool`, compare installed version to PyPI latest. Supported. |
| `install` | `uv tool install <pkg>` → isolated venv per tool, console script on PATH. |
| `uninstall` | `uv tool uninstall <pkg>`. |
| `upgrade` | `uv tool upgrade <pkg>`. |

- **Model: per-tool isolated (`uv tool`).** No global venv, no user-named venvs. The pipx model, done right.
- **Capabilities:** full set.
- **Bootstrap:** `curl -LsSf https://astral.sh/uv/install.sh | sh` (official).
- **Quirk:** some Python packages are libraries, not CLI tools (e.g. `requests` — no console script). Gimmie still installs them via `uv tool`; the GUI marks them "library — no CLI entry." Not forbidden; uv's isolation makes it harmless.

### 6.4 Cargo (`cargo`)

**Best source:** crates.io JSON API for search/info; `cargo` CLI for actions + list.

| Op | How |
|---|---|
| `search` | `crates.io/api/v1/crates?q=<query>` (JSON, paginated). |
| `info` | `crates.io/api/v1/crates/<name>` → version, description, downloads. |
| `list` | `cargo install --list` (parses the `name v1.2.3:` lines). |
| `outdated` | For each installed crate, compare to crates.io latest. Supported. |
| `install` | `cargo install <name>`. |
| `uninstall` | `cargo uninstall <name>`. |
| `upgrade` | `cargo install <name> --force` (Cargo has no `upgrade`; reinstall to latest). |

- **Capabilities:** full set; `upgrade` is a re-install under the hood (documented in the adapter).
- **Bootstrap:** `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh` (rustup, which provides cargo).
- **Quirk:** build time can be long (Rust compiles from source) — progress streaming matters; the adapter streams cargo's stderr live so the user sees compile progress.

### 6.5 Bun / npm (`bun`)

**Best source:** npm registry JSON (`registry.npmjs.org`) for search/info; `bun` CLI for actions.

| Op | How |
|---|---|
| `search` | npm registry's search endpoint (`registry.npmjs.org/-/v1/search?size=25&q=<query>`, JSON). |
| `info` | `registry.npmjs.org/<name>` (full packument) or `registry.npmjs.org/<name>/latest`. |
| `list` | `bun pm ls -g` (parse global packages). |
| `outdated` | Compare each global package to `registry.npmjs.org/<name>/latest`. Supported. |
| `install` | `bun install -g <name>`. |
| `uninstall` | `bun remove -g <name>`. |
| `upgrade` | `bun install -g <name>` (npm semantics — reinstall to latest). |

- **Capabilities:** full set; `upgrade` is a re-install.
- **Bootstrap:** `curl -fsSL https://bun.sh/install | bash` (official).
- **Quirk:** scoped names (`@types/node`, `@babel/core`) — `PackageRef.name` preserves the scope; the resolver and registry handle scoped names transparently.
- **Naming:** the adapter is named `bun` in the registry (not `npm`) — it reflects the actual tool driving the install. The GUI shows "npm (via bun)".

### 6.6 Cross-cutting adapter concerns

- **Progress streaming.** Long operations (cargo compile, large brew installs) stream stdout/stderr line-by-line to the CLI and to the GUI's activity view. This is a shared `Process` helper (in the engine), not duplicated per adapter — adapters opt in via `process.run(streaming: true)`.
- **Auto-bootstrap flow.** Every adapter's `bootstrap()` is a real install of the backend tool. Engine precondition: if `!manager.isAvailable()`, prompt the user (`<name> requires <manager>. Install it? [Y/n]`), run `bootstrap()`, re-check availability, then proceed. Refusing aborts cleanly.
- **Network failure vs not-found.** Each adapter distinguishes "package not found" (clean `nil`/error the resolver can route around) from "network down" (retryable error surfaced to the user). The resolver's concurrent fan-out tolerates individual manager failures — one manager timing out doesn't block the others.

---

## 7. CLI Surface (`gimme`)

Flat verbs + passthrough. Rebuilt from scratch.

### 7.1 Core verbs (unified namespace)

```
gimme install <name> [--from <manager>] [--version <v>]
gimme uninstall <name>
gimme upgrade <name>
gimme update                                  # upgrade ALL outdated, across every manager
gimme list [--from <m>]                       # default: every manager's installed packages; --from filters to one
gimme outdated [--from <m>]                   # default: every manager's outdated packages; --from filters to one
gimme search <query> [--all]                  # default: priority-default manager; --all fans out across managers
gimme info <name>
```

### 7.2 Preference + config verbs

```
gimme forget <name>
gimme forget --all
gimme config
gimme config set priority brew,cargo,go,uv,bun
gimme doctor
```

### 7.3 Global flags

```
--from <manager>    # force a specific backend (records a remembered pref on success)
--refresh           # bypass cache read; still writes fresh results
--no-cache          # don't read or write cache
--version, -v
--help, -h
--json              # machine-readable output for list/outdated/search/info
```

### 7.4 Passthrough (raw escape hatch)

```
gimme brew <args...>     # forwards argv verbatim to `brew`
gimme cargo <args...>
gimme go <args...>
gimme uv <args...>
gimme bun <args...>
```

Anything after the manager name is forwarded as-is. `gimme brew services start postgres` runs exactly as `brew services start postgres`. Gimmie does not parse or model it.

### 7.5 Output conventions

- Human format by default (columns, color when TTY).
- `--json` on `list`/`outdated`/`search`/`info` → machine-readable JSON (stable schema) for scripting.
- Manager shown as a colored tag in listings: `[brew] ripgrep 14.1.0`.

---

## 8. GUI Surface (SwiftUI, rebuilt)

`GimmeApp` + a new `GimmeStore` (`ObservableObject`) talking **only** through `Registry`/`Resolver`. The old `ContentView` (1000+ lines, brew-coupled) is replaced with a modular view structure — one file per major view, not a monolith.

### 8.1 Navigation

`NavigationSplitView`, two-pane by default.

```
Sidebar                          Main
├─ All Installed                 [unified list, every manager]
├─ Updates Available             [outdated across managers, "Update All"]
├─ Browse                        [search → default manager, toggle "all managers"]
├─ By Manager ▼                  [expandable: brew / go / uv / cargo / bun]
│   ├─ Homebrew
│   ├─ Go
│   └─ ...
├─ Preferences                   [priority reorder, cache settings, remembered overrides]
└─ Activity                      [live operation log + progress]
```

### 8.2 Key views

- **All Installed** — flat list of `InstalledPackage` (manager-namespaced IDs, so `ripgrep` shows twice if it's on both brew and cargo). Filter chips per manager. Click → detail.
- **Updates Available** — outdated packages across all managers; a prominent **Update All** runs upgrades concurrently per manager. Per-row "Update" too.
- **Browse** — unified search box. Default: searches the priority-default manager (fast). Toggle "Search all managers" → fan-out, results grouped by source with colored tags. Click a result → detail sheet with Install button.
- **By Manager** — collapsible sections, one per available manager (greyed out if unavailable, with an "Install <manager>" bootstrap button). Each shows that manager's installed packages.
- **Preferences** — drag-to-reorder priority list; enable/disable managers (skips them in resolution); cache TTL sliders; list of remembered overrides with per-row "Forget" buttons.
- **Activity** — append-only log of every operation with timestamps, streaming progress for in-flight operations.

### 8.3 Detail sheet (installed and browseable packages)

- Name, description, current/latest version, manager (with icon), source link.
- Installed location on disk + "Reveal in Finder" / "Open in Terminal".
- Actions: Install / Uninstall / Upgrade (greyed if `capabilities` doesn't include the op).
- Manager badge + "remembered preference" indicator.

### 8.4 Concurrency model in the store

All backend operations run on a background `Task`; progress streams into `@Published` state on the main actor. The store holds the `Registry` and `Resolver` as plain values (not `@Published` — they're not UI state). Errors surface as alerts via a shared `.alert` modifier.

### 8.5 `gimme doctor` (shared CLI + GUI)

Both CLI `gimme doctor` and the GUI's "By Manager" / Preferences surface the same health info from the `Registry`:

- Each known manager: installed? version? on PATH?
- Missing managers → bootstrap button (GUI) / one-line install command (CLI).
- Cache status, config file locations.

---

## 9. Error Handling

- **Unified `GimmieError` type** with cases: `notFound(name, searchedManagers)`, `managerUnavailable(ManagerID)`, `bootstrapFailed(ManagerID, underlying)`, `operationFailed(manager, op, underlying)`, `networkFailure(retryable: Bool)`, `configError(String)`.
- **Resolver "not found" carries context.** `notFound("ripgrep", searchedManagers: [.brew, .cargo, ...])` so the CLI can say *"no manager has 'ripgrep'; searched: homebrew, cargo, go, uv, bun"* rather than a bare error.
- **Bootstrap refusal is clean.** Declining the auto-bootstrap prompt aborts the operation with a clear message and a one-line manual install command, not an error code.
- **Partial failures in `gimme update` (update all).** When upgrading across managers and one manager fails, the others still complete; the summary reports per-manager success/failure.

---

## 10. Testing Strategy

- **Protocol conformance tests** — a shared test suite parameterized over `[any PackageManager]`, asserting each adapter satisfies the protocol contract (e.g., `list` returns packages after `install`; `uninstall` removes them; `outdated` only includes packages actually outdated). Catches cross-adapter inconsistencies.
- **Per-adapter tests** — each adapter tested against stubbed network/subprocess: mock the brew JSON API, crates.io, PyPI, npm registry, Go proxy; mock the subprocess layer for `brew install`/`cargo install`/etc. No real network or real installs in CI.
- **Resolver tests** — priority ordering, remembered-pref override, `--from` winning, graceful fallback when a remembered manager is unavailable, concurrent fan-out correctness.
- **Preferences/Cache tests** — TOML round-trip, TTL expiry, invalidation on write, `--refresh`/`--no-cache` behavior.
- **CLI integration tests** — argv parsing for every verb and flag, passthrough forwarding, `--json` output schema, `doctor` output. In-process (call `Gimme.run` like the existing tests do).
- **GUI:** no automated tests in v1 (matches current state — `GimmeTests` depends only on `GimmeCore`). Manual verification via the rebuilt app.

---

## 11. Phased Build Sequence

This is the recommended implementation order; the implementation plan (next step) will detail each phase.

1. **Delete the native pipeline.** Remove the targets, directories, and code listed in §3.5. Get the trimmed workspace compiling (Core + CLI stub + UI stub). This is the foundation — do it first so nothing built on top references dead code.
2. **Core types + protocol.** `PackageManager.swift`, all shared types (`PackageRef`, `InstalledPackage`, `OutdatedPackage`, `SearchHit`, `PackageInfo`, `InstallOptions`, `InstallResult`, `Capability`, `ManagerID`), `Errors.swift`, trimmed `Paths`/`Host`/`Config`.
3. **`Process` helper + `Bootstrap` runner.** Shared subprocess execution with streaming; the bootstrap prompt/confirm/run flow.
4. **First adapter: Homebrew.** Build one complete fat adapter end-to-end as the reference implementation. Exercise every protocol method. This proves the protocol shape.
5. **`Registry` + `Resolver` + `Preferences` + `Cache`.** The orchestration brain. Wire Homebrew into the Registry and test the full resolve → install → cache-invalidate loop.
6. **Remaining adapters.** Go, uv, Cargo, bun — each following the Homebrew reference pattern.
7. **CLI rebuild.** Flat verbs, passthrough, flags, `--json`, `doctor`.
8. **GUI rebuild.** Modular views, `GimmeStore` rewired, all sections.
9. **Cross-cutting polish.** Progress streaming wired to GUI Activity view, partial-failure handling in `update`, error messages with searched-managers context.

---

## 12. Out of Scope (v1)

- **Nix** (deferred to v2; protocol designed to accept it).
- **MacPorts, volta/fnm, rubygems.** Not in v1.
- **Go `outdated` and fuzzy `search`.** Exact-existence only.
- **GUI automated tests.**
- **Third-party `brew tap` modeling** in the unified layer (passthrough only).
- **Migration paths** from the v1 native pipeline (pre-1.0, break freely).
- **Per-project / per-directory manager pinning** (gimmie is global package management).
- **A TUI.**
