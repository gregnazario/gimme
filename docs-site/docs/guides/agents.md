# AI agents

gimme's CLI is a documented API, not just a human tool. An agent can learn the
whole surface, plan mutations, execute, and recover from structured errors —
all without scraping human prose.

## The contract

1. **`--json` is first-class.** Every command emits a single well-formed JSON
   object with a `schema_version` (currently `1`).
2. **`gimme introspect --json`** is the machine-readable CLI spec — every
   command, its args, flags (types/defaults), exit codes, and output schema.
3. **`--dry-run`** on every mutating command returns the plan as JSON without
   executing.
4. **Non-interactive under `--json`/`--yes`.** No hidden prompts; destructive
   actions return structured errors.
5. **Structured errors.** Every failure carries `code`, `message`, `details`,
   `recoverable`, and `suggested`.

## Worked flow

```text
1. gimme introspect --json              # learn the surface (cache once)
2. gimme install git --dry-run --json   # plan: see sha256, deps, conflicts
3. gimme install git --json             # execute
4. gimme info git --json                # confirm installed version
```

## Error shape

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

## Exit codes

| Exit | Categories |
|---|---|
| 0 | success (incl. intentional no-op) |
| 1 | `USAGE`, `NOT_FOUND` |
| 2 | `INSTALL`, `NETWORK`, `CHECKSUM`, `PERMISSION` |
| 3 | `CONFLICT` |
| 4 | `LOCK` |
| 70 | `UNKNOWN` |

See the [exit codes reference](../reference/exit-codes.md).

## Future: MCP

A `gimme mcp` server (Model Context Protocol) is reserved but not yet built.
The `--json` + `introspect` contract makes it a thin adapter — no engine rework.
