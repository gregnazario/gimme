# gimme — Foundation Design

**Status:** Approved (2026-08-03)
**Scope:** Foundation subsystem only. Source builds, Homebrew compatibility, GUI app, and MCP server are explicitly out of scope (see Non-goals).

---

## 1. Overview

`gimme` is a Swift-based package manager for macOS that supports source-based and download-based installation. It has a native UI app and a CLI. Tools are described by **formulae**, which combine a typed declarative manifest with sandboxed Lua logic.

The user-facing signature is the shortcut:

- `gimme git` — install `git` if missing, update if stale, no-op if current or pinned.
- `gimme rustup` — same.

This spec defines the **foundation**: the core engine, the formula format, version resolution, the install pipeline, the CLI (with a first-class AI-agent contract), and the testing/error model. Source builds, Homebrew compatibility, the GUI app, and an MCP server are deferred follow-on specs that this architecture is shaped to accommodate.

### Scope decomposition (for context)

The full `gimme` vision contains six subsystems. This foundation spec covers subsystem 1 and the interfaces the others will plug into:

1. **Core engine** — formula loading, dependency resolution, install orchestration, version/latest resolution, the cellar, PATH management. ← **This spec.**
2. **Formula system** — manifest + Lua sandbox. ← **This spec.**
3. **CLI** — `gimme git` and subcommands. ← **This spec.**
4. **Source-based builds** — follow-on. Enum value reserved, not implemented.
5. **Homebrew compatibility** — follow-on. Formula abstraction shaped to receive translations.
6. **Native GUI app** — follow-on. Consumes `GimmeCore` directly or the `--json` contract.

### Build order

1. Core engine + formula format + CLI MVP ← **start here (this spec)**
2. Version management & "latest" resolution (covered in this spec)
3. Source-based builds (follow-on)
4. Homebrew compat layer (follow-on)
5. Native GUI app (follow-on)

---

## 2. Architecture & project structure

Single SwiftPM workspace, `gimme`, with targets:

| Target | Type | Responsibility |
|---|---|---|
| `GimmeCore` | library | The engine: manifest decoding, tap management, dependency resolver, version resolution, cellar, download/verify, sandbox runtime, install orchestration, state/receipts. Pure logic, no UI. |
| `gimme` | executable | The CLI. Built with Apple's `ArgumentParser`. Thin layer over `GimmeCore` — parses args, calls engine, formats output. |
| `GimmeLua` | library (vendored) | Lua 5.4 C sources + a thin Swift overlay exposing the sandboxed `ctx` API to formulae. Separate target so the Lua build is isolated. |
| `GimmeTests` | test | Unit + integration tests against fixtures. |
| `FormulaFixtures` | resource | A fake in-repo tap used by tests (local tarballs as "downloads"). |

**Future targets (not in this spec, reserving the shape):** `GimmeUI` (macOS SwiftUI app, links `GimmeCore`), `GimmeBrew` (Homebrew-compat translator, links `GimmeCore`).

### On-disk layout

```
~/.gimme/
  bin/                 # PATH shims (real executables); user adds this to PATH once
  cellar/<tool>/<ver>/ # one dir per installed version = the install prefix
  cache/<sha256>/      # content-addressed downloads (shared, dedup'd)
  taps/<name>/         # git clones of formula repos (core + user-added)
  staging/             # temp work dirs for in-flight installs
  state/               # installed.json (index), pinned.json, gimme.lock
  logs/
  config.toml
```

### Module boundaries inside `GimmeCore`

Each is a Swift type/namespace, independently testable:

- `TapStore` — clone/update/list taps, find formula by name across taps.
- `Formula` — manifest (`Codable` struct) + loader + version model.
- `Resolver` — dependency DAG + version selection.
- `Downloader` — fetch → cache, sha256 verify.
- `Stager` — temp work dir, runs declarative install steps or sandboxed Lua.
- `Cellar` — atomic install into versioned prefix, receipts.
- `ShimManager` — create/remove/rewrite PATH shims.
- `StateStore` — active versions, pins (the derived index).
- `Installer` — the orchestrator that wires the above into the install pipeline.

---

## 3. Formula format

Hybrid model: **typed manifest for data, sandboxed Lua for logic.**

### Manifest

