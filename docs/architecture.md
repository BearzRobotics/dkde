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

External packages (fetched by hash, see Build): toml-zig, util-unix, util-core, dkman (with md-zig, gtroff-zig, regex-zig), pdf-zig and
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

`build.zig` sets up what the programs share (GTK and GLib bindings, `core`, `common`, the Wayland protocols, the image and PDF modules) and calls `src/<name>/build.zig` for each program, which adds that program's own imports, libraries and embedded files and names its data files and menu entry. `zig build` (or `-Dapp=all`) builds everything; `zig build -Dapp=<name>` builds, tests (`test-<name>`) and installs one program, with `share/dkde/{style.css,dkde.toml}` and that program's own defaults; `-Dapp=term,edit` builds a few. Lazy dependencies (`gobject`, `wayland`) are fetched only when a GTK program is selected. Dependencies are pinned by hash in `build.zig.zon`; during development a sibling checkout can be used by replacing a `.url` with `.path = "../name"`.

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

`dkde-session` (shell) starts a session D-Bus if it can, then labwc; labwc's autostart starts `dkde-panel`. Compositor features used: layer-shell (panel), `wlr-foreign-toplevel-management` (task list), `wlr-screencopy` (snip), `ext-workspace`, `ext-idle-notify`, virtual pointer/keyboard. Each degrades with a log line when its protocol is missing. With `--x11` it starts `dkde-wm` and the panel instead (see below).

### Shared desktop API

Programs reach windows, workspaces, outputs and screenshots through `common.desktop` (`src/common/desktop.zig`): types, a capability set and a `Desktop` that turns anything unsupported into a no-op. Backends fill it in: `src/wldesktop` (foreign-toplevel, ext-workspace, output management, screencopy; takes a `wl_display`, no toolkit) and `src/x11desktop` (EWMH client messages and properties over XCB; watched from the GLib loop). The panel picks the backend from the GDK display type; `panel/surface.zig` does the same for its own windows (layer-shell on Wayland, `x11_surface.zig` on X11: docks with struts, desktop and menu windows placed over XCB). dkde-snip works on both: capture goes through the API, and its scrolling capture turns the wheel with a wlr-virtual-pointer on Wayland or XTEST (`x11desktop/pointer.zig`) on X11. Task Manager's Firewall and Security pages follow detection unless `firewall-backend` / `security-module` in `tasks.toml` (set on its Settings page) override it, and are rebuilt when that changes. A `Fake` backend in `desktop.zig` covers the API in tests; `DKDE_X11_TEST=1 zig build test -Dapp=panel` runs the X11 backend against a live server.

### Own compositor and window manager (experimental)

`src/compositor` (wlroots) and `src/xwm` (XCB) are separate packages with their own `zig build`, so the main build needs neither wlroots nor X11 development files. The window manager imports the compositor's `layout.zig`, `keys.zig` and `config.zig` (no display code in them) through `src/compositor/src/shared.zig`, so both read `~/.config/dkde/compositor.toml` and share layout policy and shortcuts. `dkde-session` can start either (`DKDE_COMPOSITOR`, `--x11`, `session.conf`). Optional desktop effects: on Wayland a wlroots render pass for animations, Scale, Expo and the switchers, and our own GLES composer (`src/compositor/src/gfx.zig`) for filters, zoom, wobbly windows, blur, the cube and the rest; on X11 `src/xcomp` (`dkde-xcomp`, a third package: XCB Composite, Damage and XFixes with EGL and GLES2, the same shaders and effect code), which does opacity, fades, blur, the cube, filters, zoom, lens, water, motion blur, snow and the pointer finder, and composes only while a setting needs it (Scale, Expo, the switcher, wobbly windows, shelf, fire and paint are Wayland only). dkde-wm has parity for everything that needs no compositing (rules, placement, tab groups, gestures, opacity property) and forwards the effect keys to dkde-xcomp. The pure effect logic (placement, rules, animation, overview and cube geometry, wobble physics, filters) is shared through `shared.zig`. Progress and open items: `ai/COMPOSITOR-SURVEY.md`.

## Privilege

Today: `common/elevate.zig` asks for the password itself and runs `sudo -S`. This contradicts the spec; see `docs/decisions/0001-architecture-realignment.md` §9. `dkde-polkit` is a Polkit *agent*; no privileged helper services exist yet.

## Tests

`zig build test` (unit), `tests/build-isolation.sh` (per-app build/install), `tests/cli-contract.sh`, `tests/runtime-independence.sh` (needs a Wayland display).
