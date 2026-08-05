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
#   1. Checks for macOS + Swift 6+.
#   2. Clones (or updates) the repo to a temp build dir.
#   3. Builds a release binary.
#   4. Installs the binary + man page + tldr page.
#   5. Prints next steps (PATH setup).
#
# Environment overrides:
#   GIMME_INSTALL_DIR   where to install the binary (default: ~/.local/bin)
#   GIMME_MAN_DIR       where to install the man page (default: ~/.local/share/man/man1)
#   GIMME_REPO          git URL to clone from (default: https://github.com/gregnazario/gimme)
#   GIMME_BRANCH        branch/tag to build (default: main)
#   GIMME_SKIP_MAN      set to 1 to skip man page installation
#   GIMME_SKIP_TLDR     set to 1 to skip tldr page installation

set -eu

# --- defaults ---

REPO="${GIMME_REPO:-https://github.com/gregnazario/gimme}"
BRANCH="${GIMME_BRANCH:-main}"
INSTALL_DIR="${GIMME_INSTALL_DIR:-${HOME}/.local/bin}"
MAN_DIR="${GIMME_MAN_DIR:-${HOME}/.local/share/man/man1}"
SKIP_MAN="${GIMME_SKIP_MAN:-0}"
SKIP_TLDR="${GIMME_SKIP_TLDR:-0}"

# Allow --prefix <dir> to override INSTALL_DIR (local-clone mode).
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            shift
            INSTALL_DIR="$1"
            ;;
        --prefix=*)
            INSTALL_DIR="${1#--prefix=}"
            ;;
        --help|-h)
            cat <<'EOF'
gimme installer — POSIX sh

Usage: sh install.sh [--prefix <dir>]

Environment:
  GIMME_INSTALL_DIR   binary install dir (default: ~/.local/bin)
  GIMME_MAN_DIR       man page dir (default: ~/.local/share/man/man1)
  GIMME_REPO          git URL (default: https://github.com/gregnazario/gimme)
  GIMME_BRANCH        branch/tag (default: main)
  GIMME_SKIP_MAN=1    skip man page
  GIMME_SKIP_TLDR=1   skip tldr page
EOF
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 1
            ;;
    esac
    shift
done

# --- helpers ---

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required but not found in PATH"
}

# --- preflight ---

info "Checking prerequisites..."

# OS check — gimme is macOS-only for now.
case "$(uname -s)" in
    Darwin*) ;;
    *) fail "gimme currently supports macOS only (got $(uname -s))." ;;
esac
ok "macOS detected"

# Swift 6+ check.
need swift
SWIFT_VER="$(swift --version 2>/dev/null | head -1 | sed 's/.*version \([0-9]*\).*/\1/')"
if [ -z "$SWIFT_VER" ] || [ "$SWIFT_VER" -lt 6 ]; then
    fail "Swift 6+ is required (found: $(swift --version 2>/dev/null | head -1))."
fi
ok "Swift ${SWIFT_VER}+ detected"

need git
ok "git detected"

# --- build ---

info "Building gimme from ${BRANCH}..."

# Use a temp dir for the clone. If running from a local checkout (the script
# is in the repo root), build in-place instead.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
BUILD_DIR=""
CLEANUP=""

if [ -f "${SCRIPT_DIR}/Package.swift" ] && [ -f "${SCRIPT_DIR}/install.sh" ]; then
    # Running from a local clone — build here.
    BUILD_DIR="$SCRIPT_DIR"
    ok "Using local checkout: ${BUILD_DIR}"
else
    # Clone to a temp dir.
    BUILD_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t gimme)"
    CLEANUP="$BUILD_DIR"
    trap 'rm -rf "$CLEANUP"' EXIT INT TERM
    info "Cloning to ${BUILD_DIR}..."
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$BUILD_DIR" || fail "git clone failed"
    ok "Cloned"
fi

info "Compiling (release)..."

# Always force a clean build of the release binary. SwiftPM's incremental build
# can produce a stale/0-byte binary if a previous build was interrupted (the
# linker sees the output file exists and skips relinking).
rm -rf "${BUILD_DIR}/.build/release"

