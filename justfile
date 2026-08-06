# gimme — task runner (https://github.com/casey/just)
#
# Common workflows: `just build`, `just test`, `just docs-serve`, `just install`.

# Default: list available recipes.
default:
    @just --list

# --- Swift ---

# Build the gimme executable (debug).
build:
    swift build

# Build a release binary.
release:
    swift build -c release

# Run the test suite.
test:
    swift test

# Run tests with coverage enabled.
test-coverage:
    swift test --enable-code-coverage

# --- Docs ---

# Site venv directory.
site-venv := "docs-site/.venv"

# Create the docs-site venv and install mkdocs-material (one-time).
docs-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 -m venv {{site-venv}}
    {{site-venv}}/bin/pip install -r docs-site/requirements.txt

# Regenerate the man page from the current binary into the source tree.
man:
    #!/usr/bin/env bash
    set -euo pipefail
    swift build -c release
    mkdir -p ~/.local/share/man/man1
    .build/release/gimme man > man/gimme.1
    cp man/gimme.1 ~/.local/share/man/man1/gimme.1
    echo "man page generated at man/gimme.1 and installed."

# Install the tldr page locally (tldr-pages format).
tldr:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ~/.local/share/tldr/pages/common
    cp tldr-pages/pages/common/gimme.md ~/.local/share/tldr/pages/common/gimme.md
    echo "tldr page installed. Test with: tldr --render ~/.local/share/tldr/pages/common/gimme.md"

# Build the MkDocs site (output to ./site).
docs-build:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{site-venv}}" ]; then just docs-setup; fi
    cd docs-site && {{site-venv}}/bin/mkdocs build

# Serve the docs site locally with live reload.
docs-serve:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{site-venv}}" ]; then just docs-setup; fi
    cd docs-site && {{site-venv}}/bin/mkdocs serve

# Deploy the docs site to GitHub Pages (requires `gh-auth` + mike).
docs-deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{site-venv}}" ]; then just docs-setup; fi
    {{site-venv}}/bin/pip install -q mike
    cd docs-site && {{site-venv}}/bin/mike deploy --push latest

# --- Install ---

# Install the release binary to ~/.local/bin/gimme (copied, not symlinked).
install:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .build/release
    swift build -c release
    # Wait for the binary to be stable (SwiftPM link flush race).
    for i in $(seq 1 10); do
        [ -s .build/release/gimme ] && .build/release/gimme --version >/dev/null 2>&1 && break
        sleep 0.5
    done
    [ -s .build/release/gimme ] || { echo "Build produced no binary" >&2; exit 1; }
    .build/release/gimme --version >/dev/null 2>&1 || { echo "Binary does not run" >&2; exit 1; }
    mkdir -p ~/.local/bin
    # Copy (not symlink) — .build/release/ can be mutated by SwiftPM during
    # incremental builds, truncating a symlinked binary to 0 bytes.
    cp .build/release/gimme ~/.local/bin/gimme
    chmod 755 ~/.local/bin/gimme
    echo "installed: $(gimme --version)"

# Verify the POSIX installer script (syntax + local-mode dry run to a temp dir).
verify-install-script:
    #!/usr/bin/env bash
    set -euo pipefail
    sh -n install.sh
    test -x install.sh
    testdir="$$(mktemp -d)"
    GIMME_INSTALL_DIR="$$testdir/bin" GIMME_MAN_DIR="$$testdir/man/man1" GIMME_SKIP_TLDR=1 \
        sh install.sh --prefix "$$testdir/bin"
    "$$testdir/bin/gimme" --version
    rm -rf "$$testdir"
    echo "install.sh verified: syntax ok, local-mode build+install works."

# --- Cleanup ---

# Build the native macOS .app bundle.
app:
    sh app/build-app.sh

# Open the native macOS app.
open-app: app
    open app/Gimme.app

# Install the .app to /Applications.
install-app: app
    cp -R app/Gimme.app /Applications/
    @echo "Installed to /Applications/Gimme.app"

# Remove all build artifacts.
clean:
    rm -rf .build site docs-site/.venv app/Gimme.app