Two accepted forms, same schema:

**A. `formula.toml` (preferred — portable, easy to author/review):**

```toml
[package]
name = "git"
desc = "Distributed version control system"
homepage = "https://git-scm.com"
license = "GPL-2.0-only"

[[version]]
ver = "2.40.0"
released = "2023-03-02"

[install]
strategy = "lua"          # or "steps", or "source" (reserved, not implemented)
script = "install.lua"    # path relative to formula dir; required iff strategy == "lua"

[[dep]]
name = "gettext"
ver = ">=0.21"            # semver range; optional

[[provides]]
bin = ["git", "git-receive-pack"]
```

**B. `formula.swift` (Swift literal)** — same fields, decoded via `@dynamicMemberLookup` builder for autocomplete and type-checking. **Generated/parsed, never executed.** This avoids the "running arbitrary Swift" problem entirely.

### Version assets

Per-version download declarations:

```toml
[[version.asset]]
arch = "arm64"            # matched against host
os   = "macos"
url  = "https://.../git-2.40.0-arm64.tar.gz"
sha256 = "abcd..."
```

### Livecheck (for "latest" discovery)

```toml
[livecheck]
strategy = "github-release"   # or "url-match", "lua", "none"
repo = "git/git"
regex = 'git-(\d+\.\d+\.\d+)'
```

### Install strategies

`[install].strategy` selects how the version gets from asset → cellar prefix:

- **`steps`** — declarative, no code. Engine runs these directly. Most binary-distribution formulae use only this. No sandbox needed.

  ```toml
  [[install.step]]
  extract = "${asset}"
  [[install.step]]
  copy = { from = "git-2.40.0", to = "${prefix}" }
  ```

- **`lua`** — when logic is required. Engine runs `install.lua` in the sandbox with the `ctx` API.

- **`source`** — build from source. **Out of scope for this spec** (follow-on), but the enum value is reserved so the format is forward-compatible.

### The Lua `ctx` sandbox API

```lua
function install(ctx)       -- required entry point
  local stage = ctx:download()      -- staged asset path; sha already verified
  local dir   = ctx:extract(stage)  -- tgz/tbz/zip auto-detected
  ctx:install_dir(dir .. "/bin")    -- move into ${prefix}/bin
  ctx:mkdir("${prefix}/share/man")
  ctx:set_provides({"git", "git-receive-pack"})
  local gettext = ctx:dep_path("gettext")  -- path to a resolved dependency
  local host = ctx:host()                  -- { os=..., arch=..., macos_version=... }
end
```

**Blocked by the sandbox (by construction):** `os.execute`, `io.popen`, `loadfile`, `require` of arbitrary modules, `os.getenv` beyond a whitelist, `debug.*`, raw `os.remove`/`io.open` outside the work prefix. Network is only `ctx:download()` against declared asset URLs — no raw socket access. File writes confined to the work dir + target prefix.

**Exposed by the sandbox:** the controlled `ctx` API above, basic Lua stdlib (`string`, `table`, `math`, string patterns), declared dependency paths via `ctx:dep_path`.

### Provenance

- Every `[[version.asset]]` **must** have `sha256`. Manifest decode fails otherwise.
- `gimme install` refuses on mismatch. `--insecure` (per-install) bypasses for power users and is loud about it.
- The manifest itself is integrity-checked against the tap's git commit (formula provenance = tap trust).

---

## 4. Version resolution & "latest"

### Version queries

| Query form | Meaning |
|---|---|
| `git` (no version) | Default version for `git` — "latest" by default, or the pinned version if pinned. |
| `git@2.40` | Constraint: any 2.40.x. Highest available matching is chosen. |
| `git@2.40.0` | Exact version. |
| `git@^2.40` / `git@>=2.40,<3` | SemVer range expressions. |

Resolution always picks the **highest version satisfying the query** that has a usable asset for the host (`os=macos`, `arch=arm64`/`x86_64`). If no asset matches the host → clear error ("git 2.40.0 has no darwin-arm64 build; available: …").

### Livecheck strategies

- **`github-release`** — hit `api.github.com/repos/<repo>/releases/latest`, parse the tag with `regex`.
- **`url-match`** — fetch a listing page, regex out version strings.
- **`lua`** — a sandboxed `livecheck(ctx)` function returning a version string.
- **`none`** (default if absent) — the formula is static: latest = highest version literally listed in the manifest. No network on `update --check`.

