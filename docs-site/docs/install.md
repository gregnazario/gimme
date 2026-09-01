# Install

## Requirements

- macOS 13 (Ventura) or newer
- Swift 5.9+ — only needed when building from source

## macOS app (DMG)

Download `GimmeUI-<version>-arm64.dmg` from the
[releases page](https://github.com/gregnazario/gimme/releases), open it, and
drag Gimme to `Applications`.

The app is self-contained: it can install the command-line tool for you
(**gimme → Install Command-Line Tool…**, installs to `~/.local/bin`) and
keeps itself updated (**gimme → Check for Updates**).

## One line (CLI + app)

```sh
curl -fsSL https://raw.githubusercontent.com/gregnazario/gimme/main/install.sh | sh
```

The installer:

1. Checks for macOS and the CPU architecture.
2. Downloads the prebuilt CLI binary from the latest GitHub release
   (verified against the release's `SHA256SUMS`), falling back to a source
   build on Intel Macs or if no binary is available.
3. Installs the binary to `~/.local/bin` (configurable).
4. Installs Gimme.app to `/Applications` (uses `sudo` if needed; skip with
   `GIMME_SKIP_APP=1`).

**Options** (via environment variables):

| Variable | Default | Notes |
|---|---|---|
| `GIMME_INSTALL_DIR` | `~/.local/bin` | Where the binary goes |
| `GIMME_APP_DIR` | `/Applications` | Where Gimme.app goes |
| `GIMME_SKIP_APP` | — | Set to `1` to skip the app |
| `GIMME_REPO` | `https://github.com/gregnazario/gimme` | Git URL for source builds |
| `GIMME_BRANCH` | `main` | Branch/tag for source builds |

Or from a local clone:

```sh
just install
```

## From source

```sh
git clone https://github.com/gregnazario/gimme.git
cd gimme
swift build -c release
```

Then make the binary reachable on your `PATH`. A symlink keeps it updated when
you `git pull && swift build -c release`:

```sh
ln -sf "$PWD/.build/release/gimme" ~/.local/bin/gimme
```

## Add `~/.local/bin` to PATH (one time)

The CLI installs to `~/.local/bin`. Add it to your shell config if it isn't
already there:

=== "zsh (~/.zshrc)"

    ```sh
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
    ```

=== "bash (~/.bashrc)"

    ```sh
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    ```

=== "fish (~/.config/fish/config.fish)"

    ```sh
    fish_add_path "$HOME/.local/bin"
    ```

Restart your shell (or `source` the file), then verify:

```sh
gimme --version     # -> gimme <version>
gimme doctor        # which package managers are installed and available
```

## Uninstall

```sh
rm ~/.local/bin/gimme
rm -rf ~/.config/gimme ~/.cache/gimme   # settings + TTL cache
```

Drag Gimme.app from `Applications` to the Trash (or
`rm -rf /Applications/Gimme.app`).

Installed a v1 release? The old cellar layout lived in `~/.gimme` — remove
it too: `rm -rf ~/.gimme`.
