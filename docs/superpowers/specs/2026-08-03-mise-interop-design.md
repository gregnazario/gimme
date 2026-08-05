# gimme — Mise/asdf Interop Design

**Status:** Approved (2026-08-03)
**Scope:** Follow-on feature, layered on the gimme foundation. Adds two capabilities:
(1) read `.tool-versions` / `mise.toml` project config and install what they
declare via gimme formulae; (2) coexist with mise/asdf by skipping tools those
managers already manage.

---

## 1. Overview

gimme's foundation uses a **global, static-shim activation model** (the
Homebrew model). mise/asdf use a **per-directory activation model**. These do
not merge cleanly, so this feature deliberately does NOT attempt per-directory
activation. Instead it provides two cheap, high-value capabilities:

- **Read project config** — `gimme install` (no args) auto-detects
  `.tool-versions` / `mise.toml` in the cwd or a parent and installs what they
  declare via gimme formulae.
- **Coexist** — if mise/asdf already manages a tool on PATH, gimme skips it
  rather than clobbering. The two never fight.

This is interop, not parity. gimme remains a global tool manager; it just
reads the standard project-config file formats and defers to other managers
where they're already active.

### Decisions (locked during brainstorming)

- **Discovery:** auto-detect on `gimme install` (no args), with `--no-mise`
  (opt-out) and `--from-mise` (force) flags.
- **Conflict policy:** skip mise-managed tools (never clobber).
- **Detection:** PATH resolve + realpath prefix check (no mise dependency).

### Out of scope (explicitly)

- **Per-directory activation** — the activation-model trap. gimme stays global.
- **`ref:` / `path:` / `sub-:` specs** — don't map to gimme's download model.
  Reported as `skipped_unsupported`, not implemented.
- **Writing mise config** (`gimme init`). Read-only.
- **`MISE_<TOOL>_VERSION` env override** beyond simple recognition.
- **Shelling out to `mise`** as a detection strategy — reserved as a future
  per-directory-aware strategy (see §6).

---

## 2. Module layout

New module under the existing `GimmeCore`, matching the codebase's
one-file-per-responsibility convention:

```
Sources/GimmeCore/mise/
  MiseConfig.swift        # parse .tool-versions + mise.toml [tools]; walk + merge
  MiseVersionSpec.swift   # the spec grammar; mapping to gimme queries/constraints
  MiseDetector.swift      # is a tool already managed by mise/asdf? (PATH-based)
  MiseIntegration.swift   # orchestrator: read -> filter -> install via Installer
```

**Consumes from the foundation (no changes required):**
`Installer.install(query:)`, `Resolver`, `FormulaProvider` / `TapStore`,
`GimmeError`, `GimmePaths`, `Schema`, the `--json` response shape.

**Adds to the CLI:** auto-detect behavior inside the existing `install`
command plus two flags (`--from-mise`, `--no-mise`). No new subcommands.

---

## 3. Config parsing & version specs

### `.tool-versions` (asdf format)

One tool per line, whitespace-separated, `#` comments allowed, blank lines
ignored:

```
node 20.0.0       # comments allowed
ruby 3            # fuzzy version
shellcheck latest
go prefix:1.19
erlang ref:master
shfmt path:./shfmt
node lts
```

Grammar per line: `<name> <version-spec> [# comment]`. First token = tool
name, second = spec; everything after `#` dropped. A line with only a name is
invalid → recorded as a parse error and skipped (does not abort the run).

### `mise.toml` `[tools]` (parsed via gimme's existing TOML parser)

Two shapes per mise's docs:

```toml
[tools]
node = "20"                                          # simple string
python = "3.12"
node = { version = "22", postinstall = "corepack enable" }  # inline table
```

For each `[tools]` entry: a string value is the spec directly; an inline table
value uses its `version` field. mise-specific keys (`postinstall`,
`install_env`, `depends`) are **ignored** — gimme formulae declare their own
install logic.

### `MiseVersionSpec` — grammar and mapping

mise version strings aren't SemVer; they're fuzzy. Each maps to a gimme
`VersionConstraint` (or to a skip marker):

| mise spec            | gimme interpretation       | gimme query           | Status              |
|----------------------|----------------------------|-----------------------|---------------------|
| `20.0.0`             | exact                      | `tool@20.0.0`         | install             |
| `20`, `3`            | fuzzy major                | `tool@20`             | install             |
| `20.10.5`            | exact                      | `tool@20.10.5`        | install             |
| `latest`             | newest available           | `tool`                | install             |
| `lts`                | alias                      | `tool` (best-effort)  | install (see note)  |
| `prefix:1.19`        | newest matching prefix     | `tool@1.19`           | install             |
| `ref:<sha>`          | compile from VCS ref       | —                     | **skip (unsupported)** |
| `path:./dir`         | use a local dir            | —                     | **skip (unsupported)** |
| `sub-2:lts`          | arithmetic on resolved     | —                     | **skip (unsupported)** |

