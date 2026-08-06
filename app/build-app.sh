#!/bin/sh
# Builds the GimmeUI app bundle (.app) with proper Info.plist, icon, and structure.
# Run from the repo root: sh app/build-app.sh
# Output: app/Gimme.app

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/release"
APP_DIR="$REPO_ROOT/app/Gimme.app"

echo "==> Building GimmeUI (release)..."
cd "$REPO_ROOT"
swift build -c release --product GimmeUI 2>&1 || { echo "Build failed"; exit 1; }

BINARY="$BUILD_DIR/GimmeUI"
[ -s "$BINARY" ] || { echo "Binary not found or empty"; exit 1; }

echo "==> Assembling .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy the executable.
cp "$BINARY" "$APP_DIR/Contents/MacOS/GimmeUI"
chmod 755 "$APP_DIR/Contents/MacOS/GimmeUI"

# Copy the Info.plist.
cp "$REPO_ROOT/app/Info.plist" "$APP_DIR/Contents/Info.plist"

# Copy the app icon.
if [ -f "$REPO_ROOT/app/AppIcon.icns" ]; then
    cp "$REPO_ROOT/app/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
    echo "  ✓ AppIcon.icns installed"
else
    echo "  (no AppIcon.icns; run the icon generation first)"
fi

echo "==> App bundle ready: $APP_DIR"
echo ""
echo "To open: open $APP_DIR"
echo "To install to /Applications: cp -R $APP_DIR /Applications/"
