# gimme — Decision Log

A record of the significant design and implementation decisions made on gimme,
with rationale. Ordered roughly chronologically by feature area. Each entry
notes the decision, alternatives considered, and why this path was chosen.

---

## Foundation

### F1. Single SwiftPM workspace with a shared `GimmeCore` library

**Decision:** One SwiftPM workspace. `GimmeCore` (library) holds the engine;
`gimme` (executable) is a thin CLI layer; the future GUI app will link
`GimmeCore` directly or consume the `--json` contract.

**Alternatives considered:** (a) CLI + separate GUI project talking via
subprocess/IPC; (b) single combined binary that is both CLI and GUI.

**Why:** Shared library target = one build, one source of truth, no IPC
boundary or duplicated logic. The GUI is a future target that plugs into the
same engine; building it later needs no engine rework.

### F2. Hybrid formula format: TOML manifest + sandboxed Lua

**Decision:** Formula metadata lives in a typed TOML manifest
(`formula.toml`); imperative install logic, when needed, is a sandboxed Lua
`install(ctx)` function. ~80% of formulae are pure declarative `steps`; Lua is
only invoked for the messy cases.

**Alternatives:** pure Swift DSL (heavy/slow at runtime, sandboxing hard);
pure Lua (loses type safety on metadata); support all three (triples testing).

**Why:** Type-safe data + real scripting + clean sandbox boundary. Lua is
purpose-built for embedding (microsecond startup, first-class sandboxing via
restricted env). This is also the cleanest on-ramp for future Homebrew-compat
(Ruby `install do` maps onto `steps` or `lua`, never requiring us to run Ruby).

### F3. Vendored Lua 5.4 + C glue with a runtime dispatch table

**Decision:** Lua 5.4 C sources vendored under `Sources/GimmeLua/lua54/`
(without `lua.c`/`luac.c` main()). The `ctx` API is exposed via
`CGimmeLuaSupport` (C glue) that calls back into Swift through a
**function-pointer table registered at runtime** — not via `extern` Swift
symbols.

**Alternatives:** link-time `@_cdecl` symbols; a mixed Swift+C target.

**Why:** SwiftPM does not support mixed-language targets, and linking C
against Swift `@_cdecl` symbols fails at link time because the C target is a
*dependency* of the Swift target (circular). The runtime dispatch table breaks
the cycle cleanly: the C code holds function pointers that Swift fills in once
at startup. No link-order issues, no mixed-target gymnastics.

### F4. Versioned cellar + atomic commits (rename)

**Decision:** Each tool@version gets `~/.gimme/cellar/<tool>/<version>/`.
Install stages into a temp dir, then `rename`s into the cellar (atomic on the
same volume). Receipts (`RECEIPT.json`) are the source of truth; the
`installed.json` index is derived and rebuildable.

**Alternatives:** single-version-per-tool (no parallel versions, hard
rollbacks); commit-then-activate with no atomic step.

**Why:** Atomicity guarantee (failed installs never leave half-installed
state) is the single most important property of a package manager. Versioned
cellar enables `gimme git@2.40`, rollbacks, and parallel installs for free.
Receipt-as-truth means a corrupted index is never fatal.

### F5. PATH shims (`~/.gimme/bin`) over shell-rc editing

**Decision:** gimme manages a directory of real executable shims; the user
adds it to PATH once. Each shim exec's the active version's real binary.

**Alternatives:** edit shell rc files (fragile, fights user rc, shell-specific);
require `eval $(gimme env)` hook (forces every user to add a line, version
switches need a new shell); user manages PATH (worst UX).

**Why:** Robust across shells, no per-shell hook, instant version switches.
This is the proven asdf/mise model.

### F6. Reuse-installed-first resolver (not a SAT solver)

**Decision:** Dependency resolution reuses already-installed satisfying
versions; otherwise picks the highest satisfying version. Conflicts surface as
explicit errors with the conflicting chain.

**Alternatives:** a full SAT solver (à la Cargo).

**Why:** Covers the vast majority of real cases with far less complexity. The
`Resolver` interface is shaped so a SAT solver can be swapped in later if
proven necessary — YAGNI for the foundation.

### F7. First-class AI-agent contract (`--json` + `introspect` + `--dry-run`)

