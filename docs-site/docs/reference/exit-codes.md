# Exit codes

Exit code ↔ error category is a fixed, documented map. Deterministic for scripting.

| Exit | Category | Meaning |
|---|---|---|
| `0` | — | Success, including intentional no-op (e.g. "already current") |
| `1` | `USAGE` | Bad args, unknown flag, malformed query |
| `1` | `NOT_FOUND` | Unknown tool/version |
| `2` | `INSTALL` | Failure during stage/commit/activate |
| `2` | `NETWORK` | Download failed |
| `2` | `CHECKSUM` | sha256 mismatch |
| `2` | `PERMISSION` | Permission denied |
| `3` | `CONFLICT` | Unresolvable dependency/version conflict |
| `4` | `LOCK` | Could not acquire the state lock |
| `70` | `UNKNOWN` | Internal/unexpected error (bug); diagnostics under `--verbose` |

## Error JSON shape

Every failure (under `--json`) carries:

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

`suggested` lets an agent chain recovery without human prose.
