# gimme

> A Swift-based package manager for macOS.
> Install tools via typed formulae, with mise/asdf interop and an AI-agent contract.
> More information: <https://github.com/gregnazario/gimme>.

- Install a tool (the signature shortcut: install if missing, update if stale, no-op if current):

`gimme {{tool}}`

- Install a specific version:

`gimme {{tool}}@{{version}}`

- Explicitly install a tool (or, with no args + a `.tool-versions`/`mise.toml` present, install the batch):

`gimme install {{tool}}`

- List installed tools (or all known formulae):

`gimme list --all`

- Update all tools that aren't pinned:

`gimme update --all`

- Switch the active version of an installed tool (no download):

`gimme use {{tool}} {{version}}`

- Show health check (PATH, permissions, receipts, mise detection):

`gimme doctor`

- Emit structured JSON for scripting/agents (works with every command):

`gimme install {{tool}} --dry-run --json`
