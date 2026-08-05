# gimme — AI Agent Interface

gimme is designed to be driven by AI agents as well as humans. The CLI is a
**documented API**: every command emits structured JSON with a stable schema,
every mutation can be planned with `--dry-run`, and every error carries a
machine-readable code, message, recoverability flag, and recovery suggestion.

This document is the stable reference for agents. It is auto-generatable from
`gimme introspect --json`.

## The agent contract

1. **`--json` is first-class.** Every command emits a single well-formed JSON
   object to stdout. Every response carries `schema_version` (currently `1`).
   Bump the version on any breaking change.

2. **`gimme introspect`** is the machine-readable CLI spec — every subcommand,
   its positional args, flags (with types/defaults), exit codes, and JSON
   output schema. Load it once to know the whole surface without parsing prose.

   ```bash
   gimme introspect --json                       # full spec
   gimme introspect install --json               # one command
   ```

3. **`--dry-run`** on every mutating command (`install`, `uninstall`,
   `update`, `use`, `pin`, `tap`) returns the plan as JSON without executing —
   what would be fetched (url + sha256), which deps resolve, what cellar/prefix
   and shim changes, any conflicts. Plan before acting.

   ```bash
   gimme install rustup --dry-run --json
   ```

4. **Non-interactive under `--json` / `--yes`.** Machine mode never blocks on a
   TTY prompt. Destructive actions (e.g. uninstalling a tool others depend on)
   return a structured `CONFLICT` error listing dependents and a `--force`
   suggestion — no hidden prompts.

5. **Structured errors everywhere.** On failure:

   ```json
   {
     "ok": false,
     "error": {
       "code": "CHECKSUM",
       "message": "checksum mismatch: expected abc, got def",
       "details": { "expected": "abc", "actual": "def" },
       "recoverable": false,
       "suggested": "gimme uninstall <tool> && gimme install <tool>"
     }
   }
   ```

   Exit code ↔ error category is a fixed map:

   | Exit | Categories                                     |
   |------|------------------------------------------------|
   | 0    | success (incl. intentional no-op)              |
   | 1    | `USAGE`, `NOT_FOUND`                           |
   | 2    | `INSTALL`, `NETWORK`, `CHECKSUM`, `PERMISSION` |
   | 3    | `CONFLICT`                                     |
   | 4    | `LOCK`                                         |
   | 70   | `UNKNOWN`                                      |

6. **Filterable read output.** `list` / `search` / `info` / `outdated` take
   `--limit N`, `--fields a,b,c`, and `--query '<expr>'`.

## Worked agent flows

### Install + verify

```text
1. gimme introspect --json              # learn the surface (cache once)
2. gimme install git --dry-run --json   # plan: see sha256, deps, conflicts
3. gimme install git --json             # execute
4. gimme info git --json                # confirm installed version
```

### Handle a checksum failure

```text
1. (install fails) -> exit 2, code=CHECKSUM, suggested="gimme uninstall <tool> && gimme install <tool>"
2. gimme uninstall <tool> --json
3. gimme install <tool> --json          # retry
```

### Update everything non-pinned

```text
1. gimme outdated --json                # see what's behind
2. gimme update --all --json            # update
```

## Out of scope for the foundation

- **`gimme mcp`** (a Model Context Protocol server) is reserved but not yet
  built. The `--json` + `introspect` contract makes a future MCP adapter a thin
  mapping — no engine rework required.
- Source-based builds, Homebrew compatibility, and a native GUI are deferred
  follow-ons; the engine abstractions already accommodate them.

## Reference

- Design spec: `docs/superpowers/specs/2026-08-03-gimme-foundation-design.md`
- Implementation plan: `docs/superpowers/plans/2026-08-03-gimme-foundation.md`
