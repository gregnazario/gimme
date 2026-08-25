#!/bin/sh
# gimme — POSIX sh installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/gregnazario/gimme/main/install.sh | sh
#   # or, to a custom dir:
#   curl -fsSL https://raw.githubusercontent.com/gregnazario/gimme/main/install.sh | GIMME_INSTALL_DIR=/opt/bin sh
#   # or from a local clone:
#   sh install.sh [--prefix <dir>]
#
# What it does:
#   1. Checks for macOS.
#   2. Downloads a prebuilt binary from GitHub Releases (fast path).
#   3. Falls back to building from source if no binary is available.
#   4. Installs the binary to ~/.local/bin (or GIMME_INSTALL_DIR).
#
# Environment overrides:
#   GIMME_INSTALL_DIR   where to install the binary (default: ~/.local/bin)
#   GIMME_REPO          git URL (default: https://github.com/gregnazario/gimme)
#   GIMME_BRANCH        branch/tag to build from source (default: main)
#   GIMME_SKIP_APP      set to 1 to skip the .app installation

set -eu

# --- defaults ---
REPO="${GIMME_REPO:-https://github.com/gimme/gimme}"
REPO="${GIMME_REPO:-https://github.com/gregnazario/gimme}"
BRANCH="${GIMME_BRANCH:-main}"
INSTALL_DIR="${GIMME_INSTALL_DIR:-${HOME}/.local/bin}"
SKIP_APP="${GIMME_SKIP_APP:-0}"
APP_DIR="${GIMME_APP_DIR:-/Applications}"

# Allow --prefix <dir> to override INSTALL_DIR (local-clone mode).
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) INSTALL_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# --- helpers ---
warn() { printf '%s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- preflight ---
[ "$(uname -s)" = "Darwin" ] || fail "gimme is macOS-only. Your OS: $(uname -s)"

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)   ARCH_TAG="arm64" ;;
    x86_64)  ARCH_TAG="x86_64" ;;
    *)       fail "unsupported architecture: $ARCH" ;;
esac

echo "==> Installing gimme ($ARCH)…"

# --- try downloading a prebuilt binary ---
BINARY_TARBALL="gimme-darwin-${ARCH_TAG}.tar.gz"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

API_URL="https://api.github.com/repos/gregnazario/gimme/releases/latest"

# Fetch the download URL for the matching tarball.
DOWNLOAD_URL=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_URL="$(curl -fsSL "$API_URL" 2>/dev/null | grep -o "https://[^\"]*${BINARY_TARBALL}" | head -1 || true)"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_URL="$(wget -qO- "$API_URL" 2>/dev/null | grep -o "https://[^\"]*${BINARY_TARBALL}" | head -1 || true)"
fi

# Verify a downloaded artifact against the release's SHA256SUMS when the
# release publishes one (fail-open only for older releases without it).
verify_sums() {  # verify_sums <tarball-name>
    SUMS_URL=""
    if command -v curl >/dev/null 2>&1; then
        SUMS_URL="$(curl -fsSL "$API_URL" 2>/dev/null | grep -o "https://[^\"]*SHA256SUMS" | head -1 || true)"
    fi
    [ -z "$SUMS_URL" ] && return 0
    curl -fsSL -o "$TMPDIR/SHA256SUMS" "$SUMS_URL" 2>/dev/null || return 0
    grep "  $1" "$TMPDIR/SHA256SUMS" > "$TMPDIR/one.sum" 2>/dev/null || fail "SHA256SUMS has no entry for $1"
    (cd "$TMPDIR" && shasum -a 256 -c one.sum --status) || fail "checksum mismatch for $1"
    rm -f "$TMPDIR/one.sum"
}

