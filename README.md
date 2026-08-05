# gimme

A Swift-based package manager for macOS, supporting download-based (and
planned source-based) installation. Tools are described by **formulae** that
combine a typed TOML manifest with sandboxed Lua logic. `gimme` has a CLI
designed for both humans and AI agents, with a planned native GUI.

```bash
gimme git          # install git if missing, update if stale, no-op if current
gimme rustup       # same signature shortcut
gimme list         # show installed tools
```

## Status

This is the **foundation** plus **mise/asdf interop**: the core engine, the
manifest + Lua sandbox formula system, version resolution, atomic installs, a
CLI with a first-class AI-agent contract, reading of `.tool-versions`/`mise.toml`
project config with coexistence (skips tools mise/asdf already manage), and
≥90% test coverage on the core library. Follow-on work (source builds,
Homebrew compatibility, native GUI app, MCP server) builds on the abstractions
defined here.

## Mise/asdf interop

`gimme install` (no args) auto-detects `.tool-versions` or `mise.toml` in the
current directory (or a parent up to the `.git` root) and installs the tools it
declares via gimme formulae. Tools already managed by mise/asdf are skipped
(never clobbered). Unsupported specs (`ref:`, `path:`, `sub-`) are reported as
skipped.

```bash
cd ~/my-project        # has a .tool-versions or mise.toml
gimme install          # auto-detects + installs the batch
gimme install --no-mise   # opt out of auto-detection
gimme install --from-mise # force reading config even with a positional arg
gimme install --dry-run --json   # plan the batch (agent-friendly)
```

Per-tool outcomes are reported in a structured batch JSON (`cmd:
"install-from-mise"`, `tools[]`, `summary{installed,skipped,failed}`). See
`docs/superpowers/specs/2026-08-03-mise-interop-design.md`.

## Building

Requirements: Swift 6+, macOS 13+.

**Install (one line):**

```sh
curl -fsSL https://raw.githubusercontent.com/gregnazario/gimme/main/install.sh | sh
```

The installer clones, builds a release binary, and installs to `~/.local/bin`
plus the man page and tldr page. Override the target with
`GIMME_INSTALL_DIR=/opt/bin`, or run `sh install.sh --help` for all options.
For a local clone, `just install` does the same without cloning.

**From source:**

```bash
git clone https://github.com/gregnazario/gimme.git
cd gimme
swift build                # build the `gimme` executable
swift test                 # run the test suite (306 tests)
swift test --enable-code-coverage   # measure coverage
.build/debug/gimme --help
```

## Quick start

```bash
# Add gimme's bin to your PATH (one time):
echo 'export PATH="$HOME/.gimme/bin:$PATH"' >> ~/.zshrc

# Install a tool:
gimme install <tool>

# The signature shortcut:
gimme <tool>            # install / update / no-op / pinned-aware

# Manage versions:
gimme <tool>@2.40       # install a specific version line
gimme use <tool> 2.40.0 # switch active version (no download)
gimme pin <tool>        # hold a version
gimme update --all      # update everything not pinned

# Inspect:
gimme list [--all]      # installed tools (or all known formulae)
gimme search <term>
gimme info <tool>
gimme outdated
gimme doctor            # health check

# Formula sources (taps):
gimme tap add <name> <git-url>
gimme tap list
```

## Formulae

A formula is a directory containing `formula.toml` (declarative manifest) and
optionally an `install.lua` (sandboxed logic). Metadata is type-checked; the
Lua runtime is restricted to a controlled `ctx` API — `os.execute`, `io.popen`,
`loadfile`, `require`, and `debug` are blocked.

```toml
[package]
name = "hello"
desc = "A demo tool"

[[version]]
ver = "1.0.0"

[[version.asset]]
os = "macos"
arch = "arm64"
url = "https://example.com/hello-1.0.0.tar.gz"
sha256 = "..."     # required

[install]
strategy = "steps"          # or "lua"

[[install.step]]
extract = "${asset}"
[[install.step]]
copy = { from = "hello-1.0.0", to = "${prefix}" }

[[provides]]
bin = ["hello"]
```

For complex installs, `strategy = "lua"` runs `install(ctx)` against the
sandbox:

```lua
function install(ctx)
  local asset = ctx:download()        -- staged + sha256-verified
  local dir   = ctx:extract(asset)    -- tgz/tbz/zip auto-detected
  ctx:install_dir(dir .. "/payload")  -- move into the cellar prefix
  ctx:set_provides({"hello"})         -- declare binaries
  ctx:mkdir("${prefix}/share/man")
end
```

## Architecture

A single SwiftPM workspace:

| Target | Role |
|---|---|
| `GimmeCore` | The engine: manifest, taps, resolver, downloader, sandboxed Lua, cellar, shims, state, installer, introspect. |
| `gimme` | The CLI executable. |
| `GimmeLua` | Vendored Lua 5.4 C sources. |
| `CGimmeLuaSupport` | C glue: Lua API wrappers + `ctx` dispatch via a runtime function-pointer table. |

On-disk layout (under `~/.gimme`): `bin/` (PATH shims), `cellar/<tool>/<ver>/`
(versioned installs, atomic commits), `cache/<sha256>/` (content-addressed
downloads), `taps/`, `staging/`, `state/` (derived `installed.json` +
authoritative `pinned.json`), `config.toml`.

## AI agents

gimme's CLI is a documented API. See **[docs/agent-interface.md](docs/agent-interface.md)**
for the full agent contract: `gimme introspect --json` (the machine-readable
spec), `--dry-run` planning, structured `--json` output with `schema_version`,
and a fixed error-category ↔ exit-code map. A future `gimme mcp` server will
expose the same surface as native Model Context Protocol tool calls.

## Documentation

- **Docs site:** build and serve locally with `just docs-serve` (MkDocs Material).
- **Man page:** `man gimme` (after `just man`), or `gimme man` for the source.
- **tldr page:** `just tldr` to install locally; source at `tldr-pages/pages/common/gimme.md`.
- **Per-command help:** `gimme <command> --help` (e.g. `gimme install --help`).
- **Top-level help:** `gimme --help`.
- **Machine-readable spec:** `gimme introspect --json` (for agents).

### In this repo

- Decision log: `DECISIONS.md`
- Foundation design spec: `docs/superpowers/specs/2026-08-03-gimme-foundation-design.md`
- Foundation implementation plan: `docs/superpowers/plans/2026-08-03-gimme-foundation.md`
- Mise interop design spec: `docs/superpowers/specs/2026-08-03-mise-interop-design.md`
- Mise interop implementation plan: `docs/superpowers/plans/2026-08-03-mise-interop.md`
- Agent interface: `docs/agent-interface.md`
- Docs site source: `docs-site/` (MkDocs Material; `just docs-serve` to preview)

## Justfile tasks

```
just build          # swift build
just release        # swift build -c release
just test           # swift test
just docs-setup     # one-time: create docs-site venv + install mkdocs-material
just docs-serve     # serve docs site with live reload
just docs-build     # build docs to ./site
just man            # regenerate + install the man page
just tldr           # install the tldr page locally
just install        # install release binary to ~/.local/bin/gimme
```
