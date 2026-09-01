# Quick start

After [installing](install.md) and adding `~/.gimme/bin` to your `PATH`:

## Install a tool

```sh
gimme install <tool>          # explicit
gimme <tool>                  # the signature shortcut
```

The shortcut does the right thing without a subcommand:

| State of `<tool>` | What `gimme <tool>` does |
|---|---|
| Not installed | **Install** latest |
| Installed, update available | **Update** to latest |
| Installed, up to date | **No-op** |
| Installed, **pinned** | **No-op** (held) |

## Versions

```sh
gimme <tool>@2.40            # install a specific version line (any 2.40.x)
gimme <tool>@2.40.0          # exact version
gimme use <tool> 2.40.0      # switch active version (no download)
gimme pin <tool>             # hold the current version
gimme unpin <tool>
gimme update --all           # update everything not pinned
```

## Inspect

```sh
gimme list [--all]           # installed tools (or all known formulae)
gimme search <term>
gimme find <term>            # every manager at once, best match first
gimme info <tool>
gimme outdated               # tools with updates available
```

## Mise / asdf projects

If a directory contains `.tool-versions` or `mise.toml`, `gimme install` (no
args) auto-detects it and installs the batch — skipping tools mise/asdf already
manage.

```sh
cd ~/my-project              # has a .tool-versions
gimme install                # installs the batch
gimme install --no-mise      # opt out of auto-detection
gimme install --dry-run      # plan the batch without installing
```

See the [mise/asdf interop guide](guides/mise.md) for details.

## Taps (formula sources)

```sh
gimme tap add <name> <git-url>
gimme tap list
gimme tap remove <name>
```

## Help everywhere

```sh
gimme --help                 # top-level
gimme install --help         # per-command
gimme man                    # groff man-page source (pipe to `man`)
```
