# gimme

> Unified package manager for macOS: orchestrates Homebrew, Go, uv, Cargo, npm, and more through one CLI.
> More information: <https://github.com/gregnazario/gimme>.

- Install a package (asks each manager in priority order; `--from <manager>` pins one and remembers it):

`gimme install {{package}}`

- Search for a package (add `--all` to query every manager):

`gimme search {{query}}`

- Search every manager with the best match first:

`gimme find {{query}}`

- List packages installed across all managers:

`gimme list`

- Check for outdated packages (add `--force` to bypass every cache, incl. registry lookups):

`gimme outdated`

- Upgrade one package, or every outdated package:

`gimme upgrade {{package}}`

- Update gimme itself:

`gimme update --self`

- Find packages installed through more than one manager:

`gimme consolidate`

- Show which package managers are installed and available:

`gimme doctor`

- Forward any command verbatim to a backend manager:

`gimme brew {{args}}`