**Decision:** Every command emits a single well-formed JSON object with a
`schema_version`. `gimme introspect --json` exposes the entire CLI surface
(args/flags/exit-codes/output-schemas) as data. `--dry-run` plans any
mutation. Errors are structured (`code`/`message`/`details`/`recoverable`/
`suggested`). Exit code ↔ error category is a fixed, documented map.

**Why:** An agent can `introspect` once, `--dry-run` to plan, execute with
`--json`, and recover from structured errors — without scraping human prose or
guessing output shapes. This also makes a future MCP server a thin adapter.

---

## Security hardening (post-review)

These decisions record the security and correctness fixes made after a
dedicated security/correctness/performance review of the codebase. Each
addresses a concrete defect found during that review.

### S1. Lua sandbox opens only safe libraries (no `package`/`loadlib`)

**Decision:** The sandboxed Lua state is initialized with a custom library list
that omits `LUA_LOADLIBNAME` (the `package` library) and `LUA_DBLIBNAME`
(`debug`), then nil's out `package`, `loadfile`, `dofile`, `load`, `require`,
and the dangerous `os.*`/`io.*` functions.

**Why:** The original code called `luaL_openlibs` (which opens `package`) and
then nil'd `os`/`io`/`loadfile`/`dofile`/`load`/`require`/`debug` — but never
touched `package`. That left `package.loadlib` (which maps to `dlopen`/`dlsym`
on macOS) fully functional: a formula could call
`package.loadlib("/usr/lib/libSystem.B.dylib","system")("rm -rf ~")` for
arbitrary native-code execution, completely defeating the sandbox. This was the
single most severe finding. The fix removes the `package` library at the source
(Lua's `linit.c` is explicitly designed for this — its header invites copying a
custom openlibs), so there is no `loadlib` to nil out in the first place.

### S2. Path containment for all formula-influenced destinations