`gimme update --check` runs livechecks across installed formulae; `gimme update git` runs it for one. Results are cached (default 1h; configurable via `[cache].max_age_hours`) so `gimme list` doesn't hammer the network.

### SemVer

Vendored SemVer type in `GimmeCore` (parse, compare, range matching against `^`, `~`, `>=`, `<`, `*`). No external dependency. Pre-release tags (`2.40.0-rc1`) sort below their release. Formula authors opt into pre-releases with an explicit range (`>=2.40.0-rc`); the default query never selects a pre-release over a release.

### Dependency resolution

1. Resolver builds the dependency DAG from the top query.
2. For each dep, it queries the cellar first ("is an installed version already satisfying this?"), then available formula versions.
3. It picks the highest satisfying version; if a dep is already installed at a satisfying version, **reuse it** (don't reinstall).
4. Conflicts (two formulae needing incompatible ranges of a shared dep) → error with the conflicting chain, not a silent guess.

This is intentionally **simpler than a full SAT solver** (à la Cargo) — reuse-installed-first and pick-highest covers the vast majority of real cases. A real solver is a follow-on if it proves necessary; the `Resolver` interface is shaped so one can be swapped in.

### Host detection

`Host` struct resolved once at startup: `os` (`macos`), `arch` (`arm64`/`x86_64`), `macos_version` (for formulae that gate on OS version). Cached; formulae read it via `ctx:host()`.

### Resolution behavior for MVP commands

- `gimme git` → latest (or pinned) → highest host-matching version → resolve deps → install.
- `gimme git@2.40` → highest 2.40.x with host asset.
- `gimme update git` → run livecheck → if newer than installed, install it; old version kept in cellar, shims repointed.
- `gimme update --all` → above for every non-pinned installed formula.
- `gimme pin git` / `gimme pin git@2.40` → writes `pinned.json`; `git` queries now resolve to the pinned version, `update --all` skips it.
- `gimme use git 2.40.0` → repoints the active shim to an already-installed version (no download).

---

## 5. Install pipeline & state

Designed for **atomicity** (a failed install never leaves a half-installed tool) and **observability** (every install is reversible and auditable).

### The pipeline (one version, top to bottom)

```
resolve(query)
  → [Resolver] concrete (formula, version, asset) + dep plan
fetch(asset)
  → [Downloader] cache lookup by sha256; else download → verify sha256 → write to cache/<sha>
stage
  → [Stager] create temp work dir under ~/.gimme/staging/
  → run strategy:
      "steps" → engine executes declarative steps in work dir
      "lua"   → run install.lua in sandbox against work dir, ctx API only
prepare prefix
  → build the cellar prefix offline: ~/.gimme/cellar/git/2.40.0/
commit
  → atomic rename of staged prefix into cellar (rename is atomic on same volume)
  → write receipt.json into the prefix
activate
  → [ShimManager] (re)write ~/.gimme/bin/git shim pointing at this version
  → update state: installed.json[git].active = 2.40.0
```

**Failure handling at every stage:** anything before `commit` fails → delete the staging dir, leave the cellar and state untouched (previous version, if any, still active). Failure between `commit` and `activate` → the new version is in the cellar but not active; we roll `active` back to the prior version and surface the error. `commit` itself is the single atomic step (rename).

### Receipts (per-install audit record)

Every installed version dir gets `~/.gimme/cellar/git/2.40.0/RECEIPT.json`:

```json
{
  "formula": "git", "tap": "core", "version": "2.40.0",
  "installed_at": "2026-08-03T12:00:00Z",
  "asset": { "url": "...", "sha256": "abcd...", "arch": "arm64", "os": "macos" },
  "deps": [{ "name": "gettext", "version": "0.21", "resolved": "0.21.1" }],
  "gimme_version": "0.1.0",
  "source": "download"
}
```

`gimme uninstall`, `list`, and the dep resolver all read receipts. This is the source of truth — **not** a separate index that can drift. `installed.json` is a derived fast-index.

### State files (derived, rebuildable)

- **`~/.gimme/state/installed.json`** — `{ "git": { "active": "2.40.0", "installed": ["2.39.0","2.40.0"] }, ... }`. Derived from receipts on startup; if missing/corrupt, rebuilt by scanning the cellar. Never hand-edited.
- **`~/.gimme/state/pinned.json`** — `{ "git": "2.40.0" }`. Authoritative for pins (it's the user's intent, not derivable).

This split (receipts = truth, state = cache) means a corrupted index is never fatal — delete it and it rebuilds.

### Uninstall

`gimme uninstall git` → removes the **active** version's prefix, repoints shim to the next-highest installed version (or removes shim if none), updates state. `gimme uninstall git@2.39.0` removes a specific version. Receipts make this a directory delete + state update — no guesswork.

### Concurrency

A single `~/.gimme/state/gimme.lock` advisory file lock held for the duration of any mutating command (install/uninstall/update/pin/use). Read-only commands (`list`, `search`, `info`) don't lock. Prevents two parallel `gimme install` corrupting state; a stale lock (pid dead) is auto-recovered.

### Progress & output

CLI streams human-readable progress (`fetch → verify → stage → install → activate`) with a final summary line. A `--json` flag on every command emits structured output for the future GUI app to consume (the GUI will speak this JSON, not parse prose).

---

## 6. CLI surface & command model

Built on Apple's `ArgumentParser`. Designed so the GUI app can reuse the same command → engine calls (or just speak `--json`).

### Command tree

```
gimme                              # short help + `gimme list` if interactive
gimme <tool>[@version]             # INSTALL SHORTCUT (see below)
gimme install <tool>[@version]     # explicit install
gimme uninstall <tool>[@version]   # remove (active or specific version)
gimme update [<tool>]|[--all]      # update one or everything non-pinned
gimme use <tool> <version>         # switch active version (no download)
gimme pin <tool>[@version]         # pin to current or specific version
gimme unpin <tool>
gimme list [--all]                 # installed tools (or all known)
gimme search <term>                # search formulae across taps
gimme info <tool>                  # show formula details, versions, deps
gimme outdated                     # show installed tools with updates available
gimme tap <add|remove|list> <url>  # manage formula sources
gimme doctor                       # health check (PATH, permissions, receipts)
gimme config <get|set>             # read/write ~/.gimme/config.toml
gimme introspect                   # machine-readable CLI spec (agent contract)
```

### The `gimme <tool>` shortcut (signature UX)

`gimme git` does the right thing without subcommand ceremony:

| State of `git` | What `gimme git` does |
|---|---|
| Not installed | **Install** latest. |
| Installed, not pinned, update available | **Update** to latest. |
| Installed, not pinned, up to date | **No-op**, message "git 2.40.0 is current". |
| Installed, **pinned** | **No-op**, message "git is pinned at 2.40.0". |

`gimme git@2.40` follows the same logic but scoped to the 2.40.x line — if no 2.40.x installed, install highest 2.40.x; if installed and a higher 2.40.x exists, update to it.

Dispatch: "is the first non-flag argument a known tool name (no subcommand)?" → yes → shortcut mode. Ambiguity is resolved by reserving the subcommand verbs above; a tool literally named `install` would require `gimme install install`.

### Global flags

```
--json              # structured output for all commands (GUI + agent bridge)
--dry-run           # plan mutations without executing (agent contract)
--yes               # non-interactive confirm (machine mode)
--no-color          # disable color
--verbose / -v      # debug logging
--tap <name>        # restrict this command to one tap
--prefix <path>     # override ~/.gimme (testing/self-contained installs)
--version           # gimme version
```

`--prefix` is what makes the whole thing testable without touching the user's real `~/.gimme`.

### Exit codes

Deterministic for scripting. The exit code ↔ error category map is fixed and authoritative (the error model in section 8 and the agent contract in section 7 both rely on it):

| Exit | Category | Meaning |
|---|---|---|
| `0` | — | Success, including intentional no-op (e.g. "already current"). |
| `1` | `USAGE`, `NOT_FOUND` | Bad args, unknown tool/version, malformed query. |
| `2` | `INSTALL`, `NETWORK`, `CHECKSUM`, `PERMISSION` | Failure during fetch/verify/stage/activate. |
| `3` | `CONFLICT` | Unresolvable dependency/version conflict. |
| `4` | `LOCK` | Could not acquire the state lock (another gimme is running). |
| `70` | `UNKNOWN` | Internal/unexpected error (bug); always includes diagnostics under `--verbose`. |
| `64-79` | reserved | sysexits-style range; `70` is the only one assigned in the foundation. |

### Output conventions

- **Human output:** colored, prefixed status lines (`fetch ✓`, `verify ✓`, `install ✓ git 2.40.0`), final one-line summary.
- **`--json` output:** one JSON object per command to stdout, machine-consumable. Every response carries `schema_version`.

  ```json
  { "cmd": "install", "ok": true, "schema_version": 1, "tool": "git", "version": "2.40.0",
    "active": "2.40.0", "shim": "~/.gimme/bin/git", "duration_ms": 1240 }
  ```

### Configuration (`~/.gimme/config.toml`)

```toml
[behavior]
auto_update_check = true      # background livecheck freshness for `list`/`outdated`
prune_old_versions = false    # keep all versions vs auto-prune non-active

[cache]
max_age_hours = 1             # livecheck result freshness

[taps.core]
url = "https://github.com/gimme/core.git"
enabled = true
```

### First-run experience

`gimme` (no args) on first run: prints a one-time setup banner ("Add `~/.gimme/bin` to your PATH" with shell-specific instructions for zsh/bash/fish), runs `doctor`, and offers to bootstrap the core tap. Doesn't modify shell rc files — just instructs.

---

## 7. AI-agent interaction contract

The principle: **the CLI is a documented API, not just a human tool.**

1. **`--json` is first-class and complete.** Every command emits a single well-formed JSON object. Every JSON response carries a `schema_version` field so agents can pin and detect drift. Breaking changes bump the version.

2. **`gimme introspect`.** Emits the full machine-readable spec of the entire CLI — every subcommand, its positional args, flags (with types/defaults/constraints), exit codes, and the JSON output schema for each. An agent loads this once to know the whole surface without parsing prose. `gimme introspect --json` is canonical; supports `--command install` to scope it.

3. **`--dry-run` on every mutating command** (`install`, `uninstall`, `update`, `use`, `pin`, `tap`). Reports the plan as JSON: what would be fetched (url+sha), which deps resolved, what cellar/prefix/shim changes, any conflict — without executing. Agents plan and validate before acting.

4. **Non-interactive under `--json` / `--yes`.** Machine mode never blocks on a TTY prompt. Destructive or dependency-affecting actions (`uninstall` of a tool others depend on) return a structured error listing the dependents and a `--force` suggestion, exit non-zero — no hidden prompts.

5. **Bounded, filterable read output.** `list` / `search` / `info` / `outdated` take `--limit N`, `--fields a,b,c` (project specific fields in JSON), and `--query '<expr>'` (filter). Keeps payloads small and deterministic.

6. **Structured errors everywhere.** JSON error object:
   ```json
   { "ok": false,
     "error": { "code": "CHECKSUM_MISMATCH", "message": "...",
                "details": {}, "recoverable": false,
                "suggested": "gimme uninstall git && gimme install git" } }
   ```
   Exit code ↔ error category is a fixed, documented map. `suggested` lets an agent chain recovery.

7. **Consistent, exhaustive help.** `gimme <cmd> --help` (and `--help --json`) follows one template: usage, args, flags w/ types, exit codes, JSON schema, examples, related commands. Same data `introspect` exposes, per-command.

8. **Docs.** `docs/agent-interface.md` — a stable "CLI for agents" reference auto-generated from `introspect`, plus worked agent flows (install+verify, plan with dry-run, handle conflicts). README has an "AI agents" section pointing there.

9. **Reserved follow-on (not in this spec): `gimme mcp`** — a Model Context Protocol server exposing gimme as native tool calls. Trivial to build later because the `--json` contract + `introspect` already describe the surface; an MCP adapter is just a thin mapping.

Net effect: an AI agent can `gimme introspect --json`, plan with `--dry-run`, execute with `--json`, and recover from structured errors — all without scraping human prose or guessing at output shapes.

---

## 8. Testing, error model & non-goals

### Testing strategy

Four layers:

**1. Unit tests (`GimmeTests`)** — pure-logic modules in isolation, fast, no network, no filesystem writes to home:

- `SemVer` parsing/range matching (exhaustive cases including pre-releases).
- Manifest decode (`formula.toml` → `Formula` struct) — valid fixtures + rejection of malformed/missing-checksum.
- `Resolver` with mock taps + cellar — dependency reuse, conflict detection, host-asset filtering.
- Livecheck strategy parsing against recorded HTML/JSON fixtures (no network).
- `Receipt` round-trip; `StateStore` rebuild-from-cellar.
- Sandbox API surface (Lua `ctx` calls return expected values; blocked stdlib calls are actually blocked).

**2. Integration tests (`GimmeTests`, `--prefix` to temp dir)** — full pipeline against a temp `~/.gimme`:

- A vendored fake tap (`FormulaFixtures`) with formulae whose `url` points at **local tarballs** committed to the repo. Deterministic, offline, content-addressed by real sha256.
- Assert the observable outcomes: cellar layout, receipts, shim files, state files, exit codes, `--json` output.
- Cover the atomicity guarantees: inject a failure mid-pipeline (bad sha, missing asset) and assert the cellar/state are untouched.

**3. CLI snapshot tests** — run the actual `gimme` executable in a temp prefix against fixtures, assert on structured `--json` output (deterministic) and stable help text. Protects the agent contract from drift.

**4. Network-gated tests (opt-in)** — a small set tagged `@network` that fetches a real formula from the real core tap (e.g. a tiny static binary). Off by default (CI runs them nightly). Proves livecheck/download against reality without making local runs flaky.

Coverage targets for the foundation: every public type in `GimmeCore` has unit tests; every CLI command has at least one integration test (success + one error path) and one JSON-schema assertion.

### Error model

Three orthogonal dimensions, every error carries all three:

| Dimension | Example |
|---|---|
| **Category** (maps to exit code per section 6) | `USAGE`, `NOT_FOUND` → 1; `INSTALL`, `NETWORK`, `CHECKSUM`, `PERMISSION` → 2; `CONFLICT` → 3; `LOCK` → 4; `UNKNOWN` → 70 |
| **`GimmeError`** — a typed Swift enum with associated context | `.checksumMismatch(asset:expected:actual:)` |
| **Recoverability + suggestion** | `recoverable: false`, `suggested: "gimme uninstall git && gimme install git"` |

The Swift error type is what the engine throws; the CLI layer translates to `{category, message, details, recoverable, suggested}` JSON + the right exit code. The agent contract (section 7) consumes this directly. **No error is a bare string** — every failure path constructs a `GimmeError`.

User-facing messages are written for humans (actionable, no stack traces in default output); `--verbose` adds diagnostics; `--json` adds the structured form.

### Non-goals for the foundation (explicitly out of scope)

- **Source-based builds** (`strategy = "source"`) — enum reserved, not implemented.
- **Homebrew formula/cask compatibility** — separate `GimmeBrew` target later; the formula abstraction is shaped to receive translations.
- **Native GUI app** (`GimmeUI`) — separate target later; consumes `GimmeCore` directly or the `--json` contract.
- **MCP server** (`gimme mcp`) — reserved command, not built; the `--json`/`introspect` contract makes it a thin later adapter.
- **Linux/Windows support** — macOS only for the foundation (host detection already abstracts this for the future).
- **Self-managed core tap content** — the mechanism (taps, livecheck) ships; the library of formulae is a separate ongoing effort, not blocked on this spec.
- **A real SAT dependency solver** — reuse-installed-first + pick-highest (section 4); upgrade path reserved.
- **Background daemons / auto-update services** — `gimme update --check` is on-demand only.

### "Done" definition for the foundation

1. `gimme install git` works against a real (download-strategy) core formula, end to end, and `git` is on PATH.
2. `gimme git` (shortcut), `update`, `uninstall`, `use`, `pin`, `list`, `search`, `info`, `outdated`, `tap`, `doctor`, `config`, `introspect` all work and emit `--json`.
3. `--dry-run` plans any mutation accurately.
4. A failing install leaves the cellar and state unchanged (atomicity test passes).
5. The test layers above exist and pass on CI.
6. `docs/agent-interface.md` documents the CLI for AI agents, generated from `introspect`.