**`lts` note:** gimme's foundation doesn't track upstream LTS tags, so `lts`
is treated as "newest available" (`tool`, no constraint). Documented
limitation; the result entry reports the actually-installed version so the
user can see what was chosen.

```swift
public struct MiseVersionSpec: Equatable {
    public let raw: String           // original spec string, e.g. "prefix:1.19"
    public let kind: Kind
    public enum Kind {
        case exact(Version)
        case fuzzyMajor(Int)
        case latest
        case alias(String)           // "lts" or any non-numeric, non-scoped string
        case prefix(Int, Int)        // prefix:1.19 -> (1, 19)
        case unsupported(String)     // ref:, path:, sub- -> reason in raw
    }
    public static func parse(_ s: String) -> MiseVersionSpec
}
```

A spec is translated to a **gimme query string** (e.g. `node@20`) handed to
`Installer.install(query:)`. The existing resolver already handles
`tool@<constraint>`, so the integration is mostly spec → query translation.

### Config walk & merge

When gimme auto-detects, it starts at the cwd and walks up the directory tree
collecting every `.tool-versions` and `mise.toml`, stopping at the first
directory containing a `.git` (project root) **or** the filesystem root. This
matches the common "project + global" layering without walking the entire home
dir every run.

**Merge rule (matching mise):** for `[tools]` / `.tool-versions` content,
closer-to-cwd wins per-tool; different tools accumulate. `~/mise.toml` says
`node=18` and `~/proj/mise.toml` says `node=20` + `go=1.21` → merged result is
`{node: 20, go: 1.21}`.

---

## 4. Coexistence — skip mise-managed tools

Per the locked conflict policy: if mise/asdf already manages a tool, gimme
skips it rather than clobbering.

### Detection: PATH resolve + realpath prefix check

1. **Resolve the tool on PATH** — `which`-style walk of `$PATH` for an
   executable named `<tool>`, **excluding gimme's own `~/.gimme/bin` shim dir**
   (so gimme doesn't detect itself).
2. **realpath the result** — follow symlinks to the final on-disk binary.
3. **Check if that realpath is under a known mise/asdf shims dir.** Candidates,
   in priority order:
   - `$MISE_DATA_DIR/shims` (if set; mise respects this)
   - `~/.local/share/mise/shims` (mise default on macOS)
   - `~/.asdf/shims` (asdf)

   If the realpath starts with any of these → **that manager owns the tool** → skip.

This is robust to how mise was installed (curl|sh, brew, mise-installs-itself)
because it keys off the *shim location*, not mise's binary location. If none of
those dirs exist or the tool isn't on PATH, gimme proceeds to install — the
right behavior on a machine without mise.

```swift
public struct MiseDetector {
    public init(paths: GimmePaths)
    /// Does mise/asdf currently manage `tool`? (PATH resolve + realpath check)
    public func isManaged(byManager tool: String) -> Bool
    /// Which manager owns it (for reporting)? nil if unmanaged.
    public func owner(of tool: String) -> Manager?
    public enum Manager: String { case mise, asdf }
}
```

### What gets skipped vs installed

For a merged config `{node: 20, go: 1.21, ripgrep: latest, erlang: ref:master}`:

| Tool              | mise owns on PATH? | Spec supported? | Action                      |
|-------------------|--------------------|-----------------|-----------------------------|
| `node@20`         | yes                | yes             | **skip** — managed by mise  |
| `go@1.21`         | no                 | yes             | **install**                 |
| `ripgrep@latest`  | no                 | yes             | **install**                 |
| `erlang@ref:...`  | (n/a)              | no              | **skip** — unsupported spec |

Skips never abort the run. Each tool in the config becomes one entry in the
result array with a status (section 5).

### Honest limitation

PATH-based detection sees the **globally-active** version of a tool, not
per-directory ones. If mise manages `node` only inside certain project dirs
and you run `gimme install` from a dir where mise isn't active for `node`,
gimme won't see mise owning it and will install its own `node`. This is the
safe direction (the user gets a working tool rather than a confusing skip) and
is a deliberate consequence of gimme's global model. A future per-directory
detection strategy is reserved (§6).

---

## 5. CLI integration, result shape & doctor

### CLI surface (stays inside existing `install` command)

| Invocation                                       | Behavior                                                      |
|--------------------------------------------------|--------------------------------------------------------------|
| `gimme install` (no positional arg), mise config present   | Auto-detect, install supported+unmanaged, skip rest          |
| `gimme install` (no positional arg), no mise config        | Existing behavior — print usage                              |
| `gimme install --dry-run` (flag but no positional arg)     | Auto-detect + plan each tool, no install                      |
| `gimme install node` (any positional arg)       | Explicit install — bypasses config reading entirely          |
| `gimme install --from-mise [tool]`              | Force reading mise config even with a positional arg / when it wouldn't auto-trigger |
| `gimme install --no-mise`                       | Disable auto-detection for this run (opt-out)                |

**"Auto-detect" trigger, precisely:** `gimme install` enters mise-reading mode
when (a) there is no positional tool argument, AND (b) `--no-mise` is absent,
AND (c) a `.tool-versions` or `mise.toml` is found by the walk (§3). `--from-mise`
forces mise-reading mode even when (a) or (c) wouldn't otherwise trigger (e.g.
a positional arg is also present, meaning "install this tool AND read config").
When mise-reading mode is active, the response uses `cmd: "install-from-mise"`;
otherwise the existing single-install path (`cmd: "install"`) is unchanged.