if [ -n "$DOWNLOAD_URL" ]; then
    echo "==> Downloading prebuilt binary…"
    if curl -fsSL -o "$TMPDIR/$BINARY_TARBALL" "$DOWNLOAD_URL" 2>/dev/null || \
       wget -qO "$TMPDIR/$BINARY_TARBALL" "$DOWNLOAD_URL" 2>/dev/null; then

        verify_sums "$BINARY_TARBALL"
        tar xzf "$TMPDIR/$BINARY_TARBALL" -C "$TMPDIR"
        BINARY="$TMPDIR/gimme"
        chmod 755 "$BINARY"

        # Verify it runs.
        VERSION="$("$BINARY" --version 2>/dev/null | head -1 || echo 'gimme')"
        echo "==> Downloaded $VERSION"
    else
        echo "==> Download failed, falling back to source build…"
        DOWNLOAD_URL=""
    fi
fi

# --- fallback: build from source ---
if [ -z "$DOWNLOAD_URL" ]; then
    echo "==> Building from source (requires Swift 5.9+)…"

    command -v swift >/dev/null 2>&1 || fail "Swift not found. Install from https://swift.org or run 'brew install swift'"

    # Are we in the repo already?
    if [ -f "Package.swift" ] && [ -f "install.sh" ]; then
        REPO_ROOT="$(pwd)"
    else
        REPO_ROOT="$TMPDIR/gimme-src"
        git clone --depth 1 --branch "$BRANCH" "$REPO" "$REPO_ROOT"
    fi

    cd "$REPO_ROOT"
    swift build -c release
    BINARY="$REPO_ROOT/.build/release/gimme"

    [ -s "$BINARY" ] || fail "build succeeded but binary not found"
    VERSION="$("$BINARY" --version 2>/dev/null | head -1 || echo 'gimme')"
    echo "==> Built $VERSION"
fi

# --- install binary ---
mkdir -p "$INSTALL_DIR"
cp "$BINARY" "$INSTALL_DIR/gimme"
chmod 755 "$INSTALL_DIR/gimme"

# Strip macOS quarantine attribute if present (browser-downloaded tarballs
# get one; curl|sh doesn't). Without this, Gatekeeper blocks the binary.
xattr -cr "$INSTALL_DIR/gimme" 2>/dev/null || true

echo "  ✓ Installed to $INSTALL_DIR/gimme"

# --- install app (unless skipped) ---
if [ "$SKIP_APP" != "1" ]; then
    APP_TARBALL="GimmeUI-darwin-${ARCH_TAG}.tar.gz"
    APP_URL=""
    if command -v curl >/dev/null 2>&1; then
        APP_URL="$(curl -fsSL "$API_URL" 2>/dev/null | grep -o "https://[^\"]*${APP_TARBALL}" | head -1 || true)"
    fi

    if [ -n "$APP_URL" ]; then
        echo "==> Downloading Gimme.app…"
        if curl -fsSL -o "$TMPDIR/$APP_TARBALL" "$APP_URL" 2>/dev/null; then
            verify_sums "$APP_TARBALL"
            tar xzf "$TMPDIR/$APP_TARBALL" -C "$TMPDIR"
            # Strip quarantine so Gatekeeper doesn't block the unsigned app.
            xattr -cr "$TMPDIR/Gimme.app" 2>/dev/null || true
            if [ -w "$APP_DIR" ]; then
                cp -R "$TMPDIR/Gimme.app" "$APP_DIR/"
                xattr -cr "$APP_DIR/Gimme.app" 2>/dev/null || true
                echo "  ✓ Installed Gimme.app to $APP_DIR"
            else
                echo "  (need sudo to install to $APP_DIR)"
                sudo cp -R "$TMPDIR/Gimme.app" "$APP_DIR/" && sudo xattr -cr "$APP_DIR/Gimme.app" 2>/dev/null || true
                echo "  ✓ Installed Gimme.app to $APP_DIR" || warn "  could not install app"
            fi
        fi
    fi
fi

# --- PATH check ---
case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) warn "note: $INSTALL_DIR is not on your PATH. Add it to your shell profile:" ;;
esac

# --- final verify ---
INSTALLED="$INSTALL_DIR/gimme"
"$INSTALLED" --version >/dev/null 2>&1 && echo "==> Done! Run 'gimme --help' to get started." || fail "installation verification failed"
