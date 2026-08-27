#!/bin/sh
# gimme — build the drag-to-Applications installer DMG for Gimme.app.
#
# Usage: scripts/make-dmg.sh <output.dmg> [volume-name]
#
# Shared by scripts/package-mac.sh (local signing pipeline) and the CI
# release workflow so both ship the same installer. Requires create-dmg
# (brew install create-dmg); app/Gimme.app must already be built, signed,
# and — when notarizing — stapled (the staple travels inside the DMG).
#
# Layout contract (see scripts/make-dmg-background.py): 660x400 window,
# 96px icons, Gimme.app at (132, 160), Applications symlink at (432, 160),
# background app/dmg-background.tiff (retina TIFF from the committed PNGs).

set -eu

DMG="${1:?usage: scripts/make-dmg.sh <output.dmg> [volume-name]}"
VOLNAME="${2:-gimme}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

[ -d app/Gimme.app ] || { echo "error: app/Gimme.app not built" >&2; exit 1; }
command -v create-dmg >/dev/null 2>&1 || {
    echo "error: create-dmg not found. Install it first: brew install create-dmg" >&2
    exit 1
}

# Retina background TIFF from the committed PNGs (1x + 2x in one image).
[ -f app/dmg-background.tiff ] || \
    tiffutil -cathidpicheck app/dmg-background@2x.png app/dmg-background.png \
        -out app/dmg-background.tiff

# Source folder must contain only the app; create-dmg adds the
# Applications symlink itself. create-dmg's progress output is noisy, so
# it goes to a log that is only printed (filtered) on failure or once.
# create-dmg cd's into the DMG's parent, so that must exist first.
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
STAGE="$(mktemp -d)"
LOG="$(mktemp)"
trap 'rm -rf "$STAGE" "$LOG"' EXIT
cp -R app/Gimme.app "$STAGE/"
if ! create-dmg \
    --volname "$VOLNAME" \
    --background app/dmg-background.tiff \
    --window-pos 200 120 --window-size 660 400 \
    --icon-size 96 \
    --icon "Gimme.app" 132 160 \
    --app-drop-link 432 160 \
    --hide-extension "Gimme.app" \
    --no-internet-enable \
    "$DMG" "$STAGE" >"$LOG" 2>&1; then
    grep -vE "Copying|progress" "$LOG" || true
    rm -f "$DMG"
    echo "error: create-dmg failed" >&2
    exit 1
fi
grep -vE "Copying|progress" "$LOG" || true

test -s "$DMG"
hdiutil verify "$DMG" >/dev/null
echo "  ✓ DMG ready: $DMG"
