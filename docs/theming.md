# Theming dkde

Every dkde program uses one stylesheet and one small settings file, so the look
is the same everywhere and is changed in one place.

## What loads, and in what order

1. GTK's own theme (lowest priority).
2. `share/dkde/style.css`: dkde's stylesheet, shipped with the programs
   (`$XDG_DATA_DIRS/dkde/style.css`; set `DKDE_DATA_DIR` to use the one in a
   source checkout).
3. The *appearance* variables, generated at run time from
   `~/.config/dkde/dkde.toml` (below). They are loaded after the stylesheet, so
   they win over the defaults written in it.
4. Your own `~/.config/dkde/style.css`, if it exists: loaded last, so anything
   in it wins.

Programs watch `dkde.toml`, so changing the accent or dark mode in Settings
(or by editing the file) restyles running programs at once.

## The settings

`~/.config/dkde/dkde.toml`, group `[appearance]`, or Settings > Appearance:

| Key | Meaning |
|---|---|
| `dark` | `true` for the dark scheme |
| `accent` | any CSS colour, for example `#e66100` |
| `font` | a Pango font description such as `Sans 11`; empty keeps GTK's default |
| `icon-theme` | icons for apps, folders and file types; empty is Fluent |
| `ui-icon-theme` | the small interface glyphs (buttons, arrows, toolbars); empty is `dkde-ui`, `same` uses only `icon-theme` |
| `export-toolkits` | `true` also writes the look into GTK 3/4 and Qt settings files |

## The colour variables

These are what the stylesheet is written in. Use them in your own rules instead
of fixed colours, so your changes follow dark mode and the accent too.

| Variable | Meaning |
|---|---|
| `@dkde_accent` | the accent colour |
| `@dkde_bg`, `@dkde_fg` | window background and text (they swap in dark mode) |
| `@dkde_warning`, `@dkde_caution`, `@dkde_danger` | yellow, orange, red: fixed, not themed, used for heat maps and "full" bars |
| `@dkde_osd` | the dark pill behind the volume and brightness display |
| `@dkde_close` | the window close button's hover red |

## Overriding things: examples

Put these in `~/.config/dkde/style.css`.

```css
/* A taller taskbar button label, and square start button */
window.dkde-panel button.dkde-start { border-radius: 0; }

/* A different font for the terminal's tab strip */
.dkde-tabs { font-family: "Inter"; }

/* Make desktop icon labels larger */
.dkde-desktop-item label { font-size: 110%; }
```

Useful class names: `dkde-panel`, `dkde-start`, `dkde-task`, `dkde-tray`,
`dkde-quick-button`, `dkde-menu` (start menu), `dkde-setting-row` (Settings
cards), `dkde-card` (Task Manager), `dkde-keycap`, `dkde-osd`. Open the window
with `GTK_DEBUG=interactive dkde-<program>` to inspect any widget's classes.

## For program authors

- Never write a colour into code or into a rule that is not a variable. Colours
  belong in `style.css`.
- Code that draws with cairo cannot read CSS variables. Add
  `common.style.accentProbe()` to the widget tree and read the colour with
  `common.style.accentOf(probe)` while drawing; it gives the current accent, so
  drawn parts follow the setting (the Task Manager's graphs do this).
- GTK's own theme bakes its blue into its switches, suggested-action buttons,
  check boxes, progress bars and focus rings instead of using a variable, so
  `style.css` restates those rules with `@dkde_accent`. A new kind of widget that
  shows the theme's blue needs the same treatment at the end of that file.

## Icons

dkde ships the [Fluent icon theme](https://github.com/vinceliuice/Fluent-icon-theme)
(GPL-3.0, `icons/Fluent`, installed to `share/icons/Fluent`) and uses it by
default; Papirus is the fallback when it is missing. Choose another theme in
Settings > Appearance (`icon-theme` in `dkde.toml`). The bundled themes appear in
the list even when dkde runs from a build folder.

GTK has one icon theme, so dkde stacks two: it writes a hidden theme,
`~/.local/share/icons/dkde-active`, that inherits `ui-icon-theme` first and
`icon-theme` second, and sets that. Settings > Appearance has a picker for each.

On top of it, `dkde-ui` (`icons/dkde-ui`, MIT) carries Microsoft's official
[Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons)
for dkde's own controls (window buttons, navigation, file actions), as
recolourable symbolic SVGs. It inherits Fluent for everything else, so it is the
default. Regenerate it with `scripts/vendor-fluentui-icons.py <checkout>`; add
names to its `MAP` to cover more icons.

## Other toolkits

The panel exports the appearance (`dark`, `accent`, `font`, `icon-theme`) to the
other toolkits' config files whenever it changes, so their programs match:

| Toolkit | File written under `~/.config` |
|---|---|
| GTK 3 | `gtk-3.0/settings.ini`, `gtk-3.0/gtk.css` |
| GTK 4 / libadwaita | `gtk-4.0/settings.ini`, `gtk-4.0/gtk.css` |
| Qt 5 | `qt5ct/qt5ct.conf`, `qt5ct/colors/dkde.conf` |
| Qt 6 | `qt6ct/qt6ct.conf`, `qt6ct/colors/dkde.conf` |
| Qt via Kvantum (if installed) | `Kvantum/kvantum.kvconfig`, `Kvantum/dkde/dkde.kvconfig` |

`dkde-session` sets `QT_QPA_PLATFORMTHEME=qt6ct` so Qt reads them. Install
`qt5ct` and `qt6ct` (and `kvantum` for the flat style). These files are
overwritten on every change; put your own tweaks in `~/.config/dkde/style.css`
(GTK programs of dkde only) or turn the export off by not running the panel.

## Known gaps

Text and list *selection* colours are left to GTK's theme. Terminal colour
schemes are separate (per profile, in Settings > Terminal). Dark mode has been
checked on the panel, start menu, Files, Settings, the Task Manager, not on every program.
