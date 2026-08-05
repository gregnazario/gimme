# Mise / asdf interop

gimme reads the standard project-config file formats and coexists with mise/asdf.

## What it does

- **Reads** `.tool-versions` (asdf) and `mise.toml` `[tools]` (mise).
- **Installs** what they declare via gimme formulae.
- **Skips** tools mise/asdf already manage (never clobbers).

## Auto-detect on `gimme install`

```sh
cd ~/my-project              # has a .tool-versions or mise.toml
gimme install                # auto-detects + installs the batch
```

The trigger: no positional tool argument AND no `--no-mise` AND config found by
walking up to the `.git` root.

| Invocation | Behavior |
|---|---|
| `gimme install` (no args), config present | Auto-detect + batch install |
| `gimme install` (no args), no config | Existing behavior (usage) |
| `gimme install --dry-run` | Plan the batch, no install |
| `gimme install node` | Explicit — bypasses config reading |
| `gimme install --from-mise` | Force reading config even with a positional arg |
| `gimme install --no-mise` | Disable auto-detection for this run |

## Version spec mapping

mise specs are fuzzy, not SemVer. gimme maps each:

| mise spec | gimme interpretation | Status |
|---|---|---|
| `20.0.0` | exact | install |
| `20`, `3` | any major.x (fuzzy major) | install |
| `latest` | newest available | install |
| `lts` | alias -> newest available | install (best-effort) |
| `prefix:1.19` | any 1.19.x | install |
| `prefix:3` | any 3.x.x | install |
| `ref:<sha>` | compile from VCS ref | **skip (unsupported)** |
| `path:./dir` | use a local dir | **skip (unsupported)** |
| `sub-2:lts` | arithmetic | **skip (unsupported)** |

Unsupported specs are reported as `skipped_unsupported` in the batch result —
they don't abort the run.

## Coexistence (skip mise-managed tools)

When deciding whether to install tool `X`, gimme resolves `X` on `PATH`
(excluding its own shim dir) and checks if the resolved path lives under a
known shims dir:

- `$MISE_DATA_DIR/shims`
- `~/.local/share/mise/shims`
- `~/.asdf/shims`

If so, that manager owns `X` → skip. This is robust to how mise was installed
(curl|sh, brew, mise-installs-itself) because it keys off the shim location.

## Batch JSON shape

```json
{
  "cmd": "install-from-mise",
  "ok": true,
  "schema_version": 1,
  "source": ".tool-versions",
  "tools": [
    { "tool": "go", "spec": "1.21", "status": "installed", "version": "1.21.5" },
    { "tool": "node", "spec": "20", "status": "skipped_managed",
      "manager": "mise", "reason": "node is managed by mise" },
    { "tool": "erlang", "spec": "ref:master", "status": "skipped_unsupported",
      "reason": "gimme does not support ref:master specs" }
  ],
  "summary": { "installed": 1, "skipped": 2, "failed": 0 }
}
```

Exit code: `0` if nothing failed, `1` if any tool failed.

## Honest limitation

gimme's detection sees the **globally-active** version of a tool, not
per-directory ones. If mise manages `node` only inside certain project dirs and
you run `gimme install` from a dir where mise isn't active for `node`, gimme
will install its own `node`. This is the safe direction (you get a working
tool). A future per-directory detection strategy is reserved.
