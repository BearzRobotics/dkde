# DKDE architecture (current implementation)

Describes what the code does today, not the goals; goals are in `ai/DKDE-SPEC.md`. Last checked against the tree on 2026-11-07.

## Modules

```
 cli (src/cli.zig)            --help / --version / bad-option handling. std only.
 core (src/common/core.zig)   Config (TOML), migrate, paths, state, log, perf, events/ics/civil,
                              apps/appinfo, power, proc, labwc, notify, icons, i18n, user.
                              Needs GLib/GIO and toml-zig. No GTK.
 common (src/common/root.zig) re-exports core, plus GTK: style, dialogs, header, menubar,
                              contextmenu, runapp, elevate.
 termembed (src/term/embed.zig)   the terminal as a widget (a `Panel`) that files and edit host
 imgcodec, pdfrender, truetype, third_party/{zigimg,stb}   per-app libraries
 pdf/session.zig             an open PDF and its edit history, without GTK (dkde-pdf)

External packages (fetched by hash, see Build): toml-zig, util-unix, dkman, pdf-zig and
DKTermCore. DKTermCore owns terminal state, key encoding, colour schemes, the PTY adapter
and libghostty-vt; dkde-term, dkde-settings and the embedded panel use its `termcore` module.
```

Programs (`src/<name>/main.zig` → `dkde-<name>`):

| Imports | Programs |
|---|---|
| `core` only (no GTK linked) | `notify`, `setup`, `idle` |
| `common` (GTK4) | `panel`, `files`, `settings`, `edit`, `view`, `calc`, `calendar`, `clock`, `charmap`, `color`, `parted`, `pdf`, `snip`, `tasks`, `term`, `greeter`, `polkit-ui` |
| neither | `polkit` (GIO only), `pdfcheck`, `pointer` |

No program imports another program's source. They start each other only as optional actions, through `PATH`.

## Build

`build.zig` is the only build script. `zig build` builds everything; `zig build -Dapp=<name>` builds, tests (`test-<name>`) and installs one program, with `share/dkde/{style.css,dkde.toml}` and that program's own defaults. Lazy dependencies (`gobject`, `wayland`) are fetched only when a GTK program is selected. Dependencies are pinned by hash in `build.zig.zon`; during development a sibling checkout can be used by replacing a `.url` with `.path = "../name"`.

## Programs worth knowing about

- `dkde-term`: tabs, each a tree of panes (`gtk.Paned`); every pane is a `TerminalView`. Panes report focus, title and exit to their tab.
- `dkde-pdf`: a `Window` with a notebook of `DocView` tabs. Each tab owns a `Session` (`pdf/session.zig`): the PDF, its text layouts and an undo list. Edits are pdf-zig incremental updates; undo cuts the file back to its earlier length.
- `dkde-files`, `dkde-edit`: host a `termembed.Panel` below their content. The shell starts the first time the panel is shown.

## Testing and smoke tests

`zig build test` runs every program's unit tests. `DKDE_EXIT_AFTER_MS=<ms>` makes a program close its windows and quit after that long; Debug builds print a leak report on exit, and every program is expected to exit without one. Per-tab and per-popover data must be owned by the window struct, not freed by a widget's destroy signal: GTK does not destroy notebook tab labels or popovers with the window, and children are destroyed before the window's own destroy handler runs.

## Configuration

```
 /usr/share/dkde/<name>.toml   system defaults  ─┐ overlaid per key
 ~/.config/dkde/<name>.toml    user file         ─┘ → Config.doc
```

`Config.load(alloc, "panel.toml")`; a *group* is a top-level table. Reads never fail (defaults on missing key, wrong type, or a malformed user file). Writes: lock `<file>.lock` → re-read the user file → change → write temp file + rename → reload. A malformed user file blocks all writes. Watching uses a GIO file monitor. Legacy INI → `dkde-setup --migrate-config`.

## Session

`dkde-session` (shell) starts a session D-Bus if it can, then labwc; labwc's autostart starts `dkde-panel`. Compositor features used: layer-shell (panel), `wlr-foreign-toplevel-management` (task list), `wlr-screencopy` (snip), `ext-workspace`, `ext-idle-notify`, virtual pointer/keyboard. Each degrades with a log line when its protocol is missing.

## Privilege

Today: `common/elevate.zig` asks for the password itself and runs `sudo -S`. This contradicts the spec; see `docs/decisions/0001-architecture-realignment.md` §9. `dkde-polkit` is a Polkit *agent*; no privileged helper services exist yet.

## Tests

`zig build test` (unit), `tests/build-isolation.sh` (per-app build/install), `tests/cli-contract.sh`, `tests/runtime-independence.sh` (needs a Wayland display).