Auto-detect prints a one-line notice when it triggers: *"Detected mise config
— installing 2 tools, skipping 1 (managed by mise)."* Not silent, not noisy.

`--dry-run` plans each tool in the config without installing — the
agent-friendly path: `gimme install --dry-run --json` shows exactly what a
project needs.

### Result shape (`--json`)

One JSON object covering the whole batch. `cmd: "install-from-mise"` so
consumers distinguish a batch from a single install. Each tool entry carries
its own status; failures carry their own structured error:

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
    { "tool": "ripgrep", "spec": "latest", "status": "installed", "version": "14.0.3" },
    { "tool": "erlang", "spec": "ref:master", "status": "skipped_unsupported",
      "reason": "gimme does not support ref: specs" },
    { "tool": "ruby", "spec": "3", "status": "failed",
      "error": { "code": "NOT_FOUND", "message": "no formula named 'ruby'" } }
  ],
  "summary": { "installed": 2, "skipped": 2, "failed": 1 }
}
```

Top-level `ok` is `true` if at least one tool installed or was already-current;
`false` only if every tool failed. Individual failures don't abort the batch.

**Exit code:** `0` if nothing failed, `1` if any tool failed (so CI/scripts can
detect partial failure). Matches the foundation's exit-code map.

Per-tool `status` values: `installed` | `already_current` | `skipped_managed`
| `skipped_unsupported` | `failed`.

### `gimme doctor` integration

One new check: report whether mise/asdf is detected on PATH and, if so, list
which gimme-installed tools are *also* managed by it. Output line:
`[✓] mise: detected; manages: node, python (gimme defers to mise for these)`.

### Introspect

The `install` command's flag list in `Introspect` gains `--from-mise` and
`--no-mise` with descriptions. No schema-version bump required (the new
`cmd: "install-from-mise"` is an additive response shape).

---

## 6. Reserved follow-ons (explicitly not now)

- **Per-directory detection via `mise current <tool>`** — a future
  `MiseDetector` strategy that asks mise directly. The `Manager` enum and
  `isManaged` interface already accommodate it; only the detection internals
  change.
- **`ref:` / `path:` support** — would require source builds (the foundation's
  reserved `strategy = "source"`) and a local-dir provider respectively.
- **Writing mise config** (`gimme init`).
- **`MISE_<TOOL>_VERSION` env override** beyond simple recognition.

---

## 7. Testing

Three layers, matching the foundation's style:

1. **Unit** — `MiseConfigTests`, `MiseVersionSpecTests`, `MiseDetectorTests`.
   Parse each config format; exercise every spec kind (incl. unsupported);
   test PATH-resolution detection against a fake PATH pointing at a temp
   "shims" dir (both mise and asdf layouts); verify gimme's own shim dir is
   excluded.
2. **Integration** — `MiseIntegrationTests`. End-to-end: drop a
   `.tool-versions` in a temp dir, run the integration with `cwd` set there,
   assert install/skip outcomes. Uses the same local-tarball fixture pattern as
   the existing `InstallerTests`.
3. **CLI snapshot** — extend `CLISnapshotTests` with one test that runs
   `gimme install --json` in a temp cwd containing a `.tool-versions` and
   asserts the batch JSON shape.

Coverage target: the new `mise/` module at ≥90% line coverage, consistent with
the foundation's bar.