swift build -c release --package-path "$BUILD_DIR" 2>&1 || fail "swift build failed"

BINARY="${BUILD_DIR}/.build/release/gimme"

# Wait for the binary to be non-empty AND stable (SwiftPM may still be writing).
# This prevents the race where swift build returns before the link is flushed.
_attempts=0
while [ $_attempts -lt 10 ]; do
    if [ -s "$BINARY" ]; then
        # Verify it actually runs.
        if "$BINARY" --version >/dev/null 2>&1; then
            break
        fi
    fi
    _attempts=$((_attempts + 1))
    sleep 0.5
done

[ -x "$BINARY" ] || fail "binary not found at ${BINARY} after build"
[ -s "$BINARY" ] || fail "binary is 0 bytes after build (build may have been interrupted)"
"$BINARY" --version >/dev/null 2>&1 || fail "binary exists but does not run"
ok "Built and verified ($(wc -c < "$BINARY" | tr -d ' ') bytes)"

VERSION="$("$BINARY" --version 2>/dev/null | head -1 || echo 'gimme')"
ok "${VERSION}"

# --- install binary (COPY, not symlink — .build/ can be mutated by SwiftPM) ---

info "Installing to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"

# Copy the binary to the install dir. A symlink to .build/release/ is fragile:
# SwiftPM can truncate/replace the build output during incremental builds,
# leaving the installed binary as 0 bytes. A copy is stable.
cp "$BINARY" "${INSTALL_DIR}/gimme"
chmod 755 "${INSTALL_DIR}/gimme"

# Verify the installed copy.
[ -s "${INSTALL_DIR}/gimme" ] || fail "installed binary is 0 bytes"
"${INSTALL_DIR}/gimme" --version >/dev/null 2>&1 || fail "installed binary does not run"
ok "Binary installed: ${INSTALL_DIR}/gimme"

# --- install man page ---

if [ "$SKIP_MAN" = "1" ]; then
    warn "Skipping man page (--skip-man)"
else
    info "Installing man page..."
    mkdir -p "$MAN_DIR"
    "${INSTALL_DIR}/gimme" man > "${MAN_DIR}/gimme.1" 2>/dev/null || warn "man page generation failed (non-fatal)"
    ok "Man page: ${MAN_DIR}/gimme.1"
fi

# --- install tldr page ---

if [ "$SKIP_TLDR" = "1" ]; then
    warn "Skipping tldr page"
elif [ -f "${BUILD_DIR}/tldr-pages/pages/common/gimme.md" ]; then
    TLDR_DIR="${HOME}/.local/share/tldr/pages/common"
    info "Installing tldr page..."
    mkdir -p "$TLDR_DIR"
    cp "${BUILD_DIR}/tldr-pages/pages/common/gimme.md" "${TLDR_DIR}/gimme.md"
    ok "tldr page: ${TLDR_DIR}/gimme.md"
fi

# --- PATH check ---

GIMME_BIN_DIR="${HOME}/.gimme/bin"

case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
        printf '\n'
        warn "${INSTALL_DIR} is not on your PATH."
        printf '  Add this line to your shell config (~/.zshrc or ~/.bashrc):\n'
        printf '    export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
        ;;
esac

case ":${PATH}:" in
    *":${GIMME_BIN_DIR}:"*) ;;
    *)
        warn "${GIMME_BIN_DIR} (for installed tools) is not on your PATH."
        printf '  Add this line too:\n'
        printf '    export PATH="%s:$PATH"\n\n' "$GIMME_BIN_DIR"
        ;;
esac

# --- done ---

# Final verification: the installed binary runs and produces output.
INSTALLED="${INSTALL_DIR}/gimme"
if "$INSTALLED" --version >/dev/null 2>&1; then
    ok "Installed binary runs: $("$INSTALLED" --version 2>/dev/null)"
else
    fail "Installed binary does not run"
fi

printf '\n'
info 'Done! Next steps:'
printf '  hash -r             # clear shell command cache (important if reinstalling)\n'
printf '  gimme --version     # verify\n'
printf '  gimme doctor        # health check\n'
printf '  gimme --help        # see all commands\n'
printf '  man gimme           # read the man page\n'
printf '\n'