**Decision:** A new `PathContainment` helper validates that any destination a
formula (declarative `steps` or sandboxed Lua) can influence resolves *under*
the cellar/staging prefix. `ctx:install_dir`, `ctx:mkdir`, and the Stager's
`copy` step all enforce it. Archive-derived filenames are rejected if they
contain `..`, `/`, or `\`. The C dispatch now `luaL_error`s on a rejected path
so the violation aborts the install rather than returning a soft failure.

**Why:** `resolvePath` previously honored absolute paths (`ctx:mkdir("/etc/x")`)
and `..` traversal (`${prefix}/../../../etc`), and `install_dir` moved
archive-controlled filenames verbatim into the prefix. A malicious archive
could write anywhere on disk.

### S3. Safe tar extraction (no traversal, no escaping symlinks, no uid/setuid)

**Decision:** A new `SafeExtractor` lists members before extracting and rejects
absolute paths, `..` segments, and drive-letter paths; extracts with
`--no-same-owner --no-same-permissions` (so the archive can't impose uid/gid or
setuid bits); and post-extract strips any symlink whose target resolves outside
the extract dir. Used by both `ctxExtract` and the Stager's `steps` strategy.

**Why:** bsdtar on macOS does not strip these by default. A crafted release
tarball (whose bytes are pinned by sha256 but whose *structure* is chosen by the
formula author) could write outside the extract dir via `..` members, absolute
paths, or symlink redirection. This is the classic tarball-overwrite class.

### S4. Downloader cache re-verifies on every hit

**Decision:** A cache hit re-hashes the file and compares against `asset.sha256`;
a mismatch evicts the entry and re-fetches.

**Why:** The cache path is the sha256 hex; a hit returned the file with no
re-verification. Any wrong/corrupted/poisoned file at that name (a prior
`--insecure` install, a concurrent race, a manually-placed file, a future
hash-prefixed collision) would be trusted forever. Since the checksum is the
only integrity gate, the cache must not become a trust oracle.

### S5. Install atomicity: rollback committed-but-incomplete versions

**Decision:** The post-commit steps (write receipt, activate shims, update state)
are wrapped so any failure rolls back the just-committed cellar entry and
restores any prior version that was displaced.

**Why:** A failure between `commit` (rename into cellar) and the receipt/shim/state
steps previously left a half-installed version: present in the cellar, absent
from `installed.json`, no receipt, stale or no shim. `rebuild` wouldn't fully
fix it. Now an interrupted install leaves the system as it was before.

### S6. uninstall: dependents check covers any version; no dangling shims

**Decision:** The dependents check runs for *any* uninstall of a version some
receipt depends on (previously only when uninstalling the active version).
After removal, shim repoint/deactivation falls back to reading the removed
version's `bin/` dir when the formula can't be found (tap disabled), so shims
never dangle.

**Why:** Uninstalling a non-active version something depended on would silently
break the dependent. And if the tap was gone, `shims.deactivate` was skipped
entirely, leaving shims pointing at a deleted version.

### S7. Resolver reuses any installed satisfying version (not just active)

**Decision:** When resolving a dependency, the resolver scans *all* installed
versions for one satisfying the constraint (highest first), not just the active
one.

**Why:** A present-but-inactive satisfying version was previously ignored,
triggering an unnecessary re-download and breaking offline installs — violating
the advertised "reuse-installed-first" property.

### S8. SemVer pre-release precedence per spec 2.0.0; build metadata parsed

**Decision:** Pre-release identifiers compare dot-by-dot per SemVer 11 (numeric
identifiers as integers with lower precedence than alphanumeric; more fields
wins when prefix equal). Build metadata (`+...`) is parsed and stored but
ignored for precedence per SemVer 10.

**Why:** Pre-release comparison was a plain lexical string compare, which got
`1.0.0-2` vs `1.0.0-10` backwards (lexical `"2" > "10"`, numeric `2 < 10`),
mis-ordered `rc`/`beta`/`alpha` chains, and failed to parse `+build` metadata
entirely (`1.2.3+build` returned nil). Real-world impact: wrong "latest" for
any formula shipping pre-releases.

### S9. Lock is re-entrant within one process (depth counter)

**Decision:** `Lock` tracks an acquisition depth counter. A nested `acquire()`
on the same instance (already held) just increments depth and returns; `release()`
only unlocks when depth returns to 0.

**Why:** `Installer.install` acquires the lock, then for each unmet dependency
calls `ensureInstalled`, which calls `install` again on the same `World`/`Lock`.
Before this fix, the nested `acquire` re-opened the lock file, overwrote the
stored fd without closing the first, and either deadlocked (`EWOULDBLOCK` spin
for 30s, since a fresh `open()` creates a distinct open-file-description and
`flock` is per-description) or leaked the fd so the lock was never released —
breaking the next gimme command. A single shared `Lock` per process should be
re-entrant; `flock` is meant to be held via one open file description per
holder. A regression test (`DependencyInstallTests.testInstallFormulaWithDependencyDoesNotDeadlock`)
installs a formula-with-a-dep end-to-end, the exact scenario that broke.

### S10. Install rollback fails hard on backup-move failure

**Decision:** Moving the prior version aside before commit no longer uses `try?`.
On `moveItem` failure (e.g. cross-volume `EXDEV`), it falls back to copy+remove
and only proceeds once the backup exists; if neither works, the install aborts
rather than destroying the prior version with no backup.

**Why:** The previous `try?` swallowed a failed backup move, then `commit`
removed the (still-present) prior and installed the new one — leaving the user
with neither the old nor a complete new version, and the rollback path found no
backup to restore. The backup exists specifically to enable rollback; silently
skipping it defeats the atomicity guarantee.

### S11. Config.toTOML validates tap names and escapes URLs

**Decision:** `TapStore.add` rejects tap names outside `[A-Za-z0-9._-]+` and
empty URLs. `Config.toTOML` escapes the URL string (backslash, quote, newline)
for the TOML basic-string value.

**Why:** Unescaped interpolation let a name like `foo]\n[evil]` inject a new
`[evil]` table header, and a crafted URL (containing `"` or newline) broke TOML
parsing — which then silently fell back to `Config.defaults`, wiping the user's
tap list. A crafted valid config could also point taps at attacker-chosen git
URLs. Names are validated at entry (the only path that adds taps), so the
header stays unquoted for round-trip safety; URLs are escaped unconditionally.

### S12. Atomic state writes + self-healing installed.json

**Decision:** `installed.json` and `RECEIPT.json` are written with `.atomic`.
`StateStore` holds a cellar reference; when `loadInstalled()` finds the index
missing or unparseable, it rebuilds from cellar receipts and persists the
repaired index.

