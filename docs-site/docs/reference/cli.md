# CLI commands

The full command surface. Generated from `gimme introspect --json` — run that
for the live, machine-readable spec.

## Signature shortcut

```
gimme <tool>[@version]
```
Install if missing, update if stale, no-op if current or pinned. The primary UX.

## Commands

### `install`
```
gimme install <tool>[@version]
```
Install a tool. With no positional arg, auto-detects `.tool-versions`/`mise.toml`.

| Flag | Type | Description |
|---|---|---|
| `--dry-run` | bool | Plan without executing |
| `--insecure` | bool | Skip checksum verification |
| `--from-mise` | bool | Read mise/asdf config and install batch |
| `--no-mise` | bool | Disable auto-detection of mise config |

### `uninstall`
```
gimme uninstall <tool>[@version]
```
Remove a tool (active or specific version). `--force` overrides dependents.

### `update`
```
gimme update [<tool>]|--all
```
Update one tool or every non-pinned tool. `--check` reports outdated without updating.

### `use`
```
gimme use <tool> <version>
```
Switch the active version (no download).

### `pin` / `unpin`
```
gimme pin <tool>[@version]
gimme unpin <tool>
```
Hold/release a version. Pinned tools are skipped by `update --all`.

### `list`
```
gimme list [--all] [--limit N] [--fields a,b] [--query <expr>]
```
List installed tools (`--all` includes not-installed formulae).

### `search`
```
gimme search <term>
```

### `info`
```
gimme info <tool>
```

### `outdated`
```
gimme outdated
```

### `tap`
```
gimme tap <add|remove|list> [name] [url]
```

### `doctor`
```
gimme doctor
```
Health check: PATH, permissions, receipts, mise detection.

### `config`
```
gimme config <get|set> [key] [value]
```

### `introspect`
```
gimme introspect [--command <name>] [--json]
```
Machine-readable CLI spec (for agents).

### `man`
```
gimme man
```
Emit groff man-page source to stdout (pipe to a file under `man1/`).

## Global flags

| Flag | Description |
|---|---|
| `--json` | Structured JSON output |
| `--dry-run` | Plan mutations without executing |
| `--yes` | Non-interactive confirm |
| `--prefix <path>` | Override `~/.gimme` |
| `--tap <name>` | _(not yet implemented; fails loud)_ |
| `--verbose` | Debug logging |
| `--no-color` | Disable color |
