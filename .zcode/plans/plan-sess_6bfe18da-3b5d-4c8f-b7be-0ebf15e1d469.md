## Plan: Versioning + GitHub Auto-Builds + Binary install.sh

### Problem
1. `gimme --version` doesn't exist (it's parsed as an install flag, so it errors with "unknown command")
2. No version constant, no git tags, no CI
3. `install.sh` builds from source (slow) AND gates on the broken `--version` (fails on fresh installs)
4. No `.github/workflows/` at all

### Step 1: Add a version constant and `gimme --version` command

**Create** `Sources/GimmeCore/Version.swift`:
```swift
public enum GimmeVersion {
    /// Updated by the release CI from the git tag. Defaults to dev during local builds.
    public static let current = "2.0.0-dev"
}
```

**Modify** `Sources/gimme/main.swift`:
- Intercept `--version` / `-v` as the **first arg** (before `parseArgs`), right alongside the existing `--help` check, printing `gimmie \(GimmeVersion.current)`.
- This does NOT break `gimme install foo --version 1.0` — that `--version` is not the first arg, so it falls through to `parseArgs` as before.

**Result:** `gimme --version` → `gimmie 2.0.0-dev`; the installer's `--version` gate passes.

### Step 2: Add a GitHub Actions release workflow

**Create** `.github/workflows/release.yml`:
- **Trigger:** push of tags matching `v*` (e.g. `v2.0.0`)
- **Runner:** `macos-latest` (arm64 Apple Silicon)
- **Steps:**
  1. Checkout
  2. Extract version from the tag: `VERSION=${GITHUB_REF_NAME#v}` (strips the `v` prefix)
  3. Overwrite `Version.swift` with the real version: `sed -i '' "s/2.0.0-dev/$VERSION/" Sources/GimmeCore/Version.swift`
  4. `swift build -c release`
  5. `swift test` (gate release on green tests)
  6. Strip the binary (`strip .build/release/gimme`)
  7. Create a tarball: `tar czf gimme-darwin-arm64.tar.gz -C .build/release gimme`
  8. Build the `.app` bundle via `sh app/build-app.sh`, update its Info.plist version, tarball it too
  9. Create a GitHub Release via `gh release create` with both tarballs attached

**Create** `.github/workflows/ci.yml`:
- **Trigger:** push to `main`, PRs
- **Runner:** `macos-latest`
- **Steps:** checkout, `swift build`, `swift test` — fast feedback on every push

### Step 3: Rewrite install.sh to download prebuilt binaries

**Rewrite** `install.sh`:
- **Primary path:** query the GitHub Releases API (`https://api.github.com/repos/gregnazario/gimme/releases/latest`), download `gimme-darwin-arm64.tar.gz` (detect arch: `uname -m` → `arm64` or `x86_64`), extract, install.
- **Fallback:** if no binary is available for the arch (e.g. x86_64 which we don't pre-build), fall back to the existing source-build path (`swift build -c release`).
- **Man page:** ship `gimme man` output if the binary supports it, else skip gracefully (already non-fatal).
- **App:** download the `.app` tarball if available, or build from source as fallback.
- **Version verification:** the `gimme --version` gate now works (Step 1).

### Step 4: Tag the first release

After implementing:
1. Commit all changes
2. Tag: `git tag v2.0.0`
3. Push: `git push origin main --tags`
4. The workflow runs automatically, builds, and creates the release

### Files to create/modify
- **Create:** `Sources/GimmeCore/Version.swift`
- **Create:** `.github/workflows/release.yml`
- **Create:** `.github/workflows/ci.yml`
- **Modify:** `Sources/gimme/main.swift` (add `--version` interception)
- **Modify:** `install.sh` (binary download + source fallback)
- **Modify:** `README.md` (add install section with the curl|sh flow)