**Why:** The non-atomic writes meant a crash/SIGKILL/power loss mid-write left
truncated JSON. `loadInstalled` returned `[:]` on decode failure with no
rebuild, so `gimme list` showed nothing, the resolver couldn't see installed
deps (causing spurious re-downloads), and `uninstall` reported everything as
"not installed" — violating the documented "receipts are source of truth;
index is a rebuildable cache" invariant. The receipts remain authoritative;
the index now genuinely self-heals.

### S13. Uninstall dependents check matches the resolved version

**Decision:** `findDependents(tool:version:)` matches the version being removed
against the `resolved` version recorded in dependents' receipts, not just the
tool name.

**Why:** The previous name-only check refused removing *any* version of a tool
that had any dependent — so `gimme uninstall node@20` was blocked when only
`node@18` was a dependency, making multi-version management (the product's core
feature) painful for shared dependencies. Matching `Receipt.DepRef.resolved`
(which is populated at install time with the actual resolved version) means an
unused version uninstalls freely while a depended-on version is still
protected.

### S14. TapStore.remove validates the tap name

**Decision:** `remove(name:)` applies the same charset check as `add` (via a
shared `validateTapName` helper). The validator rejects `.` and `..` explicitly
in addition to the charset, since `.` is an allowed character but `..` as a
whole name is a path-traversal.

**Why:** `remove` built the path `paths.taps.appendingPathComponent(name)`,
which honors `..` segments. An unchecked `gimme tap remove "../../.ssh"`
resolved to `~/.gimme/taps/../../.ssh` = `~/.ssh` and deleted it — an
arbitrary-directory-deletion primitive reachable from the CLI. The `add` path
was already validated (S11), but `remove` was missed; both now share one
validator.

### S15. Shim script names are validated as shell/path safe

**Decision:** A new `NameSafety` helper validates the package name, version
strings, and provided bin names against a filename/shell-safe charset
(alphanumerics plus `. _ + -`, with `.`/`..` rejected as whole names). It runs
in `ManifestLoader.validate` (rejects malicious taps at load time) and again in
`ShimManager.activate` (defense in depth).

