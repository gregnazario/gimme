# gimme

An all-in-one package management layer for macOS. gimme is a **pure
orchestration** tool: it doesn't download, build, or shelve anything itself —
it drives real package managers (Homebrew, Go, uv, Cargo, bun) through one
unified interface, so you can address packages by name across all of them

## Install

**macOS app:** download the signed + notarized DMG from
[releases](https://github.com/gregnazario/gimme/releases), open it, and drag
gimme to `Applications`. No Gatekeeper prompts.

**CLI (and app) via the install script:**
```bash
curl -fsSL https://raw.githubusercontent.com/gregnazario/gimme/main/install.sh | sh
```

This downloads a prebuilt binary (Apple Silicon) and installs it to `~/.local/bin`.
On Intel Macs or if no binary is available, it falls back to building from source
(requires Swift 5.9+). The SwiftUI app is installed to `/Applications` if available.

**Custom install directory:**
```bash
curl -fsSL https://raw.githubusercontent.com/gregnazario/gimme/main/install.sh | GIMME_INSTALL_DIR=/usr/local/bin sh
```

**Skip the app:**
```bash
curl -fsSL https://raw.githubusercontent.com/gregnazario/gimme/main/install.sh | GIMME_SKIP_APP=1 sh
```

After installing, make sure `~/.local/bin` is on your `PATH`, then:
```bash
gimme --help    # see what you can do
gimme doctor    # check which package managers are installed
```
without remembering which tool owns what.

Native Swift, with both a CLI (`gimme`) and a SwiftUI macOS app, sharing one
engine.

```bash
gimme install ripgrep        # resolves to the right manager automatically
gimme install --from cargo ripgrep   # force a backend; remembered next time
gimme list                   # everything installed, across every manager
gimme outdated               # what can be upgraded, across every manager
gimme update                 # upgrade all outdated packages
gimme brew services start postgres   # passthrough to the real tool
```

## Supported managers (v1)

| Manager | Backend | Notes |
|---|---|---|
| **Homebrew** | `brew` | formulae + casks (casks are first-class packages) |
| **Go** | `go install` | import-path packages; existence via the Go module proxy |
| **Python (uv)** | `uv tool` | per-tool isolated venvs (pipx-style), no dependency conflicts |
| **Cargo** | `cargo install` | crates.io for search/info |
| **npm (via bun)** | `bun install -g` | npm registry; adapter named `bun` |
| **npm** | `npm install -g` | npm registry; the npm CLI itself |
| **pnpm** | `pnpm add -g` | npm registry; pnpm's content-addressed store |
| **Yarn** | `yarn global add` | npm registry; classic (v1) global model — berry dropped globals |
| **RubyGems** | `gem install` | rubygems.org API for search/info |
| **Composer (PHP)** | `composer global require` | packagist.org API for search/info |
| **Deno** | `deno install -g` | JSR (jsr.io) + npm; scans ~/.deno/bin. No outdated (no version metadata) |
| **pipx** | `pipx install` | PyPI; per-tool isolated venvs (Python ecosystem alongside uv) |
| **aqua** | `aqua install` | owner/repo packages; declarative config. No outdated (pinned) |
| **ubi** | `ubi --project owner/repo` | GitHub releases. No registry/search; best-effort list scan |
| **App Store** | receipt scan + iTunes Lookup API | updates only (list/outdated/upgrade); `mas` upgrades when installed (password dialog when needed), else opens the App Store page |

Cargo installs prefer `cargo-binstall` (prebuilt binaries) when available, falling back to compiling from source.

## Consolidation

When the same package ends up in multiple managers within one ecosystem (e.g. `esbuild` in both bun and npm), `gimme consolidate` finds the duplicates and prints the exact commands to consolidate toward one preferred provider per ecosystem. **Report + guide only — no changes are made automatically.**

```bash
gimme consolidate                     # scan all ecosystems, report duplicates + commands
gimme config set ecosystem.js bun     # set the JS consolidation target
gimme config show ecosystems          # show current per-ecosystem preferences
```

Ecosystems are fixed buckets (JS, Python, Rust, Go, Ruby, PHP, System). Preferences are separate from the install-priority list.

**Runtime version managers (mise, asdf)** are detected and shown in `doctor`,
but deliberately *not* modeled as package managers — they manage runtimes
(node@20, python@3.12), not CLI packages. gimme coexists with them via PATH
augmentation; that's the right relationship.

Nix is designed for but deferred to v2. Missing a backend? gimme offers to
install it for you (`auto-bootstrap`).

## How it resolves packages

When you run `gimme install <name>`, gimme decides which manager to use:

1. **`--from <manager>`** wins outright. On success, that choice is *remembered*
   for the package, so `gimme install ripgrep` later goes to the same place.
2. Otherwise a **remembered preference** is used (if that backend is still
   installed).
3. Otherwise the **priority list** (default `homebrew, go, uv, cargo, bun`):
   gimme checks which managers have the package (concurrently) and picks the
   highest-priority one.

Use `gimme forget <name>` (or `--all`) to clear remembered preferences.

## CLI reference

```
gimme install <name> [--from <manager>] [--version <v>]
gimme uninstall <name>
gimme upgrade <name>
gimme update                       upgrade all outdated, across every manager
gimme list [--from <manager>]      all installed (default); --from filters to one
gimme outdated [--from <manager>]
gimme search <query> [--all]       default-priority manager; --all fans out
gimme info <name>
gimme forget <name> | --all
gimme doctor                       which managers are installed / on PATH
gimme config [set priority <a,b,c>]
```

**Passthrough:** `gimme <manager> <args...>` forwards verbatim to the underlying
tool — `gimme brew tap ...`, `gimme cargo build --release`, etc. gimme doesn't
parse or model it.

**Flags:** `--from <m>` · `--all` · `--refresh` (bypass cache read) · `--no-cache`
· `--json` (machine-readable output for `list`/`outdated`/`search`/`info`) ·
`--version <v>` · `-y` (non-interactive).

## State

- **Live query + TTL cache.** gimme always asks the real managers for the truth
  on `list`/`outdated`/`info`; the disk cache only avoids re-querying within its
  TTL window (5 min for list/outdated, 1 hour for info). `--refresh` bypasses it.
  Cache lives in `~/.cache/gimme/`.
- **Config:** `~/.config/gimme/config.toml` (priority list, enabled managers,
  cache TTLs).
- **Preferences:** `~/.config/gimme/preferences.toml` (per-package remembered
  overrides).

## Architecture

Single SwiftPM workspace, three targets:

- **`GimmeCore`** — the engine: the `PackageManager` protocol, the `Registry`
  (discovers adapters), the `Resolver` (priority + remembered prefs), the TTL
  `Cache`, `Preferences`, and shared `ProcessRunner` / `HTTPClient` / `Bootstrap`
  helpers. Plus five fat adapters in `managers/` (Homebrew as the reference).
- **`gimme`** — the CLI.
- **`GimmeUI`** — the SwiftUI app.

The design is **thin engine, fat adapters**: the engine never knows *how* a
manager installs things. Each adapter owns its I/O strategy (brew JSON API, Go
proxy, PyPI, crates.io, npm registry; CLI where no machine API exists) behind
the one `PackageManager` seam. See
[`docs/superpowers/specs/2026-08-07-gimme-v2-orchestrator-design.md`](docs/superpowers/specs/2026-08-07-gimme-v2-orchestrator-design.md)
for the full design and
[`docs/superpowers/plans/2026-08-07-gimme-v2-orchestrator.md`](docs/superpowers/plans/2026-08-07-gimme-v2-orchestrator.md)
for the implementation plan.

## Building

```bash
swift build              # debug, all targets
swift test               # 105+ tests, in-process, no real installs/network in CI
swift build -c release   # release
```

The SwiftUI app builds with `swift build -c release --product GimmeUI`; the
`.app` bundle is assembled by `app/build-app.sh`.

## Status

v2 orchestration layer, working end-to-end against real managers. Pre-1.0;
breaking changes are expected. The earlier v1 native-pipeline (formulae, TOML
manifests, Lua sandbox, cellar, taps) has been removed.
