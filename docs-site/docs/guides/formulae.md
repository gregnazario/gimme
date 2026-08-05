# Formula format

A formula is a directory containing `formula.toml` (declarative manifest) and
optionally an `install.lua` (sandboxed logic). Metadata is type-checked; the
Lua runtime is restricted to a controlled `ctx` API.

## The manifest

```toml
[package]
name = "hello"
desc = "A demo tool"
homepage = "https://example.com"
license = "MIT"

[[version]]
ver = "1.0.0"
released = "2026-01-01"

[[version.asset]]
os = "macos"
arch = "arm64"
url = "https://example.com/hello-1.0.0.tar.gz"
sha256 = "..."     # required

[install]
strategy = "steps"          # or "lua"

[[install.step]]
extract = "${asset}"
[[install.step]]
copy = { from = "hello-1.0.0", to = "${prefix}" }

[[provides]]
bin = ["hello"]

[livecheck]
strategy = "none"
```

### Versions & assets

Each `[[version]]` declares one or more `[[version.asset]]` entries. An asset
matches a host when its `os`/`arch` agree (unset means "any"). **Every asset
must declare `sha256`** — `gimme install` refuses on mismatch (`--insecure`
bypasses per-install, loudly).

### Install strategies

`[install].strategy` selects how the asset becomes a cellar prefix:

| Strategy | When to use |
|---|---|
| `steps` | The common case: extract tarball, move into prefix. Pure data, no code execution. ~80% of formulae. |
| `lua` | Logic required (conditional layout, post-install). Runs `install.lua` in the sandbox. |
| `source` | Build from source. **Reserved** (follow-on). |

### Livecheck

`[livecheck].strategy` controls "latest" discovery:

| Strategy | Meaning |
|---|---|
| `none` (default) | Latest = highest version literally declared in the manifest. No network on `update --check`. |
| `github-release` | Hit the GitHub releases API, parse the tag with `regex`. |
| `url-match` | Fetch a listing page, regex out version strings. |
| `lua` | A sandboxed `livecheck(ctx)` returning a version. |

## The `steps` strategy

Declarative, no code. The engine runs these directly:

```toml
[[install.step]]
extract = "${asset}"                 # tarball -> work dir
[[install.step]]
copy = { from = "hello-1.0.0", to = "${prefix}" }
```

Variables: `${asset}` (the verified download path), `${prefix}` (the cellar
prefix the install is building). Copy destinations are validated to stay within
the staging prefix (path-traversal-safe).

## The `lua` strategy

When logic is required:

```lua
function install(ctx)
  local asset = ctx:download()        -- staged + sha256-verified
  local dir   = ctx:extract(asset)    -- tgz/tbz/zip, extraction-hardened
  ctx:install_dir(dir .. "/payload")  -- move into the cellar prefix
  ctx:set_provides({"hello"})         -- declare binaries
  ctx:mkdir("${prefix}/share/man")
end
```

### The `ctx` sandbox API (the only thing a formula can call)

| Method | Returns | Notes |
|---|---|---|
| `ctx:download()` | staged asset path | sha already verified |
| `ctx:extract(path)` | extracted dir | tar-hardened (no traversal/escaping symlinks) |
| `ctx:install_dir(src)` | moves `src` contents into prefix | filename components validated |
| `ctx:mkdir(rel)` | creates dir under `${prefix}` | destination must stay in prefix |
| `ctx:set_provides(list)` | declares bin names | each name shell/path-safe |
| `ctx:dep_path(name)` | path to a resolved dependency | |
| `ctx:host()` | `{os, arch, macos_version}` | |

### Blocked by construction

`os.execute`, `io.popen`, `loadfile`, `dofile`, `load`, `require`, `debug`,
and `package` (so `package.loadlib`/`dlopen`) are all unavailable. The Lua
state opens only a safe subset of standard libraries. A formula cannot run
arbitrary native code or shell.

## Provenance

- Every `[[version.asset]]` **must** declare `sha256`; manifest decode fails
  otherwise.
- `gimme install` refuses on checksum mismatch.
- The manifest itself is integrity-checked against the tap's git commit
  (formula provenance = tap trust).