**Why:** `ShimManager.shimScript` interpolates `tool`, `version`, and `bin`
raw into a generated `#!/bin/sh` script *and* into path components
(`cellar/<tool>/<version>/bin/<bin>` and `~/.gimme/bin/<bin>`). None were
validated. A tap with `bin = ["foo\";rm -rf ~ #"]` produced
`exec ".../bin/foo";rm -rf "$HOME" #" "$@"` — command injection on the next
invocation of the tool. A `bin = ["../evil"]` wrote the shim outside
`~/.gimme/bin`. These values cross a trust boundary (tap author → user's shell)
and must be names, not shell fragments.

### S16. pinned.json is written atomically and under the lock

**Decision:** `StateStore.pin`/`unpin` use `.atomic` writes. `Gimme.runPin`/
`runUnpin` acquire the lock before mutating (matching `install`/`uninstall`/
`switchActive`).

**Why:** `pinned.json` is the authoritative user-intent store (per the file's
own comment), yet it was written non-atomically and without the lock. A crash
mid-write left a corrupt file, and `loadPinned` returns `[:]` on decode failure
with no self-heal — so a corrupt file *silently discarded every pin the user
set*. Without the lock, two concurrent gimme commands (e.g. `gimme pin a` and
`gimme install b`) doing read-modify-write could interleave and lose one
update. Pins are user intent that can't be reconstructed from the cellar, so
atomic writes (not self-heal) are the prevention.

### S17. Downloader caps size and streams the hash

**Decision:** `sha256(of:)` streams the file in 64 KiB chunks via `FileHandle`
rather than loading it all into memory. `fetch` enforces a configurable
`maxDownloadBytes` (default 2 GiB) for both `file://` copies and HTTP
downloads (via `expectedContentLength`/file size), rejecting larger assets with
a `.network` error before the checksum gate runs.

**Why:** The previous whole-file `Data(contentsOf:)` hash loaded entire release
tarballs into RAM, and there was no upper bound on download size — a
compromised mirror (or a `file:///dev/zero`-style asset under `--insecure`)
could fill the disk before the sha256 gate ran. The cap is generous (2 GiB
covers real tool tarballs) and the streaming hash removes the memory ceiling.

### S18. SafeExtractor extracts member-by-member and verifies containment after each

**Decision:** Instead of one bulk `tar xf` followed by a post-extract symlink
strip, `SafeExtractor` now extracts each member individually in archive order
and, after writing each, verifies the resolved on-disk path (symlinks resolved)
stays within the dest root. A member that wrote through an escaping symlink
created by an earlier member resolves outside the root → abort + clean up the
whole dest. The post-extract strip remains as defense in depth.

**Why:** The previous post-extract-only strip left a window between `tar xf`
and the walk where a carefully ordered archive (symlink member, then a member
that writes through it) could escape. Per-member extraction + per-member
containment closes that window: the second member's check resolves through the
first member's symlink and aborts before the write can do harm.

### S19. Livecheck bounds the regex input against ReDoS

**Decision:** `parseVersionStatic` caps the input fed to the formula-supplied
regex at `maxRegexInputBytes` (1 MiB) before matching. Version strings appear
early on real release pages, so the cap doesn't lose valid matches in practice.

**Why:** A formula-supplied regex is applied to fetched, untrusted HTML/JSON
via `NSRegularExpression` (ICU, backtracking). A vulnerable pattern (e.g.
`(a+)+`) against adversarial page content (a compromised livecheck URL) can
catastrophically backtrack and hang the process. Capping the input bounds the
worst-case work; combined with only requesting `firstMatch`, the regex path is
no longer an unbounded CPU sink.

### S20. Lock is thread-safe and opens with O_NOFOLLOW

**Decision:** The `fd`/`depth` fields are guarded by an `os_unfair_lock`,
removing the latent data race (today all access is single-threaded, but this
makes the lock safe under future concurrency). The lock file is opened with
`O_CREAT | O_RDWR | O_NOFOLLOW`, refusing to follow a symlink at the lock
path, with a fallback plain open for legacy symlinked lock files.

**Why:** Without `O_NOFOLLOW`, an attacker with write access to
`~/.gimme/state` could plant a symlink at `gimme.lock` pointing at an
arbitrary file; the holder-PID write would clobber the target. The thread-safety
guard is forward-looking — `flock` re-entrancy (S9) already works
single-threaded, but the counter must be safe if gimme ever adopts concurrency.

### S21. TOML comment-strip tracks backslash escapes

**Decision:** `stripComment` tracks `\` escapes inside basic strings so an
escaped quote (`\"`) doesn't toggle the string closed and expose a later `#`
as a comment.

**Why:** A formula value like `url = "https://x/y#z"` (a URL with a fragment)
followed by a real `#` comment was being truncated at `#z` because the bare
`#` handling didn't account for escapes. The fix mirrors `parseBasicString`'s
escape handling so the two agree.

### S22. Cellar.scanAll is NOT memoized (tried, reverted)

**Decision:** `Cellar.scanAll()` always reads fresh; there is no per-instance
cache. `Cellar` is a class (reference type) so `StateStore` can hold a stable
reference for self-healing, but the scan itself is uncached.

**Why:** A memoization attempt (invalidate on `commit`/`remove`) caused a real
staleness regression: receipts and dirs are written by paths *outside* Cellar's
mutations (the install-atomicity backup, the StateStore self-heal trigger,
tests, external tooling), so the memo could return a pre-mutation snapshot and
the dependents check would miss a just-installed dependent. The performance
gain (avoiding re-walks within one command) wasn't worth the correctness risk.
If profiling later shows `scanAll` is hot, the safe caching boundary is one
logical command with explicit invalidation hooks added at *every* writer — a
larger change than warranted now.

### S23. SafeExtractor: bulk extract + post-extract escape rejection (per-member reverted)

**Decision:** `SafeExtractor.extract` does ONE bulk `tar xf` into dest, then a
post-extract walk that rejects anything that escaped dest — both escaping
symlinks (the redirect primitive) and regular files whose realpath is outside
dest (a write that went *through* an escaping symlink created by an earlier
member). On any escape, the artifact is removed and dest is cleaned up,
aborting the install.

**Why:** S18 originally used per-member extraction (one `tar xf <member>` per
member, with a containment check after each) to close the write-through-symlink
window. That was secure but O(n²) for gzipped archives — each per-member
invocation re-decompressed the gzip stream from the start (gzip isn't seekable),
taking ~28s for a 200-member tarball. Verification confirmed bsdtar/macOS
genuinely follows symlinks during extraction, so the threat is real — but the
per-member implementation imposed a performance cliff on the most common asset
type (large gzipped release tarballs).

The bulk + post-walk design is O(n) and still catches the escape: a file
written through an escaping symlink lands at a realpath outside dest, which the
walk detects (and undoes) before the install proceeds. This is the same
defense-in-depth shape as the Cellar memoization tradeoff (S22): prefer the
design whose correctness doesn't depend on every writer being instrumented.

### S24. mise `prefix:<major>` and bare-major queries mean "any major.x.x"

**Decision:** `MiseVersionSpec` distinguishes `prefixMajor(Int)` (from
`prefix:3`) from `prefix(Int, Int)` (from `prefix:1.19`). `VersionConstraint`
gained a `.major(Int)` case and now parses a bare major (`"3"`) as `.major(3)`
= any `3.x.x`, while `"3.0"` stays `majorMinor(3, 0)` = any `3.0.x`.

**Why:** mise's `prefix:3` means "any 3.x.x", but gimme was collapsing it to
`prefix(3, 0)` → query `tool@3.0` → resolver `majorMinor(3, 0)` = "any 3.0.x".
A user writing `go prefix:1` or `python prefix:3` would silently get only the
`3.0.x` line (or a confusing "no version satisfies" if no `3.0.x` exists),
when mise would have picked the highest `3.x.x`. The fix aligns gimme's
bare-major semantics with the mise/asdf/npm convention, which also makes
`gimme tool@3` do the intuitive thing (any 3.x) for direct queries.

### S25. `--tap` fails loud until implemented

**Decision:** The `--tap` global flag is documented in `Introspect` and parsed
by the CLI, but the scoped-search behavior was never implemented. Rather than
silently ignoring it (which violates the agent contract — an agent reading
`introspect` would pass `--tap` expecting scoped behavior and get unscoped
results), `main.swift` now exits nonzero with a structured `--tap is not yet
implemented` error when the flag is set.

**Why:** A documented flag that silently does nothing is worse than no flag:
it misleads agents and users into thinking they've scoped an operation when
they haven't, potentially installing from an unintended tap. Failing loud makes
the gap visible and unblocks a future implementation that threads the filter
through `TapStore.find`/`allFormulae`/`Resolver`.

### S26. Unknown CLI flags exit nonzero

**Decision:** The hand-rolled arg parser now `exit(1)`s on any unrecognized
flag, after writing a `gimme: unknown flag <x>` message to stderr.

**Why:** Previously an unknown flag was written to stderr but parsing continued
with exit 0. A typo in a safety-critical flag (`--dry-run`, `--force`,
`--insecure`, `--no-mise`) would cause real side effects with no error signal
— `gimme install foo --dry-run --typo` would actually install. Most CLI tools
exit nonzero on unknown flags for exactly this reason; the structured `--json`
contract also benefits (the previous behavior emitted `ok: true` while a
warning went to stderr).

---

## Mise/asdf interop (follow-on)

### M1. Interop, not parity — global model only

**Decision:** gimme reads `.tool-versions`/`mise.toml` and installs what they
declare via gimme formulae, but does NOT attempt per-directory activation.
gimme stays a global/static-shim tool (the Homebrew model); mise/asdf are
per-directory (a different paradigm).

**Alternatives:** become a per-directory runtime manager (reimplement mise's
core trick).

**Why:** The two activation models don't merge cleanly. Per-project resolution
would require the shim itself to re-resolve on every invocation by walking the
dir tree — that's reimplementing mise. "Full mise support" isn't a feature you
bolt on; it's a different product. Interop (read its config, defer to it) is
cheap, high-value, and doesn't compromise gimme's design.

### M2. Auto-detect on `gimme install` (no args)

**Decision:** `gimme install` with no positional arg auto-detects mise config
in the cwd or a parent and installs the batch. `--no-mise` opts out;
`--from-mise` forces.

**Alternatives:** explicit flag only (less ergonomic); auto-detect without an
opt-out (surprising).

**Why:** Most mise-like UX (cd into a project, run `gimme install`) while
keeping an opt-out for users who want `gimme install` to stay explicit. The
auto-detect prints a notice so it's never silent.

### M3. Skip mise-managed tools (never clobber)

**Decision:** If mise/asdf already manages a tool on PATH, gimme skips
installing it. The two never fight.

**Alternatives:** gimme always installs and its shim wins; per-tool prompt.

**Why:** Safe, predictable, respects the user's existing setup. A skip is
reported in the batch result as `skipped_managed` with the manager named, so
the user always sees why.

### M4. PATH-resolve + standardized-path detection (no mise dependency)

**Decision:** To decide if mise manages tool X, gimme resolves X on PATH
(excluding its own bin), and checks if the PATH entry lives under a known
shims dir (`$MISE_DATA_DIR/shims`, `~/.local/share/mise/shims`,
`~/.asdf/shims`).

**Alternatives:** shell out to `mise` (couples gimme to mise being installed,
breaks if mise changes output); config-only (too conservative).

**Why:** Self-contained, no mise-as-a-dependency, robust to how mise was
installed (curl|sh, brew, mise-installs-itself) because it keys off the shim
*location*. Crucial implementation detail: we compare the **standardized PATH
entry path** (NOT the symlink-followed realpath) — following the symlink all
the way out to the final binary would lose the "lives in shims dir" signal.

### M5. Honest global-vs-per-dir caveat (documented)

**Decision:** PATH-based detection sees the globally-active version of a tool,
not per-directory ones. If mise manages `node` only inside certain project dirs
and you run `gimme install` from a dir where mise isn't active for `node`,
gimme will install its own `node`.

**Why:** This is the safe direction (user gets a working tool rather than a
confusing skip) and a deliberate consequence of gimme's global model. A future
per-directory detection strategy (asking `mise current <tool>` directly) is
reserved; the `MiseDetector` interface already accommodates it without engine
changes.

### M6. Unsupported specs skipped, not errored

**Decision:** `ref:` (VCS-ref builds), `path:` (local-dir runtimes), and
`sub-` (version arithmetic) specs are reported as `skipped_unsupported` in the
batch result — they don't abort the run.

**Alternatives:** error the whole batch on an unsupported spec.

**Why:** A project's `.tool-versions` often mixes supported and unsupported
tools; erroring the whole batch would prevent installing the supported ones.
Per-tool status gives the full picture in one run.

### M7. Batch exit code is partial-failure-aware

**Decision:** Exit 0 if nothing failed and at least one tool installed; exit 1
if any tool failed OR nothing installed. Individual failures don't abort the
batch — the JSON carries per-tool status.

**Why:** CI/scripts can detect partial failure via exit code while still
getting the structured per-tool breakdown in the JSON. Required restructuring
`Gimme.dispatch` to return `([json], exitCode)` so commands can signal
non-zero exits alongside their payload (previously exit code came only from
thrown errors).

### M8. Walk up to `.git` (project root), with a depth cap

**Decision:** Config discovery walks up from cwd collecting
`.tool-versions`/`mise.toml`, stopping at the first directory containing
`.git` or the filesystem root. Defensive depth cap of 64.

**Why:** Matches the common "project + global" layering. The depth cap is
hard-won: an early test hung because an unbounded walk from a temp dir
traversed the entire filesystem (slow). The cap makes traversal
unconditionally bounded.

### M9. `lts`/aliases treated as "newest available"

**Decision:** mise aliases like `lts`, `stable` resolve to gimme's "newest
available" (no constraint), not to upstream LTS tags.

**Why:** gimme's foundation doesn't track upstream LTS tags. Best-effort
resolution installs a working version; the result reports what was actually
chosen so the user can see. Tracking LTS tags would be a future enhancement.

---

## Reserved follow-ons (explicitly NOT done)

- **Per-directory detection via `mise current <tool>`** — `MiseDetector` and
  `Manager` already accommodate this; only the detection internals change.
- **`ref:` / `path:` spec support** — would need source builds (foundation's
  reserved `strategy = "source"`) and a local-dir provider.
- **Source-based builds** (`strategy = "source"`) — enum value reserved.
- **Homebrew formula/cask compatibility** — separate `GimmeBrew` target later.
- **Native GUI app** (`GimmeUI`) — separate target later.
- **MCP server** (`gimme mcp`) — reserved command; the `--json`/`introspect`
  contract makes it a thin adapter.
- **Writing mise config** (`gimme init`).
