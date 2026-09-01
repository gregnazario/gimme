# CLI commands

gimme is a pure orchestrator: it drives real package managers (Homebrew, Go,
uv, Cargo, bun, npm, pnpm, Yarn, RubyGems, Composer, Deno, pipx, aqua, ubi,
and the Mac App Store) through one unified namespace.

Run `gimme --help` for the built-in usage text.

## Commands

### `install`
```
gimme install <name> [--from <manager>] [--version <v>]
```
Install a package, asking each available manager in priority order.
`--from` forces a specific manager and remembers the choice per package.
Missing backends are bootstrapped on demand (prompted unless `-y`).

### `uninstall`
```
gimme uninstall <name> [--from <manager>]
```

### `upgrade`
```
gimme upgrade [<name>]
```
Upgrade one package, or every outdated package across all managers when run
with no arguments. Partial failures are reported per package.

### `update`
```
gimme update [--self]
```
Alias of bare `upgrade`; `--self` updates gimme itself
(SHA256SUMS-verified download from the latest GitHub release).

### `list`
```
gimme list [--from <manager>]
```
List packages installed across all managers (or one) as
`[manager] name version` lines.

### `outdated`
```
gimme outdated [--from <manager>] [--refresh] [--force]
```
Show packages with a newer version available. Per-package registry lookups
are cached for 1 h; `--force` re-asks every registry.

### `search`
```
gimme search <query> [--all]
```
Search the highest-priority manager that has the package; `--all` queries
every manager.

### `find`
```
gimme find <query>
```
Searches every capable manager at once (no `--all` needed) and ranks exact
name matches first — the fastest answer to "which managers provide `jq`?".
Accepts `--json` and `--force`.

### `info`
```
gimme info <name> [--from <manager>]
```

### `forget`
```
gimme forget <name> | --all
```
Drop remembered per-package manager preferences.

### `consolidate`
```
gimme consolidate
```
Report packages installed through more than one manager in the same
ecosystem, with recommended install/uninstall commands. Makes no changes.

### `doctor`
```
gimme doctor
```
Per-manager availability and version, plus detected runtime version managers
(mise/asdf), which gimme coexists with but does not manage.

### `config`
```
gimme config                       (print current config)
gimme config set priority brew,cargo,go,uv,bun
gimme config set ecosystem.js bun
gimme config show ecosystems
```

## Passthrough

```
gimme <manager> <args...>
```
Forward arguments verbatim to the underlying tool — `gimme brew tap ...`,
`gimme cargo build --release`. gimme doesn't parse or model passthrough
commands. Managers: `homebrew go uv cargo bun npm pnpm yarn gem composer
deno pipx aqua ubi appstore`.

## Global flags

| Flag | Description |
|---|---|
| `--from <m>` | Restrict a command to one manager |
| `--all` | search: query every manager · forget: drop all preferences |
| `--refresh` | Bypass the list/outdated result cache for this run |
| `--force` | Bypass every cache layer, incl. per-package registry lookups (implies `--refresh`; `--no-cache` is an alias) |
| `--json` | Machine-readable JSON output (list/outdated/search/info/install/doctor/consolidate) |
| `--version <v>` | install: pin to a version |
| `-y`, `--yes` | Non-interactive; auto-confirm bootstrap prompts |

## Caching

Results are live-queried and cached in `~/.cache/gimme/` with per-type TTLs
(5 min for list/outdated results, 1 h for per-package registry version
lookups, 6 h for App Store lookups). Mutating operations invalidate the
affected entries. `--refresh` bypasses the result cache; `--force` re-asks
everything.
