# gimmie — project instructions

This file is the project-level instructions for the gimmie repository. It
overrides default behavior for any agent working in this workspace. The global
user instructions at `~/.zcode/AGENTS.md` still apply (English only, no AI
attribution in commits, etc.).

## What gimmie is

gimmie is a **pure-orchestration** package manager for macOS: it does not
download, build, or shelve anything itself. It drives real package managers
(Homebrew, Go, uv, Cargo, bun) through one `PackageManager` protocol seam, and
exposes them through a unified namespace via both a CLI (`gimme`) and a SwiftUI
macOS app (`GimmeUI`), sharing one Swift engine (`GimmeCore`).

- **Architecture:** thin engine, fat adapters. The engine never knows *how* a
  manager installs things; each adapter owns its I/O (brew JSON API, Go proxy,
  PyPI, crates.io, npm registry; CLI where no machine API exists).
- **Build:** SwiftPM, `swift-tools-version: 5.9`, macOS 13 floor, no external
  dependencies. Three targets: `GimmeCore`, `gimme` (CLI), `GimmeUI` (SwiftUI).
- **Spec & plan of record:** `docs/superpowers/specs/2026-08-07-gimmie-v2-orchestrator-design.md`
  and `docs/superpowers/plans/2026-08-07-gimmie-v2-orchestrator.md`. Read these
  before making non-trivial changes.

## Language

- **English only** in all responses, code, comments, commit messages, and docs.

## Git & commits

- **Never attribute commits to any AI** — no `Co-Authored-By`, no trailers, no
  banners. Commits must look human-authored.
- **Conventional Commits** (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`,
  `chore:`), matching the existing log.
- **Frequent commits** — one logical unit per commit, each leaving the build
  and tests green.
- Commit or push only when the user asks.

## Testing

- **TDD by default.** Write the failing test, implement, verify green, commit.
- Run `swift test` before claiming work is complete; report real output, not
  intentions. The suite is in-process (no real network/installs in CI).
- GUI has no automated tests (v1 decision, see spec §10). Verify GUI changes by
  building the app and launching it.

## SwiftUI navigation policy (MANDATORY)

This is the rule the user asked to codify. Every interactive surface must have
an obvious way out. Apply it to all new and existing UI:

### 1. Modals (`.sheet`, `.fullScreenCover`, `.popover`) → **Close or Cancel**

- Every modal **must** present a visible dismissal control: a Close/Cancel
  button, or an explicit ✕ in a header. Never rely solely on clicking outside
  the sheet or swiping — it must be discoverable.
- **Esc must dismiss** any modal. Wire the dismissal control to
  `.keyboardShortcut(.cancelAction)` so the keyboard works.
- Destructive actions inside a modal (Uninstall, Remove) use `.buttonStyle` /
  `role: .destructive` and **keep their own confirmation** (or the modal's
  Cancel) — the action button dismisses only *after* acting; the close button
  dismisses *without* acting.
- Reference implementation: `Sources/GimmeUI/Views/DetailSheet.swift` (header
  with ✕ wired to `.cancelAction`, plus the action button).

### 2. Detail / drill-down navigation (push) → **Back**

- When a view shows "more info on the main page" by drilling into a detail
  screen via a `NavigationStack` push (`NavigationLink` / `navigationDestination`),
  the destination **must** have working back navigation. On macOS this is the
  toolbar back button / `NavigationSplitView`'s sidebar selection; do not
  present pushed detail in a way that removes the path back.
- If a drill-down is presented as a sheet instead (common in `NavigationSplitView`
  apps, since a third column is awkward), it follows rule 1 (Close/Cancel) —
  that's acceptable and macOS-idiomatic for "details about a selected item."

### 3. Sidebar / window root navigation → **no back button**

- `NavigationSplitView` sidebar sections (Installed, Updates, Browse, etc.) are
  switched directly; the **sidebar itself is the navigation**, so no back
  button is added. This is correct — do not bolt one on.
- The main window is always dismissable via the standard window controls (⌘W).

### Decision rule when adding a new screen

| If the new surface is… | Use… | Affordance |
|---|---|---|
| Transient action / quick details (install, uninstall, info card) | `.sheet` | Close (✕) + Esc; Cancel if destructive |
| Confirmation of an irreversible action | `.alert` / `.confirmationDialog` | OK + Cancel buttons (built in) |
| Drill-down into richer info within the same flow | `NavigationStack` push | Back (toolbar / sidebar) |
| A new top-level area | Sidebar section | Sidebar selection (no back) |

When unsure: **a user must always be able to leave the current screen using
only UI that is visible on that screen.** If they can't, the navigation is
wrong — fix it before shipping.
