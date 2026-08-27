# Signing & Notarization Setup

Everything the audit's one open item needs. Two independent halves; both are
one-time and interactive (secrets only you hold). Once done, every tagged
release is signed + notarized in CI, and `just package` notarizes locally.

## 1. CI (release.yml) — make GitHub releases signed + notarized

The workflow already contains the signing/notarization steps; they activate
when these repo secrets exist. Create them at
`https://github.com/gregnazario/gimme/settings/secrets/actions`
(or `gh secret set` from a clone):

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | base64 of the exported .p12 (see below) |
| `MACOS_CERTIFICATE_PWD` | the .p12 export password you choose |
| `APPLE_DEVELOPER_ID` | `Developer ID Application: Gregory Nazario (4SRDAWJ9G7)` |
| `APPLE_ID` | your Apple ID email |
| `APPLE_ID_PWD` | an app-specific password (appleid.apple.com → Sign-In and Security → App-Specific Passwords) |
| `APPLE_TEAM_ID` | `4SRDAWJ9G7` |

Export the certificate as .p12 (Keychain Access → My Certificates →
"Developer ID Application: Gregory Nazario (…)" → File → Export Items →
.p12, choose a password), then:

```sh
base64 -i cert.p12 | pbcopy        # paste into the MACOS_CERTIFICATE secret
# or: gh secret set MACOS_CERTIFICATE < cert.p12.base64
```

## 2. Local — notarize `just package` artifacts

The one-time interactive step `scripts/package-mac.sh` needs (keychain
profile `gimme-notary`):

```sh
xcrun notarytool store-credentials gimme-notary \
  --apple-id <your-apple-id> \
  --team-id 4SRDAWJ9G7 \
  --password <app-specific-password>
```

Then `sh scripts/package-mac.sh <version>` (no `--skip-notarize`)
notarizes + staples the CLI, the app, and the DMG. Until this is stored,
local packaging uses `--skip-notarize` (signed but not notarized).

## Verifying it worked

- CI: the next tagged release's `spctl -a -t open` on the DMG shows
  "accepted"; the release assets are signed.
- Local: `spctl -a -t open --context context:primary-signature dist/GimmeUI-<v>-arm64.dmg`
  reports accepted, and `xcrun stapler validate` passes.

## Notes

- Self-update doesn't depend on this: it verifies SHA256SUMS and runs the
  curl path (no Gatekeeper quarantine). Notarization matters for anyone
  downloading the DMG from a browser.
- Every tagged release attaches the DMG (`GimmeUI-<version>-arm64.dmg`,
  built by CI via the same `scripts/make-dmg.sh` as `just package`); the
  versionless tarballs serve the CLI, install.sh, and in-app self-update.
