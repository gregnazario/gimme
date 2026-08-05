# gimme

A **Swift-based package manager for macOS** — source or download installs,
typed formulae with a sandboxed Lua runtime, versioned cellar with PATH shims,
mise/asdf interop, and a first-class AI-agent contract.

```sh
gimme git          # install git if missing, update if stale, no-op if current
gimme rustup       # same signature shortcut
gimme list         # show installed tools
```

## Why gimme?

- **Typed formulae.** Declarative TOML manifest + a sandboxed Lua `install(ctx)`
  for the messy cases. ~80% of formulae are pure data.
- **Versioned cellar.** Every tool@version lives in its own dir; switch or roll
  back instantly. `gimme git@2.40`, `gimme use git 2.40.0`.
- **Atomic installs.** A failed install never leaves a half-installed tool.
- **Mise/asdf interop.** `gimme install` reads `.tool-versions` / `mise.toml`
  and defers to tools mise already manages.
- **Agent-friendly.** Every command emits `--json` with a `schema_version`;
  `gimme introspect` exposes the whole CLI as data; `--dry-run` plans.

## Status

The **foundation** is complete: core engine, formula system, version
resolution, atomic install pipeline, full CLI (15 commands), mise interop, and
306 tests at ~95% coverage. Follow-on work (source builds, Homebrew
compatibility, native GUI, MCP server) is reserved.

Follow-on work builds on the abstractions defined in the
[design spec](design/foundation.md) and [decision log](reference/decisions.md).

## Next

- [Install](install.md) gimme
- [Quick start](quickstart.md) — install your first tool
- [Formula format](guides/formulae.md) — write a formula
