# Installed/update fetch performance — design

Date: 2026-08-27
Status: implemented (uncommitted), incl. round 2 below

## Problem

`gimme outdated` is fast when the 5-minute engine cache is warm (28 ms measured)
but pays a full re-fetch every time that TTL lapses: 2.6–6.9 s measured on the
reference machine (483 brew items, 137 gems, 32 cargo crates). Causes:

1. **Per-package HTTP fan-out with no response caching.** Eight adapters
   (gem, cargo, npm, bun, pnpm, yarn, uv, pipx) fetch one registry doc per
   installed package on every expired run. The App Store adapter already
   caches each lookup for 6 h and Homebrew caches its search indexes for 6 h;
   the pattern was never applied to the registry adapters.
2. **Oversized npm-family requests.** npm/bun/pnpm/yarn `outdated()` download
   the full packument to read one field. Measured for `typescript`:
   full packument 2.0 MB / 0.67 s vs the dist-tags endpoint 179 B / 0.29 s.
3. **Connection throttling.** `URLSessionHTTPClient` uses `URLSession.shared`,
   capped at ~6 connections per host, so large fan-outs (137 gem lookups)
   serialize in waves.

`gimme list` is subprocess-bound (~0.6 s brew, concurrent, engine-cached) and
is not a target of this change.

## Design

### 1. Per-package latest-version caching (adapter level)

Extend the App Store/brew-index pattern to the eight registry adapters:

- Each gains an injectable `indexCache: Cache? = nil` (nil in unit tests → no
  caching, hermetic; `Gimme.defaultRegistry()` passes the shared disk cache).
- `outdated()` consults the cache for each package's latest-version string
  before hitting the network; a fresh value is stored after fetch. Keyed
  `"<manager>:latest:<name>"` with a 1 h TTL (`latestTTL`), mirroring
  `AppStoreManager.lookup` / `HomebrewManager.indexTTL`.
- The npm-family adapters share one key namespace
  (`"npm-registry:latest:<name>"`) since all four query registry.npmjs.org —
  one cached fetch serves npm, bun, pnpm, and yarn.

Freshness tradeoff: a release published within the hour is detected at most
1 h late. Precedent in this repo: App Store lookups 6 h, self-update 12 h.
`--refresh` / GUI Refresh bypass the *engine* result cache but not these
response caches — same as the existing App Store behavior; refresh means
"redo the computation," not "re-download the world."

### 2. Lighter npm-family endpoint

`NpmRegistry` gains `distTagsURL(for:)` (percent-encoding scoped names:
`@babel/core` → `@babel%2Fcore`) and a shared
`latestVersion(http:indexCache:name:)` helper that GETs
`/-/package/<name>/dist-tags` through the cache. npm/bun/pnpm/yarn
`outdated()` use it; `info()` keeps the full packument (needs description,
homepage, license).

### 3. Higher HTTP concurrency

`URLSessionHTTPClient` defaults to a dedicated `URLSession` with
`httpMaximumConnectionsPerHost = 16` (registries are CDNs; 6 was serializing
the fan-out). `init(session:)` remains injectable.

### 4. Shared cache helper

`Cache.fetchThrough(key, ttlSeconds, fetch:)` — return the cached value if
fresh, otherwise await `fetch`, store non-nil results, return them. Used by
gem/cargo/uv/pipx (npm-family goes through the NpmRegistry helper, which uses
it too). Failed lookups are not cached (same never-false-flag bias as App
Store).

## Round 2 (same day): force refresh, list memoization, stale-while-revalidate

The three follow-ups, now implemented:

### Force refresh (escape hatch for the response caches)

- Protocol gains `outdated(forceRefresh:)` (default forwards to `outdated()`);
  cache-holding adapters (the 8 registry ones + App Store lookups) bypass the
  cache read, refetch, and overwrite the entry.
- Engine: `Gimme.outdated(from:refresh:force:)` — force also bypasses the
  engine result cache.
- CLI: `--force` (implies `--refresh`) on `outdated`; the historically inert
  `--no-cache` is now an alias.
- GUI: the Updates view's Refresh button became a menu with Refresh and
  Force Refresh.

### Shared listInstalled between concurrent list/outdated

Rather than a protocol seam change, adapters with subprocess-backed
listInstalled (homebrew, gem, cargo, npm, bun, pnpm, yarn, uv, pipx) memoize
the result in-process for 5 s (`InProcessMemo`), so the GUI's concurrent
`loadAll` spawns each `brew list`/`gem list`/… once instead of twice.
Mutating ops (install/uninstall/upgrade) clear the memo so post-action reads
reflect the new state.

### Stale-while-revalidate (GUI launch)

- `Cache.get` gains `allowStale`; engine `list/outdated` gain `preferStale`.
- The store's auto-load path reads preferStale (paints expired disk cache
  instantly) and, when `Gimme.hasExpiredListOrOutdatedCache()` says any entry
  is stale, follows with a background normal-semantics pass that republishes.
  Cold cache (no entries) still blocks on the live fetch. Explicit refreshes
  stay fully blocking. CLI never passes preferStale.

## What remains out of scope

- PyPI has no lightweight latest-version endpoint, so uv/pipx still download
  the full PyPI JSON on first fetch per hour; caching addresses the repeat
  cost.
- Homebrew's outdated stays its own `brew outdated --json=v2` subprocess
  (single call, no response cache involved).

## Testing

In-process, stub `http:`/`process:` seams per house rules:

- `CacheTests`: fetchThrough caches (second call does not re-fetch), nil
  fetches are not cached.
- `NpmRegistryTests`: dist-tags URL encoding (scoped and plain).
- npm/bun/pnpm/yarn suites: `outdated()` hits the dist-tags URL (stub keyed
  on the new URL — fails against the old packument code); second run served
  from cache with a stub-less HTTP client and zero requests (App Store test
  pattern).
- gem/cargo/uv/pipx suites: cached second run, zero requests.
- `defaultRegistry()` wiring is compile-level only (tests must not construct
  it — TestIsolationTests).

## Verification on the real machine

Read-only verbs only: rebuild release, `time gimme outdated --refresh` twice —
first run populates `~/.cache/gimme/*:latest:*.json`, second run should drop
to subprocess-only time; warm engine-cache run unchanged (~30 ms).
