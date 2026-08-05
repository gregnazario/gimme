# Install

## Requirements

- macOS 13 (Ventura) or newer
- Swift 6.0+ (Xcode 16+) — only needed if building from source

## One line (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/gregnazario/gimme/main/install.sh | sh
```

The installer:

1. Checks for macOS + Swift 6+.
2. Clones the repo to a temp dir (or builds in-place if run from a checkout).
3. Builds a release binary.
4. Installs the binary + man page + tldr page to `~/.local/bin` (configurable).
5. Prints PATH setup instructions if needed.

**Options** (via environment variables):

| Variable | Default | Notes |
|---|---|---|
| `GIMME_INSTALL_DIR` | `~/.local/bin` | Where the binary goes |
| `GIMME_MAN_DIR` | `~/.local/share/man/man1` | Where the man page goes |
| `GIMME_REPO` | `https://github.com/gregnazario/gimme` | Git URL to clone |
| `GIMME_BRANCH` | `main` | Branch/tag to build |
| `GIMME_SKIP_MAN=1` | — | Skip man page |
| `GIMME_SKIP_TLDR=1` | — | Skip tldr page |

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

=== "zsh"

    ```sh
    ln -sf "$PWD/.build/release/gimme" ~/.local/bin/gimme
    ```

=== "bash"

    ```sh
    ln -sf "$PWD/.build/release/gimme" ~/.local/bin/gimme
    ```

## Add `~/.gimme/bin` to PATH (one time)

Installed tools are shimmed into `~/.gimme/bin`. Add it to your shell config so
the shims are reachable:

=== "zsh (~/.zshrc)"

    ```sh
    echo 'export PATH="$HOME/.gimme/bin:$PATH"' >> ~/.zshrc
    ```

=== "bash (~/.bashrc)"

    ```sh
    echo 'export PATH="$HOME/.gimme/bin:$PATH"' >> ~/.bashrc
    ```

=== "fish (~/.config/fish/config.fish)"

    ```sh
    fish_add_path "$HOME/.gimme/bin"
    ```

Restart your shell (or `source` the file), then verify:

```sh
gimme --version     # -> gimme 0.1.0
gimme doctor        # health check (PATH, permissions, receipts)
```

## Man page (optional)

```sh
gimme man > ~/.local/share/man/man1/gimme.1
man gimme
```

## Verify

```sh
gimme --help
gimme introspect --json | head
```

## Uninstall

```sh
rm ~/.local/bin/gimme
rm -rf ~/.gimme   # removes the cellar, cache, taps, state
```
