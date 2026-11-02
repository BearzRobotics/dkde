# dkde — Specification

> **Working name.** `dkde` is a placeholder. It appears in binary names, the
> config directory, Zig namespaces and GObject type prefixes (`Dkde`). Pick
> the real name before the first commit and replace it everywhere.

Status: **Draft v0.1**. Anything marked **OPEN** is an undecided question.
Resolve it here before writing code that depends on it.

---

## 1. Vision

A small, cohesive Wayland desktop shell with the layout of classic Windows: a
bottom taskbar, an Open-Shell "Windows 7 style" start menu, and a matching set
of core applications. It should feel like one product, not a collection of
unrelated tools.

Cohesion comes from three things, and this spec exists to enforce them:

1. **One toolkit and one stylesheet** for every component.
2. **One configuration mechanism** shared by every component.
3. **Freedesktop standards** for everything that crosses component boundaries
   (desktop entries, icons, MIME types, user directories).

The reference platform is **dkrescue**: musl libc, LLVM/Clang, dinit, no
systemd. dkde must run there. It must also run on ordinary glibc
distributions.

**Portability rule:** use only libc interfaces that both musl and glibc provide
(POSIX, plus the few GNU names musl also has, such as `program_invocation_short_name`).
Do not call glibc-only extensions: `mallopt`, `malloc_trim`, `malloc_usable_size`,
`mallinfo`/`mallinfo2`, `backtrace` (`execinfo.h`), `gnu_get_libc_version`,
`error`/`error_at_line`, or the GNU `strerror_r`; do not test `__GLIBC__`; and
do not hardcode `/lib64` or `ld-linux` paths. If a glibc feature is worth having,
guard it with `comptime builtin.target.isGnuLibC()` so it is never referenced
when linking against musl (as `common.perf` does for `mallopt`). Every change
must link for `x86_64-linux-musl` as well as glibc.

## 2. Goals and non-goals

### Goals (v1)

- Taskbar with running windows, a clock, and a start button, System tray (StatusNotifierItem)
- Windows 7-style start menu: pinned and recent apps, "All Programs", search,
  and places on the right-hand side.
- Terminal emulator in the style of Windows Terminal, built on libghostty-vt,
  with modern terminal extensions.
- File manager with Nautilus-level everyday functionality on local
  filesystems, Removable media mounting.
- Settings app covering appearance, the taskbar, the start menu, input, and
  default applications, Display configuration
- Runs on labwc with **no systemd and no logind**. A session D-Bus is allowed
  but optional: the shell works without one, and the features that need it
  (desktop notifications, the system tray) start only when the session was
  started under a bus (`DBUS_SESSION_BUS_ADDRESS` is set, for example through
  `dbus-run-session`). dkde talks to it through GIO's built-in GDBus, so there
  is no new library dependency.

- A text console (`dkde-console`) that replaces `agetty` on the VTs, with
  the terminal features of `dkde-term`, and falls back to a plain login
  when it can't start.

### Non-goals (v1)

These are explicitly out of scope. Adding any of them requires changing this
spec first.

- **Writing a compositor.** labwc is the compositor.
- **libadwaita** or any GNOME platform library beyond GTK4/GLib/GIO.
- **Accessibility via AT-SPI.**
- **X11 as the primary target.** dkde is Wayland-first and the default build
  has no X11 code or X11 library dependency. An optional X11 backend exists
  behind `zig build -Dx11=true` (see 5.9).
- **Translations.** Strings go through one helper so i18n can be added later.

## 3. Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | **Zig** | Pin an exact version (see 3.1). |
| Toolkit | **GTK4**, without libadwaita | Styled entirely by our own CSS. |
| GTK bindings | **zig-gobject** | Ghostty's build of zig-gobject (decided), pinned by hash. |
| Layer shell | **gtk4-layer-shell** | Panel, start menu, wallpaper surfaces, desktop icons, snap corners (win 11), alt tab |
| Wayland protocols | **zig-wayland** scanner | For protocols GTK doesn't expose (taskbar). |
| Terminal core | **libghostty-vt** (Zig API) | Pre-1.0: pin a commit. |
| Text rendering (terminal) | **Pango** into a GTK drawing area (v1) | A GPU renderer can replace it later behind the same interface. |
| Compositor | **labwc** | Needs `wlr-layer-shell` and `wlr-foreign-toplevel-management`. |
| Build | `zig build` | No meson, cmake or make in this repo. |
| Console | **Kernel interfaces only**: DRM/KMS, evdev and VT ioctls, PSF2 fonts | libghostty-vt is its only library. See 5.11. |

### 3.1 Version pinning

- **Zig:** 0.17.0, set in `build.zig.zon` as
  `.minimum_zig_version` and stated here. Decided: **0.17.0**. Zig is
  pre-1.0; upgrading is a deliberate, separate change, never incidental.
- **libghostty-vt and zig-gobject:** pinned by hash in `build.zig.zon`.
- **labwc:** state the minimum version the panel is tested against.

### 3.2 Dependency budget

Runtime libraries allowed in v1:

- GTK4 and its own dependency chain (GLib, GIO, Pango, Cairo, HarfBuzz,
  FreeType, Fontconfig, gdk-pixbuf, Graphene, libepoxy)
- gtk4-layer-shell
- wayland-client
- libghostty-vt
- Debus
- gvfs/udisks2
- shared-mime-info (data, needed for GIO content types)
- An icon theme (https://github.com/PapirusDevelopmentTeam/papirus-icon-theme)
- zigimg (MIT), vendored in `third_party/zigimg/` and used as a package with its own `build.zig`; wrapped by `src/imgcodec/` (decode to RGBA, EXIF orientation), shared by `dkde-view` and the PDF renderer. Zig 0.17.0, no system libraries.
- stb_image (public domain / MIT), vendored in `third_party/stb/`, JPEG decoding only, built by Zig's C compiler. Only a fallback in the PDF renderer, for JPEGs zigimg refuses (such as CMYK).
- zpdf (CC0), vendored in `third_party/zpdf/`, the PDF reader under `src/pdfrender/`
  (Zig 0.17.0, no dependencies). It is meant to replace poppler-glib in `dkde-pdf`, so
  that viewer needs no system PDF library. See `third_party/zpdf/README.dkde.md`.
- zig-yaml (MIT), vendored in `third_party/zig-yaml/`, used only by `dkde-hex`
  to read Kaitai Struct `.ksy` files. It is a copy of the `src/` directory of
  the GitHub commit `e5cf8ac3de410749fef57a3f3864100104043042` (the project has
  since moved to https://codeberg.org/kubkon/zig-yaml), with two small edits so
  it builds on Zig 0.17: `Parser.zig` and `Tree.zig` read struct fields through
  `field_names`/`field_types`, and the error bundle is created with `Wip.init`.
  Its own `build.zig` is not used. See `third_party/zig-yaml/README.dkde.md`.

- `dkde-console` uses **none** of the libraries above except
  libghostty-vt, and links nothing else: no libdrm, libinput, udev,
  xkbcommon, FreeType or HarfBuzz. Its display, input, keymap, fonts and
  configuration reader are written in this repository (5.11). The built-in
  Terminus font (SIL OFL 1.1) is vendored in `third_party/terminus/`.

Anything not on this list needs a spec change explaining why.

## 4. Architecture

Each component is a separate program. They share one Zig module, `common`,
and never link to each other.

`dkde-console` is the exception to "they share one Zig module": it uses
`termcore` (4.3) and nothing from `common` that touches GTK or GLib. See
5.11.

| Binary | Purpose |
|---|---|
| `dkde-panel` | Taskbar, start menu, clock, wallpaper. The shell. |
| `dkde-term` | Terminal emulator |
| `dkde-files` | File manager |
| `dkde-settings` | Settings |
| `dkde-console` | Text console on the VTs, replacing agetty |

### 4.1 Process model

- dkde has no init-system dependency: nothing in it starts, stops or queries
  a service manager. Service files for the optional daemons are provided for
  dinit, systemd and SysV init (see 5.10).
- labwc starts `dkde-panel` from its `autostart` file. If the panel exits
  unexpectedly, the autostart wrapper restarts it.
- Apps are normal Wayland clients. They use
  `G_APPLICATION_NON_UNIQUE`, because GApplication uniqueness requires a
  session D-Bus.
- **IPC:** the panel listens on a Unix socket at
  `$XDG_RUNTIME_DIR/dkde/panel.sock`. The protocol is one line of text per
  command. v1 commands: `toggle-menu`, `reload`. `dkde-panel msg <command>`
  is the client. This is what the labwc keybinding for the Super key calls.
- **Settings changes need no IPC.** Every component watches its config files
  with `GFileMonitor` and reapplies changes as they happen.

### 4.2 Shared module (`common`)

- Config loading, saving and watching (see 6.1)
- Stylesheet loading (see 6.2)
- XDG directories, including `user-dirs.dirs`
- Desktop entry lookup and launching, wrapping `GDesktopAppInfo`
- `app_id` → desktop entry matching (used by the taskbar and start menu)
- Error dialog helper
- String helper for future i18n

### 4.3 Terminal core (`termcore`)

The terminal code `dkde-term` and `dkde-console` have in common: the pty
(`openpty`, `fork`/`exec`, `TIOCSWINSZ`), the libghostty-vt setup,
key-encoding glue, colour schemes, and the INI reader. `termcore` imports
only `std` and libghostty-vt: no GTK, GLib or Pango. Only code both
programs use as written moves here (see 5.11 *Shared code*).

## 5. Components

### 5.1 Panel (`dkde-panel`)

**Surface:** a `wlr-layer-shell` surface on the `top` layer, anchored to the
bottom, left and right edges, reserving an exclusive zone equal to its height.
One per output.

**Layout, left to right:** start button, taskbar buttons (fill the remaining
space), clock.

**Pinned apps:** `[panel] taskbar-pinned` (desktop file IDs, in order) puts launcher buttons first on the taskbar. A pinned app that is not running shows as an icon that starts it; when it runs, its windows share that button (when windows are combined). Pin or unpin from the right-click menu of a taskbar button, or of an app in the Start menu ("Pin to taskbar"). Written only when you pin or unpin.

**Taskbar** (`wlr-foreign-toplevel-management-unstable-v1`, accessed through
the `wl_display` that GDK exposes):

- One button per toplevel window, showing its icon and title. The icon comes
  from matching the window's `app_id` to a desktop entry; a generic icon is
  used if there's no match.
- The active window's button is visibly highlighted.
- Left click: activate the window. If it's already active, minimize it.
- Middle click: close the window.
- Right click: a menu with Restore/Minimize, Maximize, and Close.
- Grouping by application (on by default): windows with the same `app_id`
  share one button with a count. Clicking a stack lists its windows; the
  right-click menu gains "Close all windows". `panel.conf`:
  `[panel] group-windows` (default true) and `show-labels` (default true;
  false shows icons only). Both are on the Settings Taskbar page and apply
  live.
- Add option to hide the task bar
- Add option to move the taskbar to other edges of screen

**Clock:** time and date 12hr default, in a format set in the config. Updates on the
minute boundary, not by polling every second. Noramal date options

**Wallpaper:** a separate layer surface on the `background` layer of each
output, showing an image or a solid colour from the config.

**`panel.conf` keys (M1):** `[panel] height` (pixels, default 40) and
`clock-format` (strftime-style, default `%-I:%M %p` over `%-m/%-d/%Y`); `[wallpaper] image` (path,
empty for none) and `color` (any CSS colour, default `#3a6ea5`). The panel
creates the config directory at startup so it can watch for the file
appearing.

**Wallpaper options (post-M1):** `[wallpaper] fit` (`cover`, `contain`,
`fill`, `center`), `slideshow-dir` (a folder of images that replaces `image`)
and `slideshow-minutes` (default 10; 0 keeps the first picture).

**Position and auto-hide:** `[panel] position` (`bottom`, `top`, `left` or
`right`; default `bottom`) and `autohide` (default false). A side panel is
vertical and shows icons only. An auto-hidden bar keeps its surface at full size, transparent, and slides in
over 150 ms when the pointer touches an 8-pixel strip at its edge (only that
strip takes pointer input while hidden, and it is painted at 1% opacity,
because a fully transparent surface receives no input). It hides again
500 ms after the pointer leaves, floats over windows instead
of reserving space, and stays out while the start menu is open. `height` is
the panel's thickness. Changing position or auto-hide rebuilds the bars live.

**Clock menu:** left click shows a month calendar; right click offers
"Adjust date/time" and "Clock format", both of which open Settings > Date &
time. The default format is two lines, `%I:%M %p` over `%m/%d/%Y`.

**Desktop icons:** the contents of the Desktop folder (`XDG_DESKTOP_DIR`) are
drawn on the primary output's wallpaper surface: folders first, `.desktop`
launchers shown with their own name and icon, hidden files skipped. Double
click opens (folders in dkde-files, launchers start the app, files in their
default app). Right click on an icon offers Open and Move to Trash; right
click on empty space is the wallpaper menu. Icons are placed freely: drag one
and it is remembered in `desktop.conf` (`[icons] <file name> = x,y`); new files
take the next free cell, filling a column top to bottom. `[desktop] icons`
(default true) turns them off and `[desktop] snap-to-grid` (default true) makes
a dropped icon settle in the nearest 96x104 cell; both are on the Settings
Taskbar page. Not done: multi-select drag, creating items from the desktop menu.

**System tray:** the panel hosts StatusNotifierItem icons, left of the clock,
when a session bus exists. It owns `org.kde.StatusNotifierWatcher` (nothing
else does in a dkde session), so apps that look for it register themselves.
Each item shows its `IconName` (or `IconPixmap`), its title as a tooltip, and
follows `NewIcon`/`NewTitle`/`NewStatus`; `Passive` items are hidden and
`NeedsAttention` ones are highlighted. Left click calls `Activate`, middle
click `SecondaryActivate`, right click shows the app's `com.canonical.dbusmenu`
(flat list: submenu entries indented under their parent, separators skipped,
mnemonic underscores removed) or calls `ContextMenu` for items without a menu.
An item disappears when its bus name does. Coordinates sent to the app are
zero, because Wayland gives a client no screen position. Not done: submenus as
real cascading menus, menu icons, check and radio state, tooltips with bodies,
the older XEmbed tray, and a tray on vertical bars laid out differently.

**Notifications:** when the session has a D-Bus session bus, the panel owns
`org.freedesktop.Notifications` and shows toasts at the top right on the
`overlay` layer (Desktop Notifications Specification 1.2, through GDBus).
Supported: summary, body (markup reduced to text), icon, replacing, expiry
(default 6 s, 0 never), click to dismiss, `NotificationClosed`. At most five
are shown. Not supported: actions, hints, sounds, a history or do-not-disturb.
Wayland only; with no session bus the panel logs that notifications are off.
**Sending one from a script:** `dkde-notify [-i ICON] [-t MS] SUMMARY [BODY]` (a
small program like `notify-send`, with nothing extra to install) sends a
notification through the session bus to whatever daemon owns it: the panel's, or
another. `-t 0` keeps it until dismissed. The text is shown as given, never as
markup or a command. For an automounter's hooks there are three forms that take only a
device node: `dkde-notify --mounted|--unmounted|--removed /dev/sdd1`. They look
up the label (`/dev/disk/by-label`) and the mount point (`/proc/self/mounts`)
themselves and show them as text, because devmon's `%l` and `%d` go through
`eval` and a label is chosen by whoever made the drive; only `%f` is handed
over. Anything but a node under `/dev` is refused.

**Quick settings:** status icons between the tray and the clock (network,
sound, battery, and airplane mode while it is on) open a flyout with Wi-Fi,
Bluetooth and Airplane mode toggles, volume with mute, a brightness slider and
the battery level. `[panel] quick-settings` is the comma-separated list of
items to show (`network,bluetooth,airplane,sound,brightness,battery`; unset
means all), set by switches on the Settings Taskbar page and applied live. Each
control needs its tool and appears only when it works: `nmcli` (Wi-Fi radio and
connection state), `bluetoothctl`, `rfkill` (airplane mode blocks or unblocks
all radios and needs access to `/dev/rfkill`), `wpctl` or `pactl`, and sysfs
for the battery (`/sys/class/power_supply/BAT*`) and the backlight
(`/sys/class/backlight/*`; brightness is set with `brightnessctl` when
installed, otherwise by writing sysfs, which needs permission). Icons refresh
every 20 seconds and whenever the flyout changes something. Not done: choosing
a Wi-Fi network or sound device from the flyout, and ordering the items.

**Virtual desktops:** the panel shows one icon in the system area (a grid and the
current desktop's number; hidden when there is only one desktop). A click opens
a chooser with a button per desktop, and the mouse wheel over the icon switches. It reads and drives labwc's workspaces through `ext-workspace-v1`
(vendored in `protocols/`). The number of desktops is labwc's
`<desktops><number>` in `rc.xml`, set on the Settings Taskbar page (1 to 9)
and applied by a labwc reconfigure. Default keybindings, added by `dkde-setup`:
Ctrl+Alt+Left/Right switch (`GoToDesktop`) and Ctrl+Alt+Shift+Left/Right
carry the active window along (`SendToDesktop`). The taskbar lists windows of
all desktops, because `wlr-foreign-toplevel` does not say which desktop a
window is on; activating a window on another desktop switches to it. Not done:
a per-desktop taskbar, "move to desktop" in the window menu, naming desktops
and an overview with thumbnails.

**Media keys and on-screen display:** the volume, mute and brightness keys
(`XF86AudioRaiseVolume`, `XF86AudioLowerVolume`, `XF86AudioMute`,
`XF86MonBrightnessUp`, `XF86MonBrightnessDown`) are bound by `dkde-setup` in
labwc to `dkde-panel msg volume-up|volume-down|volume-mute|brightness-up|
brightness-down`. Volume moves 5 points per press (raising it unmutes) and
brightness 10, through the same tools as quick settings (`wpctl`/`pactl`,
`brightnessctl` or sysfs). Each press shows a pill at the bottom centre of the
screen on the overlay layer (icon, level bar, percentage) for 1.5 s; it takes no
pointer input. Wayland only. Not done: microphone mute, keyboard backlight,
holding the key down repeats only as fast as labwc repeats the binding.

**Low battery:** on a machine with a battery the panel watches it itself (no
daemon, no timer outside the panel): every 60 seconds, every 15 when within
5 points of the low level, and every 2 minutes on mains power. `[power]
low-battery` (default 15) shows a notification once while discharging;
`critical-battery` (default 5) shows a second one that stays until dismissed and
starts a 30-second grace period, after which, if the machine is still on the
battery and still that low, `critical-battery-action` runs: `sleep` (the same
sleep command as the start menu), `poweroff` or `none`. The action runs once per
discharge; plugging in resets everything. A level that wobbles around the limit
warns once. `low-battery=0` turns the warnings off; a computer without a
battery never starts the watcher. The thresholds are read each time, so
Settings > Power & lock applies at once.

**Lock, screen off and sleep:** dkde has no lock screen of its own. A secure
one needs `ext-session-lock-v1`, which GTK 4 cannot be a client of (it sets its
own window role), so it would have to be a separate non-GTK program; until
then dkde runs a locker you install. `[menu] lock-command` and `sleep-command`
(panel.conf) name the commands; empty means detect: `swaylock`, `gtklock`,
`waylock` for locking, and for sleep `loginctl suspend` when logind runs, then
`zzz`, `pm-suspend`, `systemctl suspend`. The start menu's power list shows Lock
and Sleep when a command exists. `dkde-idle`, started by the labwc autostart,
uses `ext-idle-notify-v1` and runs the commands after `[power] lock-after`,
`screen-off-after` and `sleep-after` minutes without input (0 = never; sleep
locks first unless `lock-before-sleep=false`). Screen off is
`wlr-randr --off` for every output and `--on` when input resumes, which
disables the outputs rather than powering them down with DPMS. It reloads
panel.conf when Settings > Power & lock changes it.

**Start button:** opens and closes the start menu. Super is bound in labwc to
`dkde-panel msg toggle-menu`. labwc can bind a lone modifier released by
itself; labwc 0.9.3 documents this (`<keybind key="Super_L" onRelease="yes">` in
labwc-config(5)). See `data/labwc/rc-keybind.xml`.



### 5.2 Start menu (inside `dkde-panel`)

**Surface:** a layer surface on the `overlay` layer, anchored bottom-left,
with exclusive keyboard focus while it's open. It closes on Escape, on
clicking outside it, or after launching something.

**Layout (Open-Shell "Windows 7 style"):** add reference screenshots under
`docs/reference/` and treat them as the visual target.

- **Left column:**
  - Pinned apps (user-ordered; drag to reorder is post-v1)
  - Separator
  - Recently used apps (most recent first; length set in the config)
  - "All Programs", which swaps the left column to a category tree built
    from desktop entry `Categories`, following the XDG menu spec's main
    categories
  - A search box at the bottom
- **Right column:** user name, then links to Home, Documents, Pictures,
  Music, Downloads (from `user-dirs.dirs`, opened in `dkde-files`), then
  Terminal and Settings.
- **Bottom right:** a Shut Down button with a menu for Restart and Log Off.

**Profile picture:** the right column shows the user's picture beside their
name: `[user] picture` in `dkde.conf`, else `~/.face`, else a default icon.

**Search:**

- Typing while the menu is open goes straight to the search box; no click
  needed.
- Matches app `Name`, `GenericName` and `Keywords`. Prefix matches rank above
  substring matches. Results update as you type.
- Enter launches the first result. Arrow keys move through the results.

**Data sources:** desktop entries from `$XDG_DATA_DIRS/applications` and
`$XDG_DATA_HOME/applications`, honouring `NoDisplay`, `Hidden`, `OnlyShowIn`
and `NotShowIn`. The directories are watched, so newly installed apps appear
without restarting the panel.

**Launching:** always through `GDesktopAppInfo`, which handles `Exec` field
codes and `Terminal=true` (configured to use `dkde-term`).

**Power actions:** there is no logind, so the commands for Shut Down, Restart
and Log Off are set in the config. The defaults are `poweroff`, `reboot`, and
exiting labwc.

**`panel.conf` keys (M3), `[menu]`:** `pinned` (desktop file IDs, `;`
separated; unset pins Files, Terminal and Settings), `recent-count` (default
5), `shutdown-command`, `restart-command`, `logoff-command`. Recent apps are
stored in `$XDG_STATE_HOME/dkde/recent.conf`. The menu is built each time it
opens, so installed apps are always current. `Terminal=true` entries run as
`dkde-term -e <command>` (the `-e` flag arrives with M4).

### 5.3 Terminal (`dkde-term`)

**Model:** Windows Terminal. Tabs, profiles, and a settings file.

**Window:**

- Client-side decorations, with the tab strip in the title bar.
- A "+" button opens a new tab with the default profile. The dropdown next to
  it lists all profiles.
- **OPEN:** whether the CSD title bar should imitate the labwc theme or the
  two should share one look defined in dkde's stylesheet.

**Profiles:** name, command (default: the user's login shell), starting
directory, font, colour scheme, and cursor style.

**Terminal features required in v1.** libghostty-vt handles the parsing and
state; dkde-term must wire each one through to the UI:

- 24-bit colour
- Kitty keyboard protocol (via libghostty-vt's key encoding)
- Mouse reporting, including SGR mode
- Bracketed paste
- Focus in/out events
- Synchronized output
- OSC 0/2 window and tab titles
- OSC 7 current directory: new tabs open in the same directory
- OSC 8 hyperlinks: Ctrl+click opens them
- OSC 52 clipboard writes, with a per-profile on/off setting
- Scrollback with a configurable length, and search within it
- Copy and paste: Ctrl+Shift+C and Ctrl+Shift+V, plus Wayland primary
  selection

Images (kitty graphics protocol): **post-v1**, depending on what
libghostty-vt exposes.

**PTY:** `openpty` and `fork`/`exec`, both available in musl and glibc.
Resize is forwarded with `TIOCSWINSZ`.

**Implementation notes (M4):**

- Pinned to libghostty-vt from Ghostty tag `v1.4.0` (needs Zig 0.17.0); the
  dependency hash is in `build.zig.zon`.
- `dkde-term -e <command> [args...]` runs the command in the first tab
  instead of the shell. The start menu uses it for `Terminal=true` entries.
- Terminal shortcuts use Ctrl+Shift so plain Ctrl+letters reach the program
  running inside (readline's Ctrl+W, vim, tmux): Ctrl+Shift+T new tab,
  Ctrl+Shift+W close tab, Ctrl+PageUp/PageDown switch tabs, Ctrl+Shift+F
  find, Ctrl+Shift+C/V copy and paste, Shift+PageUp/PageDown scroll. This
  refines the Ctrl+T / Ctrl+W rows of 6.3 for this app.
- `term.conf` also takes `[terminal] scrollback-lines` (default 10000), and
  profiles take `opacity` (percent, 20 to 100; below 100 the background is
  see-through).
- A scroll bar shows when there is scrollback. F11 toggles fullscreen.
- Ctrl+click opens an OSC 8 link with the default handler for its scheme
  and reports an error if there is none.
- Input method (IME) composition is not wired up in v1.
- Colour schemes: `campbell` (default), `one-half-dark`, `solarized-dark`,
  `solarized-light`.

**Rendering:** Pango into a GTK drawing area, with a monospace grid and
font fallback through Fontconfig. Damage is tracked per row; there's no
full redraw on every update.

### 5.4 File manager (`dkde-files`)

**Model:** Nautilus-level everyday functionality, styled to match dkde. Add
reference screenshots under `docs/reference/`.

**Window layout:**

- Sidebar: Home, the XDG user directories, Trash, bookmarks, and mounted
  filesystems read from `/proc/self/mountinfo` (no gvfs).
- Path bar: breadcrumb buttons that switch to a text entry on Ctrl+L.
- Main view: five views, chosen from View in the menu bar: Details (name,
  size, type, modified; sortable columns), List (one narrow column of names),
  Small icons, Medium icons and Large icons. The choice is remembered.

**Operations (all through GIO):**

- Open with the default app; "Open With" lists other apps that handle the
  MIME type.
- Copy, cut, paste, rename (F2), new folder.
- Move to Trash (Delete) using GIO's local trash, which needs no gvfs.
  Permanent delete is Shift+Delete, with a confirmation.
- Long operations show progress and can be cancelled. Name conflicts ask the
  user what to do.
- Properties dialog: name, type, size, location, timestamps, and
  permissions. The name and the nine permission bits can be edited and are
  applied with OK (a rename, and `unix::mode` through GIO); owner and group are
  shown but not changed.
- Run: "Run" and "Run as Administrator" (through `common.elevate`, so sudo
  asks for the password in a dialog) for executable files; "Mark as
  Executable" / "Unmark as Executable" toggles the three execute bits.
- "Open in New Window" starts another `dkde-files` on a folder.
- **Drag and drop:** items can be dragged (as `GdkFileList`, so other
  programs get `text/uri-list`) onto a folder in the list, onto the empty space
  of a view, onto a sidebar entry (Trash trashes them) or a path-bar button.
  The default is a move; when only a copy is offered (Ctrl held) it is a copy.
  Files dropped from other programs are copied or moved the same way. Drops
  use the same background job as paste, with the same conflict questions.
- **Open With…** (context menu and File menu) opens a chooser of the programs
  that handle the file's type, with "Show all applications" and "Always use
  this application" (sets the default for the type). `open-with` in the
  context-menu lists still gives the first six programs inline.

**Other:**

- Live refresh with `GFileMonitor`.
- Type-to-search within the current folder.
- Hidden files toggled with Ctrl+H.
- Bookmarks stored in dkde's own config.

**Implementation notes (M5):**

- `dkde-files [folder]` opens `folder`, or the home directory.
- Cut and copy put the files on the system clipboard as
  `x-special/gnome-copied-files` (`copy` or `cut`, then URIs),
  `text/uri-list` and `text/plain` (the paths), so files can be pasted into
  another dkde-files window or another file manager, and files copied there
  paste here. A cut is pasted once, then the clipboard is cleared.
- The Trash entry browses `$XDG_DATA_HOME/Trash/files` directly. Restore
  reads the matching `.trashinfo` file. This is why gvfs is not needed.
- `files.conf` keys: `[files] show-hidden`, `[files] view` (`details`, `list`,
  `small`, `medium` or `large`; the older `grid` means `medium`), and
  `[bookmarks] paths` (`;` separated folders).
- **Context menu** (right click): a row of emoji buttons on top (Windows 11
  style, tooltips carry the names), then text entries. Both are configurable
  in `files.conf`, group `[context]`, as `;` separated action ids, where `--`
  is a separator: `quick` (the emoji row; default
  `cut;copy;paste;rename;trash`), `item` (on files and folders) and `folder`
  (on empty space). Defaults: `item` = `open;open-tab;open-window;open-with-choose;run;
  run-admin;exec;--;extract;compress-zip;compress-targz;restore;
  delete-permanent;--;properties`, `folder` = `new-folder;open-window;
  terminal-here;open-admin;toggle-hidden;bookmark;empty-trash;--;properties`.
  Ids: `open open-tab open-window open-with open-with-choose run run-admin exec extract
  compress-zip compress-targz restore delete-permanent empty-trash cut copy
  paste rename trash new-folder terminal-here open-admin toggle-hidden
  bookmark properties`. An id that does not apply to the selection (for
  example `run` on a folder, `restore` outside the Trash) is left out, and
  unknown ids are ignored. Extra commands: `[context-commands] <label> =
  <command>` and use `cmd:<label>` in a list; `%f` becomes the selected file
  (or `%F` all selected), `%d` the current folder, and the command runs in
  the current folder. Ctrl+D bookmarks
  the current folder; right-clicking a bookmark in the sidebar removes it.
- Copy and move run as an asynchronous job: nothing is scanned up front,
  progress and Cancel appear under the file list, and name conflicts ask
  (Skip, Keep Both, Replace, Replace All, Skip All, Cancel).

**Thumbnails:** **post-v1**.

**Archives:** the item context menu offers *Extract Here* for a single `.zip`,
`.tar`, `.tar.gz`/`.tgz`, `.tar.xz`/`.txz`, `.tar.bz2`/`.tbz2`, `.tar.zst`, `.7z`
or `.rar` file (into a new folder named after it, "name (2)" if taken) and
*Compress to .zip* / *Compress to .tar.gz* for the selection (named after the
single item, or "Archive"). They run `unzip`, `tar`, `7z`, `unrar` and `zip` in
the background, and an item is greyed out when its tool is missing. File names
reach the shell scripts only as positional parameters. Not done: progress, a
cancel button, password-protected archives, opening an archive as a folder.

### 5.5 Settings (`dkde-settings`)

**Window:** major categories on the left (Personalization, System, Network &
devices, Apps, Time & language, Accounts). A category opens a list of its pages,
each with an icon and a line on what it is for; a page opens below a breadcrumb
(`Apps › Console`) with a back arrow. `--page <id>` opens a page or a category.
Search narrows the categories and their lists. Terminal and Console are
side by side under Apps, and their descriptions say which is which: Terminal
is the desktop window (per user, with profiles), Console is the full-screen
text login with no desktop (system-wide, needs an administrator password).
Changes are
**not** written as you make them: they are held in memory (the controls show
them) and a bar at the bottom says "N changes not applied yet" with **Revert**
and **Apply**. Apply writes the config files once, and the components pick the
changes up through their file monitors. Revert drops the held changes and shows
the saved values. Closing the window with held changes asks whether to apply
them. Actions that run a program (connecting to Wi-Fi, pairing, changing the
volume, the keyboard-shortcut take-over, Display's own apply with a revert
timer) are their own explicit actions and are not held back.

**v1 pages:**

| Page | Settings | Writes to |
|---|---|---|
| Appearance | Wallpaper, light/dark, accent colour, UI font, icon theme | dkde config |
| Taskbar | Height, position, auto-hide, grouping, labels | dkde config |
| Date & time | Clock style or custom format, time zone, set the clock | dkde config; `/etc/localtime`, `date` (administrator) |
| Display | Resolution, refresh rate, scale per output | `wlr-randr`, then `display.sh` |
| Network | Wi-Fi on/off, list, connect, disconnect | `nmcli` |
| Bluetooth | Power, scan, pair, connect, remove | `bluetoothctl` |
| Printers | List, default, test page, add, remove | CUPS (`lpstat`, `lpoptions`, `lpadmin`) |
| Start menu | Pinned apps, recent-apps count, power commands | dkde config |
| Terminal | Default profile, editing profiles, with a preview of font, scheme, cursor, opacity and padding | dkde-term config |
| Console | Font (PSF or TrueType), size, colour scheme, scrollback, with a preview | `/etc/dkde/console.conf`, through `dkde-console config set` (administrator) |
| Keyboard | Layout | labwc `environment`, then `labwc --reconfigure` |
| Keyboard shortcuts | Rebind dkde's own shortcuts | labwc `rc.xml` `<keybind>` blocks, then reconfigure |
| Mouse & touchpad | Pointer speed, natural scrolling, tap to click | labwc `rc.xml` `<libinput>` section, then reconfigure |
| Default apps | Browser, file manager, terminal, text editor | `mimeapps.list` |
| Language & region | Language and the formats (dates, numbers, currency, paper, measurements), from the UTF-8 locales `locale -a` lists | `~/.config/locale.conf`, read by `dkde-session` at sign-in (applies to the next session; no password) |
| About | Device name, OS, kernel, architecture, processor, memory, storage, up time, dkde version, with a Copy button | nothing |

**Implementation notes (M6):**

- Appearance writes `[appearance] dark`, `accent`, `font` and `icon-theme` to `dkde.conf`. The icon theme drop-down lists the themes installed under `$XDG_DATA_DIRS/icons`, `~/.local/share/icons` and `~/.icons` (folders whose `index.theme` has `Directories` and is not `Hidden`); "System default" clears the choice.
  Every component applies them live through `common.style.Appearance`.
  The wallpaper settings are the `[wallpaper]` keys of `panel.conf`.
- The User page sets the profile picture (`[user] picture` in `dkde.conf`)
  and lists the accounts (uid 1000 and up, with a real shell). It can add
  and delete accounts, change a password or full name, grant or remove
  administrator rights (membership of `sudo`, `wheel` or `admin`), edit any
  account's group memberships, and create or delete groups with a group id of
  1000 or more. Every privileged step asks for the user's password through
  `common.elevate`. Guard rails: the signed-in account and root cannot be
  deleted, and your own administrator rights cannot be removed.
- `common.elevate` (a dkde-owned password dialog, because there is no polkit
  agent or D-Bus) runs a command through `sudo -S -k` and feeds it the
  password on stdin; the password is never on a command line or in the
  environment. User-supplied values reach the privileged scripts only as
  positional parameters, never as script text. "Run as administrator" is in
  the start menu's item menu and "Open Folder as Administrator" in Files.
  **dkde's own tools do not use polkit** (it needs `polkitd` and a tracked login
  session, which dkde does without); `dkde-polkit` (5.12) is the agent for the
  other programs that do.
- The Sound page sets the default output's volume and mute through `wpctl`
  (PipeWire) or `pactl` (PulseAudio). It tries `wpctl` first and uses the
  first tool that is installed and can reach a running sound server (so WSL,
  which only has a PulseAudio socket, ends up on `pactl`); if none works it
  names the packages to install. dkde has no D-Bus, so there is no direct connection to
  the sound server. Only the default output is controlled.
- Default apps use GIO's `mimeapps.list` writer. "Terminal" has no MIME
  type, so it is stored as `[default-apps] terminal` in `dkde.conf`.
- `term.conf` holds `[terminal] default-profile` and one `[profile:<name>]`
  group per profile with `command` (empty means the login shell),
  `directory`, `font`, `color-scheme`, `cursor-style` (`block`, `bar` or
  `underline`) and `osc52` (boolean). Further profile keys: `title` (fixed
  tab title), `icon` (icon name or image path), `tab-color` (CSS colour for the
  tab's top edge), `environment` (`NAME=value;NAME=value`), `columns` and
  `rows` (size of a new window in cells; 0 keeps the default), `startup`
  (`windowed`, `maximized`, `fullscreen`), `close-on-exit` (`always`,
  `success` or `never`; a tab that stays open prints the exit code),
  `padding` (pixels, 0 to 40, default 4), `copy-on-select` (default true) and
  `opacity`. `command` is split like a shell command line, so it may carry
  arguments. The terminal reloads `term.conf` while running: open tabs follow
  opacity changes; other settings apply to new tabs.
- labwc reloads its `environment` file on reconfigure (labwc-config(5)), so
  the keyboard page writes `XKB_DEFAULT_LAYOUT` there and runs
  `labwc --reconfigure`.

- **Hardware pages** (Display, Network, Bluetooth, Printers, Date & time and the
  Sound device pickers) drive command-line tools and never link a library, so
  each page says which package to install when its tool is missing. Pages are
  built on first visit and refresh when shown. Commands run asynchronously.
  - *Display* needs `wlr-randr` 0.4 or newer (`--json`). A changed mode
    reverts by itself after 15 seconds unless the user keeps it. Keeping it
    writes `$XDG_CONFIG_HOME/dkde/display.sh`, which the labwc autostart runs
    at login. Arranging several outputs and turning one off are not done yet.
  - *Network* needs NetworkManager (`nmcli`). A new secured network asks for
    its password; `nmcli` takes it as an argument, so it is briefly visible in
    the process list.
  - *Bluetooth* needs BlueZ (`bluetoothctl`) with `bluetoothd` on the system
    bus. Pairing uses a no-input agent, so devices that ask for a PIN fail.
  - *Printers* need CUPS. Removing or adding a printer asks for the
    administrator password through `common.elevate`. Adding is by name and
    address with the driverless (`everywhere`) driver; there is no discovery.
  - *Sound* also lists output and input devices, sets the default, and plays a
    generated test tone (left, right or both) through `pw-play` or `paplay`.
  - *Date & time* offers presets or any strftime pattern; the zone list comes
    from `/usr/share/zoneinfo/zone1970.tab`. Zone and clock changes are
    administrator actions. There is no network time sync.

- **Keyboard shortcuts** lists the entries of `common.labwc.dkde_keybinds`
  (start menu, terminal Ctrl+Alt+T, lock Ctrl+Alt+L, Task Manager, screenshots,
  volume and brightness keys, desktop switching) with their current key read
  from `rc.xml`, found by the command or action each block runs rather than by
  its key, so a rebound entry is still recognised. Change opens a dialog that
  records the next key press (modifiers C-, A-, S-, W-; a plain letter needs a
  modifier, while function, media and Print keys may stand alone; the bare Super
  key is allowed for the start menu only); Reset restores the default key. A key
  already bound to another entry of rc.xml is refused.
  **dkde owns every shortcut.** Besides its own, the list holds labwc's window
  shortcuts as explicit entries: Alt+Tab and Alt+Shift+Tab (`NextWindow`,
  `PreviousWindow`), Alt+F4 (`Close`), Super+A (`ToggleMaximize`), Super with
  the arrow keys (`SnapToEdge`, left, right, up, down) and Alt+Space
  (`ShowMenu menu="client-menu"`). `dkde-setup` writes them all and removes
  `<default />` from `<keyboard>`, so labwc binds nothing beyond rc.xml and a
  change made in Settings is the only definition of that shortcut. labwc's
  Super+Return (`lab-sensible-terminal`) and its amixer and brightnessctl keys
  are not carried over: Ctrl+Alt+T and dkde's own volume and brightness keys
  replace them. On an rc.xml that still has `<default />`, the page says so,
  lists what labwc adds (read from the `keybinds listed below` block of
  labwc-config(5), via `zcat` of the installed man page, with a built-in copy of
  the 0.9 list as fallback), and offers *Use dkde's shortcuts only* to do the same
  migration. A shortcut cannot be switched off here (rebind or reset only). Other
  keybinds the user put in rc.xml are listed read-only below.

**Editing labwc files:** only dkde's own sections and keys are changed, and
the rest of the file is preserved. A backup is written before the first edit.

**Console page.** Font, size, colour scheme and scrollback for `dkde-console`,
with a live preview drawn by the console's own renderer code. It never writes
`/etc` itself: **Apply** runs `sudo dkde-console config set …` for each change
(see 5.11 *Configuration tools*).

### 5.6 Accessories (v1.1)

Small apps that share `common`, the stylesheet and the config conventions.
Each ships a `.desktop` file with its `MimeType=` list so Open With,
default apps and the start menu find it.

| Binary | Purpose | Notes |
|---|---|---|
| `dkde-edit` | Text editor (Notepad) | Open/save, find/replace, word wrap, font. Default `text/plain` handler. |
| `dkde-calc` | Calculator | Standard and scientific modes, full keyboard entry. Evaluation logic unit-tested. |
| `dkde-view` | Image viewer | Zoom, fit, rotate, previous/next in folder, set as wallpaper. |
| `dkde-tasks` | Task Manager | Processes tab (from `/proc`, end process) and a Performance tab (CPU, memory, disks, network, GPU). Opened with Ctrl+Shift+Esc. Right-click a process for End Task, Force Quit (with a confirmation), Copy PID and Copy name; Delete also ends the selected one. |
| `dkde-snip` | Screenshots | `wlr-screencopy-unstable-v1`. Full screen, window, or region. Print Screen. (if possible a scroll option for webpage) |
| `dkde-hex` | Hex editor | Whole file in memory (up to 1 GiB). Offsets, hex and text panes; overwrite and insert; undo and redo; select, copy as hex or text, paste hex; find (text or hex bytes, both directions, wrapping); go to offset; 8, 16 or 32 bytes per row; data inspector (8 to 64-bit integers, floats, bits, in either byte order). Saves with `g_file_set_contents`, which replaces the file and does not keep unusual permissions. **Structure (reverse engineering):** reads [Kaitai Struct](https://kaitai.io) `.ksy` descriptions, parses the open file with them and shows a tree of fields with values and byte ranges. Selecting a field selects its bytes, the cursor selects the field it is in (breadcrumb in the status bar), and fields are coloured in the hex view. A format is picked automatically from the file's magic bytes (or a unique file extension), by Structure ▸ Choose format…, or loaded by hand (Load definition…). Formats are **not bundled** (their licences are mixed): point `[hex] formats-dir` in `hex.conf` (or Structure ▸ Formats folder…) at a folder of `.ksy` files such as a clone of kaitai_struct_formats; the default is `~/.local/share/dkde/formats`. Structure ▸ Get formats… shows the project link (https://github.com/kaitai-io/kaitai_struct_formats) and, when `git` (or `curl` or `wget` together with `tar`) is installed, a Download button that fetches the formats into that folder; without those tools it says what to install. Nothing is downloaded without that click. Find strings lists ASCII and UTF-16 text with offsets. Not done: huge files, bookmarks, comparing two files, writing back through a format, `process` (xor, zlib), `valid` checks, `params` types, user-defined methods, `_io` seeking inside substreams of other objects beyond `pos`/`io`. A parse that fails keeps what it read and shows the error as a node. **ImHex patterns:** `.hexpat` files are a second front end feeding the same tree, panel and colours (patterns can set their own with `[[color]]`). Understood: `struct`, `union`, `enum`, `bitfield` (including computed values), `using`, templates, inheritance, `namespace`, `fn` with parameters and defaults, `if`/`else`/`while`/`for`/`match`, `be`/`le`, `@` placement, pointers, arrays (counted, `while(...)`, null-terminated), expressions with `$`, `this`, `parent`, `sizeof`, `addressof`, the attributes `name`, `color`, `hidden`, `inline`, `sealed` and `no_unique_address`, `#define`, `#ifdef`, `#pragma endian`, `import` of files from the `includes/` folder, and a built-in subset of the `std::` library (`mem`, `string`, `math`, `core`, `ctype`, `format`). Not understood, shown as an error: `try`/`catch`, sections, array initialisers, `[[format]]`/`[[transform]]` and visualisers (ignored), `std::time` and hashing, and function-like `#define`. Patterns are **not bundled**: the community collection (https://github.com/WerWolv/ImHex-Patterns) is GPL-2.0, which does not fit dkde's MIT licence. Point `[hex] patterns-dir` in `hex.conf` at a clone (it has `patterns/` and `includes/` inside; default `~/.local/share/dkde/patterns`). A pattern is picked automatically from its `#pragma magic` at offset 0, or a file name matching the extension; a Kaitai format wins a tie. Structure ▸ Get ImHex patterns… shows the link and downloads the collection like the Kaitai one. **Analysis tools** (Analyze menu and Edit menu): Checksums (MD5, SHA-1, SHA-256, CRC-32 of the selection or the file); Entropy and histogram (entropy per block across the file, click to jump, and byte-value counts); Compare with file (differences in red, F7/Shift+F7 to step, Clear comparison); Disassemble selection (through `objdump -D -b binary` when installed, for x86-64, x86, ARM, AArch64, MIPS, RISC-V, PowerPC if that objdump supports them); Follow value as offset (Ctrl+J, reads 2, 4 or 8 bytes in the inspector's byte order) and Back (Alt+Left); Bookmarks with names and comments (Ctrl+B to add; underlined in the view; kept per file in `$XDG_STATE_HOME/dkde/hex-bookmarks/`, written only when changed); Find modes Text, Hex with `??` wildcards, and Number (u8 to u64, signed, float, double, either byte order); Copy as C array, Python bytes, Base64 or an escaped string; Fill, XOR, Reverse and byte-swap on the selection. Patterns are also found by content type (`#pragma MIME`) and by magic at any offset, not only at 0. **Tabs:** each file, disk or process opens in its own tab in one window (File ▸ New tab Ctrl+N, Close tab Ctrl+W, Ctrl+PageUp/PageDown to switch); every tab has its own undo history, view, structure, bookmarks and comparison; Open, Open disk and Open process memory use the current tab when it is empty and a new tab otherwise; closing the window asks about each tab with unsaved changes. Not done: scripting, dragging tabs between windows. **Process memory** (Disk ▸ Open process memory…): pick a process, then one of its readable regions from `/proc/PID/maps`; the region opens **read-only** through `/proc/PID/mem` as a 4 MiB window with the real address in the left column and in the status line (Go to takes an address; Follow value as offset follows pointers). Reading another user's process, or any process where `ptrace_scope` forbids it, needs dkde-hex started as administrator; it says so. Not done: writing to a process, searching all regions at once, following a region as it changes. **Disk mode** (Disk menu, or `dkde-hex --device /dev/sdX`): opens a disk, a partition or any device or image file **read-only**, as a 4 MiB window with the real device offset in the left column, a status line with the sector (LBA) and offset, Go to sector…, and Previous/Next window; the size cannot change (no insert, delete or append). Reading a device that needs root offers to reopen `dkde-hex --device` as administrator through the sudo dialog. **Writing is gated:** Disk ▸ Enable writing (with a warning) reopens the device read-write; Write changes (Ctrl+S) lists how many sectors differ from what was read and which, warns when the disk or one of its partitions is mounted, and only writes the changed sectors after you confirm. The Structure view works on the window, so a Kaitai format such as an MBR or GPT shows partition tables. **Find searches the whole device** (or process region), not only the 4 MiB window, in 8 MiB steps with a percentage in the status line, both directions, wrapping; starting another search cancels the running one, and with unwritten edits it searches the window only. The window is 4 MiB unless `[hex] disk-window-mib` (1 to 512) says otherwise; it is held in memory, so that is the limit on what can be edited at once. **Disk ▸ Save as image…** copies the whole device or process region into a regular file (4 MiB at a time with a percentage; Cancel imaging stops it and keeps the partial file). The source is only read; unreadable stretches are stored as zeros and counted; a device, or the file being read, is refused as the destination. **Disk ▸ Clone to another disk…** copies the open disk onto another device the same way, after a picker and a confirmation naming both; it refuses the source or a partition of it, a target smaller than the source, a mounted target (or one with a mounted partition), and process memory, and needs administrator rights to open the target for writing. Not done: verifying the copy afterwards, resuming, undo after a write. See `docs/hex-structure.md`. |
| `dkde-pdfcheck` | Renderer checker | Headless. `dkde-pdfcheck [--pages N] [--scale S] [--out DIR] [--report FILE] [--trail FILE --resume] [--shard I/N] [--max-mb N] [-v] PATH...` draws the pages of every PDF in the given files and folders and prints one JSON line per file (pages, time, error, and counts of what was not drawn, such as `font-embedded-not-read` or `image-jpx`), then a summary sorted by how many files are affected. The trail file is written before each file, so after a crash the last `BEGIN` without an `END` names the file, and `--resume` skips past it. Events are also logged through `DKDE_LOG=debug` (scope `pdfrender`) or `-v`. |
| `dkde-pdf` | PDF viewer | **Optional:** built only with `zig build -Dpdf=true`, linking `poppler-glib` by name (`pkg-config poppler-glib`; the few calls it uses are declared by hand, so no headers are needed). One scrolling column, pages rendered on demand and cached; zoom presets, fit width and fit page, Ctrl+wheel zoom; go to page; text search with highlights across the whole document and next/previous; copy a page's text; password prompt for protected files. Not done: text selection with the mouse, outline and thumbnail sidebars, annotations, forms, printing, two-page view, HiDPI-sharp rendering. **In progress:** `dkde-pdf` is moving from poppler-glib to a renderer in Zig (`src/pdfrender/`, on the vendored zpdf parser, drawing with cairo), so it needs no system PDF library. It already draws paths, fills, strokes, clips, colours, images (raw samples, indexed, masks, soft masks, JPEG), embedded TrueType fonts (simple and composite, drawn from their own outlines), form XObjects, constant transparency, page rotation and text in substitute fonts; embedded CFF and Type 1 font outlines, shading, patterns, blend modes, soft-mask groups, JPEG 2000, JBIG2 and CCITT come next, and the viewer switches over (and `-Dpdf` goes away) once it draws the files poppler does. |
| `dkde-charmap` | Character Map | Unicode blocks (Latin, Greek, Cyrillic, arrows, maths, box drawing, symbols, emoji and more) as a grid of at most 256 characters; click to collect into a box, copy. Hover shows the code point and UTF-8 bytes. No search by character name (GLib has no name table). |
| `dkde-clock` | Clock | Stopwatch with laps, countdown timer, and a one-shot alarm. A finished timer or alarm sends a desktop notification (session bus) and a beep. Timers and alarms run only while the window is open: there is no background service. |
| `dkde-calendar` | Calendar | A month grid with **events** (title, place, start and end date and time, all-day, repeat daily/weekly/monthly/yearly, reminder from "at the start" to a week before, notes), a free-text note for any day, and two optional **liturgical overlays**, each a toggle: the **Novus Ordo** General Roman Calendar (solemnities, feasts, memorials and optional memorials, Lent weekdays, transferred solemnities, Sunday and weekday lectionary cycle) and the **1962** calendar (classes I to IV, Ember days, commemorations, transfers, leap-year shift). **Calendar systems** (a drop-down, `[view] system`, default `julian`): the **Julian** (Old) Calendar, the **Gregorian**, and the **International Fixed Calendar** (13 months of 28 days, Sol between June and July, every month starting on a Sunday of the Fixed week; Leap Day after June 28 and Year Day after December 28 are outside the week). The grid, the month title and the day panel follow the chosen system, each cell shows the civil date small, and the day panel lists the date in the other two. Events, reminders and the liturgical overlays always use the civil (Gregorian) date, whatever the view; the overlays do not yet compute Julian-calendar feasts or Pascha. A Fixed weekday is its own cycle, so a Fixed Sunday is generally not a civil Sunday. A third overlay, **Russian Orthodox** (`[view] orthodox-ru`), follows the Old Calendar: Pascha by the Julian reckoning (`orthodox.zig`), the Triodion (Publican and Pharisee to Forgiveness Sunday), Great Lent and Holy Week, the Pentecostarion, the Sundays after Pentecost, and the fixed feasts and saints by their Julian dates (`liturgy-ru.txt`). All three overlays mark **fast and abstinence days with food emoji** (⛔ total or fast and abstinence, 🥣 strict, 🍇 wine and oil, 🐟 fish, 🍷 wine only, 🧀 dairy, 🍽️ fast only): the Orthodox fasts (Great Lent, Apostles', Dormition and Nativity Fasts, Wednesdays and Fridays, single fast days, fish on great feasts), Novus Ordo (Ash Wednesday, Good Friday, Fridays) and 1962 (Lent, Ember days, vigils, Fridays, after the 1917 Code). The emoji are a guide only: bishops' conferences, jurisdictions and parishes differ. Not done: the Revised Julian (New Calendar) fixed feasts, the Orthodox Gospel and Epistle cycle, the eight tones, the fixed Sundays of Zacchaeus and the Canaanite Woman. Both Catholic overlays show the liturgical colour and season in each day's cell and the details in the day panel. Easter and everything counted from it are computed (any year); fixed days come from `liturgy-no.txt` and `liturgy-1962.txt` (built in; a copy in `~/.config/dkde/` replaces them), so they can be proofread and corrected without a rebuild. Events are `[event.<id>]` groups and notes `[notes] YYYY-MM-DD` in `~/.config/dkde/calendar.conf`; the overlay choices are `[view] novus-ordo`, `tlm-1962`. **Reminders** are sent as desktop notifications by `dkde-panel`, which is always running: it watches `calendar.conf`, keeps one timer set for the next reminder (re-checking the wall clock at least every 5 minutes, so a resume from suspend catches up) and sends it through its own notification server. There is no cron or init-system timer, and nothing wakes while no reminder is pending. **iCalendar (.ics)**: *Options* has Import, Export and a **sync file**. Choosing a sync file (`[sync] ics-file`, for example in a Syncthing or Nextcloud folder) makes the calendar merge that file in at start-up and on *Sync now*, and rewrite it after every change, so another device that reads the same file sees the changes. Events match by UID (`<id>@dkde` for its own); times are written as floating local times, and UTC times from other programs are converted to local. Carried over: title, place, notes, dates and times, all-day, a simple repeat, one reminder and the colour. Not carried: repeat details beyond daily/weekly/monthly/yearly (INTERVAL, BYDAY, COUNT, UNTIL), time zones other than local, attendees, attachments; an event deleted in the other program is not deleted here. Not done: invitations, CalDAV, time zones, end-of-repeat dates, editing one occurrence of a repeating event, moving Ascension and Corpus Christi to Sunday, the Epiphany on a Sunday. |
| `dkde-color` | Colour | Red, green and blue sliders, a hex box that accepts `#rgb` and `#rrggbb`, and rgb() and hsl() read-outs with copy buttons. It cannot pick a colour from the screen. |
| `dkde-parted` | Partitions | **Pending operations:** New table, New partition (optionally formatted in the same step), Delete, Resize, Format, Label, Flag and Erase are queued, not run: the table and bar show the predicted layout, a list at the bottom shows what is pending, and Undo last, Clear all, Show commands (the exact commands) and Apply are there. Apply asks once, runs the commands that need no password (image files) and then all administrator commands as one script (one password, stopping at the first failure), and re-reads the disks. Every apply is recorded in `$XDG_STATE_HOME/dkde/parted.log` (the Log button). Mount, Unmount, Check, New image and Open image act at once. `dkde-parted --selftest IMAGE` runs, as root and with no window, the commands the tool generates for every installed filesystem (create, format, check, label, grow, delete) against a scratch image file and prints pass or FAIL for each; it never touches a disk. Run it on a new machine before trusting the tool. An apply cannot be cancelled once started, to avoid a half-finished change. **Layout like GParted:** the chosen disk is picked from a drop-down at the top right, its size bar runs across the window (labelled, clickable segments, free space), and below it is a table with Partition, File system (with a colour), Mount point, Label, Size, Used, Unused and Flags (usage is shown where `lsblk` knows it, that is for mounted filesystems; flags for images). **Filesystems** come from a table (`fs.zig`) and appear only when their tools are installed: ext2/3/4, btrfs, xfs, FAT16/FAT32, exFAT, NTFS, F2FS, JFS, ReiserFS, NILFS2, UDF, HFS+ and swap, and the Filesystems button lists what is available and which package supplies the rest. Per filesystem it can create (with a label), check read-only, change the label (`e2label`, `fatlabel`, `ntfslabel`, `xfs_admin`, `btrfs filesystem label`, ...), and resize where a tool exists (ext2/3/4, NTFS, FAT, ReiserFS grow and shrink; btrfs and xfs through a temporary mount, xfs and F2FS grow only). New partition can format in the same step; Flag sets or clears boot, esp, bios_grub, msftdata, swap, lvm, raid, hidden; Erase runs `wipefs -a`. Lists disks and their partitions (from `lsblk`) and **disk image files** (`.img`, read with `parted -m`) with a labelled size bar (click a segment to select it) and free space; creates sparse images with a table (New image…, no administrator rights needed), opens existing ones (`dkde-parted file.img` or Open image…), and changes images that hold no filesystem as you; anything that needs a block device, or a filesystem inside an image, goes through a loop device (`losetup -fP`) as administrator; resizes a partition (grow into the free space after it, or shrink) together with its filesystem: ext2/3/4 (`e2fsck`, `resize2fs`), NTFS (`ntfsresize`) and FAT (`fatresize`), the filesystem first when shrinking and after when growing; xfs and btrfs are refused with the reason; creates a partition table (GPT or MBR), creates and deletes partitions, formats (ext4, btrfs, xfs, FAT32, exFAT, NTFS, swap, as far as the `mkfs` tools are installed), mounts and unmounts, and runs a read-only filesystem check. Everything that changes a disk runs through `parted`, `mkfs.*`, `mount`, `umount` and `fsck` with `common.elevate` (the sudo password dialog), after a confirmation that names the device. **Safeguards:** nothing that rewrites a disk is offered while one of its partitions is mounted; the disk that holds `/`, `/boot`, `/usr`, `/var` or active swap is read-only here; partition creation is aligned to 1 MiB. Not done: LUKS, bcachefs, ZFS and other filesystems without a row in the table, moving a partition or its data, copying a partition, LVM, RAID, encryption, SMART, and editing flags and type GUIDs (use `dkde-hex` Disk mode for raw sector edits). |
| `dkde-disks` | Disk Usage | Mounted real filesystems (from `/proc/self/mounts`, pseudo filesystems hidden) with usage bars, and a folder scanner that lists the largest entries of any folder with sizes and percentages. The scan runs one folder per main-loop step, so the window stays usable; it reports allocated size, like `du`. |

**Implementation notes (accessories):**

- `dkde-calc`: expressions are parsed by a recursive-descent evaluator
  (`+ - × ÷ ^ ! % mod`, parentheses, `sin cos tan asin acos atan ln log
  sqrt abs exp`, `π`, `e`); degrees or radians; Enter evaluates.
- `dkde-edit`: UTF-8 text only. Keys in `edit.conf`: `[edit] word-wrap`,
  `font`. Ctrl+N/O/S, Ctrl+Shift+S, Ctrl+F or Ctrl+H for find and replace.
- `dkde-view`: decodes in Zig through the shared `imgcodec` module (zigimg:
  PNG, JPEG baseline and progressive, GIF, BMP, TGA, QOI, TIFF, PCX, netpbm,
  and a few older formats), honouring EXIF orientation. Formats zigimg does
  not read (WebP, SVG, ICO, AVIF, JPEG XL, animated GIF frames beyond the
  first) fall back to gdk-pixbuf and whatever loaders are installed (WebP
  needs `webp-pixbuf-loader`, SVG needs `librsvg2-common`). "Set as
  wallpaper" writes `[wallpaper] image` and clears `slideshow-dir`.
- `dkde-tasks`: two tabs. **Processes** lists processes from `/proc`, refreshed
  every 1.5 s; a search box filters by name, command line or PID; busy CPU,
  memory and disk cells are tinted. The name is the program's file name
  (`/proc/<pid>/exe`), else the first word of its command line, else the
  kernel's thread name, so a program that renamed its main thread still reads
  as itself; files named by a version number (`.../versions/2.1.316`) are
  skipped. Columns: Name, PID, User, Status, CPU %, Memory, Disk, Threads,
  Priority and Command; the View menu shows and hides all but Name, and the
  choice is kept in `$XDG_STATE_HOME/dkde/tasks.state`. Every header sorts.
  **Disk** is read and written bytes per second from `/proc/<pid>/io`, which only
  the owner and root may read: other processes, and every process on a kernel
  built without task I/O accounting (WSL2), show a dash. There is no
  per-process network column: Linux has no unprivileged per-process traffic
  counters. End Task sends SIGTERM, Force Quit SIGKILL after confirmation.
  The right-click menu adds **Open file location** (the folder of the program
  file, for processes whose file is known), **Priority** (High, Above normal,
  Normal, Below normal, Low, which are nice -10, -5, 0, 5 and 15; raising a
  priority needs root, as on any Linux system) and Copy command line.
  `--tab processes|performance` and `--resource cpu|memory|sda|eth0|card0` choose
  what opens first.
  **Performance** is laid out like the Windows 11 Task Manager: a list of CPU,
  Memory, each disk, each Ethernet and Wi-Fi adapter and each GPU, each with a
  60-sample thumbnail, and for the selected one a large graph and its figures.
  CPU: utilization, speed, processes, threads, up time, base speed, sockets,
  cores, logical processors, virtualization, L1 to L3 cache, and a per-logical-
  processor graph view. Memory: in use, available, committed, cached, slab,
  swap, and a composition bar. Disk: active time, response time, read and write
  speed, capacity, type (SSD, HDD, NVMe), system disk. Network: send and
  receive in Kbps/Mbps, IPv4 and IPv6, MAC, link speed, driver, and for Wi-Fi
  the SSID (via `nmcli`) and signal strength. GPU: from sysfs; AMD shows
  utilization, VRAM, temperature, power and clock; Intel shows clock speed
  only. NVIDIA's proprietary driver exposes nothing in sysfs, so it is listed
  without figures. Disks, network adapters and GPUs are looked for again every
  nine seconds: a device that appears gets a row, and one that disappears
  loses its row (and comes back with it).
- `dkde-snip`: full screen and region, for the first output. The picture is
  saved to `<Pictures>/Screenshots/` and copied to the clipboard. **Window
  capture and scrolling capture are not offered:** wlr-screencopy and
  wlr-foreign-toplevel give no window geometry and no way to drive another
  program's scrolling. `dkde-snip --full` and `--region` capture at once.
- labwc bindings (`data/labwc/rc-keybind.xml`): Print and Shift+Print for
  screenshots, Ctrl+Shift+Esc for the Task Manager.
- Added protocol: `wlr-screencopy-unstable-v1` (vendored in `protocols/`).
- Taskbar buttons have a capped width and sit left to right; they only
  shrink (labels ellipsize) when the bar is full.

### 5.8 First-run setup (`dkde-setup`)

A command-line tool that checks what a working session needs and fixes what
it can. User-level fixes (labwc `autostart`, `rc.xml` keybindings,
`environment`) are applied after one confirmation, only add to existing
files, and back them up once. System-level fixes (the WSL `.X11-unix` sticky
bit, `video`/`input` groups without logind, a login-manager session entry)
are never run silently: the command and reason are shown and each runs only
on an explicit yes. `--check` reports only; `--yes` applies user-level fixes
without asking.

**One time only.** `dkde-setup --once` is what `dkde-session` runs before
starting labwc: it applies the user-level fixes (labwc `autostart`, keybindings
including the take-over of labwc's built-in shortcuts, `environment`, the home folders) without asking, never runs anything that
needs root, and then writes `$XDG_STATE_HOME/dkde/setup-done`. While that file
exists `--once` does nothing, so setup never puts back a line the user removed
or a key they moved. A plain `dkde-setup` run is always allowed by hand, ignores
the marker, and also leaves it in place; deleting the file lets the first-login
run repeat.

It also checks the groups that give a user without logind or polkit access
to hardware and services: `audio`, `netdev` (NetworkManager and rfkill),
`plugdev`, `bluetooth` and `lpadmin`, asking only for those that exist on the
system, plus `video` and `input` for the session. The fix is one `usermod -aG`
command that runs only after an explicit yes.

It also creates the standard home folders (Desktop, Documents, Downloads,
Music, Pictures, Videos, Templates, Public) when missing, and writes
`user-dirs.dirs` naming them if the file does not exist. An existing
`user-dirs.dirs` is never changed. The labwc autostart check also adds the line
that restores the saved display layout.

### 5.10 Login (`dkde-greeter`, greetd)

dkde does not write a display manager. The login screen is a greeter for
**greetd**, which works without systemd or logind.

- `dkde-greeter` is a fullscreen GTK window: account picker (uid 1000 and up
  with a real shell), password, Sign in. It speaks the greetd IPC protocol
  (length-prefixed JSON on `$GREETD_SOCK`): `create_session`, answers the
  password prompt, then `start_session` with `dkde-session`, and exits.
  Wrong passwords are cancelled and reported. There are no power buttons, user
  pictures or session choice yet.
- `dkde-greeter-session` (what greetd runs) starts a kiosk labwc that shows
  only the greeter and exits with it. `/etc/greetd/config.toml` is in
  `data/greetd/`; greetd runs the greeter as `_greetd`.
- `dkde-session` is the real session: it sets the environment, makes an
  `XDG_RUNTIME_DIR` when logind did not, reads the user's profile, and starts
  labwc under `dbus-run-session` when that exists (so notifications work).
  `data/dkde.desktop` installs to `share/wayland-sessions`.
- **Seats without logind.** The session and the login screen both reach the
  display and input devices through seatd's socket `/run/seatd.sock`, which
  belongs to a group (`video`): the user and the greetd user (`_greetd`) must be
  in it (`dkde-setup` checks both). seatd lives in `/usr/sbin` on Debian and
  Ubuntu and in `/usr/bin` elsewhere, so the service files run
  `dkde-seatd`, which looks in both. The dinit service tells dinit when the
  socket exists (`ready-notification`, seatd's `-n`), and the greetd service
  depends on it, so the login screen never starts before it.
- **When the session does not start,** labwc's own error would vanish with the
  login screen coming back. `dkde-session` writes its messages to
  `~/.local/state/dkde/session.log` (the last session only) and the login
  screen's to `/tmp/dkde-greeter-<uid>.log`. Each records the user and groups,
  says whether seatd's socket is missing or unusable and how to fix it, and
  ends with labwc's exit status and how long it ran.
- **Init systems:** dkde needs none (SPEC 4.1); the login screen and the
  optional services can be started by any of them. `data/dinit.d/` (dinit),
  `data/systemd/` (systemd) and `data/sysvinit/` (SysV init: Slackware, LFS)
  hold service files, and `data/pam/greetd` an example PAM service. The dinit
  files, for `dkde-console@N` (see 5.11), `greetd`, `seatd`, `dbus`,
  `networkmanager`, `bluetooth` and `cupsd`. Copy those you want to
  `/etc/dinit.d/` and enable them with `dinitctl enable`.

### 5.9 X11 backend (optional, `-Dx11=true`)

For people who run Xorg. Off by default: without the flag nothing X11 is
compiled or linked. With it, `dkde-panel` and `dkde-snip` choose their
backend at start-up from the GDK display (Wayland or X11); every other app is
a plain GTK4 program and already runs on either.

| Part | Wayland | X11 |
|---|---|---|
| Placing the bar and wallpaper | layer-shell | `_NET_WM_WINDOW_TYPE_DOCK` / `DESKTOP`, `_NET_WM_STRUT_PARTIAL` |
| Window list and actions | wlr-foreign-toplevel | EWMH: `_NET_CLIENT_LIST`, `_NET_ACTIVE_WINDOW`, client messages |
| Start menu | full-output overlay | a popup window next to the bar, closed on focus loss |
| Screenshots | wlr-screencopy | `XGetImage` of the root window |

It needs an EWMH-compliant window manager (openbox is the suggested pair) and
no compositor is required. Not supported on X11: auto-hide, and every feature in the list below.

**What does not work on X11** (the apps themselves, being GTK, run under either
backend): global shortcuts and Settings > Keyboard shortcuts (they edit labwc's
`rc.xml`; an X window manager has its own bindings); the virtual-desktop
indicator (`ext-workspace-v1`); desktop notifications (the toasts need
layer-shell); the volume and brightness on-screen display; `dkde-idle` and so
the idle lock, screen-off and sleep (`ext-idle-notify-v1`); the Display page
(`wlr-randr`; there is no `xrandr` equivalent yet); scrolling screenshots
(`wlr-virtual-pointer`); `dkde-pointer`; and the greetd login screen (the X
session is started by `dkde-xsession` or an X display manager). Untested on X11:
desktop icons, the quick-settings flyout and the system tray. Lock detection
looks for Wayland lockers only (`swaylock`, `gtklock`, `waylock`). The X session is
started by `scripts/dkde-xsession`, and `scripts/dkde-startx` runs it from a
console with `startx`.

### 5.7 Context menus

| Where | Items |
|---|---|
| Desktop (wallpaper) | Personalize, Open Terminal, Open Files |
| Taskbar, empty area | Task Manager, Settings |
| Start menu item | Pin/Unpin, Open file location |
| Files, item | Open, Open With, Cut, Copy, Paste, Rename, Move to Trash, Properties |
| Files, empty area | New Folder, Paste, Open Terminal Here |

The taskbar-button and start-menu-item menus also open from the keyboard
(Menu key or Shift+F10).

### 5.11 Console (`dkde-console`)

**Model:** the Linux text console, rebuilt. It replaces `agetty` on a virtual
terminal (VT): it shows a login prompt, runs `login`, and gives the session
the terminal features of `dkde-term`. It draws through KMS/DRM, not through
the kernel's framebuffer console.

**Why it exists.** The kernel console only does what VT100-era terminals
did: 16 colours (or 256 at best), one font of at most 512 glyphs, and no
graphics protocols. On a machine without a working desktop, or before one
starts, that's the only terminal there is. fbterm, the usual way around
this, has been unmaintained for over a decade.

**The rule above all others:** the console must work when everything above
it doesn't. It never needs GTK, GLib, a compositor, a session D-Bus, seatd
or udev. When it can't start, the user still gets a login prompt (see
*Fallback*).

#### Dependencies

A program this low in the system depends on as little as possible. The
console's dependencies are, in full:

- **libghostty-vt**, for terminal emulation
- **libc** (musl or glibc), through Zig's standard library
- **The kernel's user-space API**: DRM/KMS, evdev and VT ioctls, inotify,
  and netlink

Everything else is written in this repository, in Zig: the DRM mode
setting, VT handling, input, keymap, font loading and rendering, the
login loop, and the configuration reader. None of those jobs is large, and
each one is a well-documented kernel interface or file format. Doing them
here means the console can't be broken by a library it doesn't need.

**Static linking.** On musl, `dkde-console` is linked statically, like the
other programs a rescue system can't do without (shells, coreutils, dinit).
It keeps working when the shared libraries on the system are damaged.

**libghostty-vt's own dependencies:** Ghostty's build pulls in simdutf and
highway, which are C++, unless it is built with `simd=false`. The console
passes `.simd = false` to the `ghostty` dependency (`build.zig`, `addConsole`),
so it has no C++ code and no C++ runtime. Its parser takes the scalar path
instead of the SIMD one. `dkde-term` keeps the default build. The rule is to depend on no more than
necessary, not on nothing.

#### Process model

- **One process per VT.** The init system starts `dkde-console --vt N` on
  each VT where `agetty` would otherwise run. dinit, systemd and SysV init
  service files are in `data/` (see 5.10). For dinit it's one templated
  service, `dkde-console@N`.
- **Login.** The console opens a pty, prints `/etc/issue` (with agetty's
  `\n`, `\l`, `\s`, `\r` and `\m` escapes), and starts `login` in it. When
  `login` exits (the user logged out), it clears the screen and starts it
  again. It never runs a shell itself.
- **Privileges.** It runs as root, as a getty does: `login` needs that, and
  it lets the console open the display and input devices itself. It reads
  configuration only from system paths (see *Configuration*), never from a
  user's home directory.

#### VT handling

The console manages its VT directly through the kernel's VT layer. That
layer is also the protocol every other display program uses, so the
console coexists with labwc under seatd, or any other compositor, on
another VT.

- **Taking the VT:** `VT_SETMODE` with `VT_PROCESS`, so the kernel asks
  before switching away; `KDSETMODE KD_GRAPHICS`, so the kernel stops
  drawing text on it; and `KDSKBMODE K_OFF`, so keystrokes reach only the
  console.
- **Switching:** the console handles Ctrl+Alt+F1…F12 itself and calls
  `VT_ACTIVATE`.
- **Release request** (another VT is about to be shown): drop DRM master,
  close the input devices, free the frame buffers, then acknowledge with
  `VT_RELDISP 1`. The console **acknowledges every release request**, even
  in the middle of a redraw. If it doesn't, the kernel refuses the switch
  and the user can't leave the VT.
- **Acquire** (its VT is shown again): acknowledge with
  `VT_RELDISP VT_ACKACQ`, take DRM master, probe the outputs again, reopen
  the input devices, and redraw.
- **Restoring the VT on exit.** On a normal exit and on SIGTERM, SIGINT and
  SIGHUP, the console sets `KD_TEXT`, `K_UNICODE` and `VT_AUTO` again and
  drops DRM master. SIGKILL and crashes can't be caught, so **every start
  first resets the VT to text mode**, and so does the fallback path before
  it `exec`s agetty. agetty doesn't reset the VT mode itself; without this,
  a crash would leave a blank screen even after the fallback.
- Magic SysRq keeps working in every mode, because the kernel handles it
  before the VT layer.

#### Fallback

The console falls back to a plain text login whenever it can't do its job:

- **At start-up:** no DRM device, or no usable display mode. It resets the
  VT to text mode and `exec`s the fallback getty (`[console] fallback`,
  default `/sbin/agetty --noclear tty%N linux`, with `%N` replaced by the VT
  number). Because it `exec`s, the init system still sees the same process.
  A missing font is not a reason to fall back: a default font is built into
  the program (see *Fonts*).
- **After repeated crashes:** each start writes a counter to
  `/run/dkde-console/ttyN.starts` and clears it once the console has run
  for 60 seconds. On the third start within that window, it goes straight
  to the fallback. A console that crashes in a loop must never lock the
  user out.
- **Kernel messages and panics** are not the console's job. They stay with
  the kernel's own console (fbcon), which takes the screen back when the
  console exits. `dmesg` shows them inside a session.

#### Display

- **KMS directly, through the DRM ioctls** (`DRM_IOCTL_MODE_GETRESOURCES`,
  `GETCONNECTOR`, `CREATE_DUMB`, `MAP_DUMB`, `ADDFB2`, `SETCRTC`,
  `PAGE_FLIP`, and `SET_MASTER`/`DROP_MASTER`), with the structures from
  the kernel's `drm.h` and `drm_mode.h`. No libdrm.
- **CPU rendering** into two dumb buffers, swapped with page flips. The
  flip-done events are read from the DRM file descriptor. No GPU API, so
  the console works with any kernel DRM driver, `simpledrm` included.
- **Outputs:** v1 uses the first connected connector in its preferred mode
  and shows nothing on the others. Outputs are probed again on every VT
  acquire. **Post-v1:** mirror to every output, and react to hotplug
  through the kernel's uevent netlink socket.
- **Damage:** per row, as in `dkde-term`. Nothing is redrawn that hasn't
  changed, and an idle console doesn't wake up (see *Low-resource*).

#### Fonts

- **v1: PSF bitmap fonts**, the format of the kernel console's own fonts
  and the kbd package's `consolefonts`. The reader takes PSF2 and PSF1 (the
  older format, 8 pixels wide, 256 or 512 glyphs; the built-in 16-pixel
  Terminus is one). A PSF font is a header, a glyph bitmap array and a
  Unicode table, so the reader is short. Drawing a glyph is copying bits;
  there's no rasterizer. Gzipped fonts (`.psf.gz`) are not read; unpack them
  first.
- **A default font is built in** with `@embedFile`: Terminus at 16, 24 and
  32 pixels. The console therefore always has a font, whatever is on disk.
  Terminus is under the SIL Open Font License, which allows bundling it;
  `third_party/terminus/` holds it with its licence (see 6.5). The files are
  the `Uni3-Terminus` conversions from Debian's console-setup, which cover
  Latin, Greek, Cyrillic and many symbols.
- **Size:** chosen from the output's physical size in its EDID, aiming for
  the same physical size on every screen: the largest built-in size that
  keeps at least 80×24 cells. `[console] font-size` overrides it, and
  `[console] scale` (1 or 2) doubles pixels for very dense screens.
- **Other fonts:** `[console] font` takes the path to a PSF2 file, and
  `[console] fallback-fonts` lists PSF2 files used for characters the main
  font lacks. A character no font has is drawn as a box.
- **TrueType outlines (M9)**, read and rasterized in Zig: `[console] font`
  takes a `.ttf` file as well as a PSF file (the type is told by the file's
  first bytes). The `glyf` outlines come from the same `truetype` module
  `dkde-pdfrender` uses (`src/truetype.zig`). Each glyph is filled with exact-area
  anti-aliasing into an 8-bit coverage bitmap the first time it is drawn and
  kept in a cache of at most 2048 glyphs per face. There is no hinting. The
  cell is `font-size` pixels tall (0 chooses as for PSF), as wide as the
  face's "M", and shrinks until 80 columns fit. Bold smears the glyph one pixel
  to the right, as for PSF. A character the face lacks is looked up in
  `fallback-fonts` (PSF or TrueType, centred in the cell), then drawn as a box.
  Only monospace faces make a grid; `config fonts` and the Settings page list
  the monospace ones. OpenType files with CFF outlines are refused.
- **Later, unscheduled:** colour emoji (colour bitmap tables such as
  `CBDT`) and ligatures (the `GSUB` table). Both would be welcome, but
  neither is needed soon, and each is a sizeable piece of work. They get a
  milestone when they're wanted, written in Zig like the rest. Hinting is not planned.

Wide characters and grapheme clusters follow libghostty-vt's cell model.

#### Input

- **evdev directly:** the console opens `/dev/input/event*` itself and
  reads `struct input_event`s. Each device is classified by its
  capabilities (`EVIOCGBIT`): keyboards, relative pointers (mice), and
  absolute pointers (tablets, and touchpads through their single-touch
  `ABS_X`/`ABS_Y` axes). No libinput, libevdev, mtdev or udev.
- **Hotplug:** inotify on `/dev/input`, so a keyboard plugged in later
  works. `devtmpfs` creates the nodes itself, so this doesn't need udev.
- **Key repeat** comes from the kernel (the `value == 2` repeat events),
  so the console needs no repeat timer.
- **Keymap: the kernel's own.** The console reads the keymap loaded with
  `loadkeys` from the kernel (`KDGKBENT`, `KDGKBSENT`, `KDGKBDIACRUC` for
  dead keys) and translates key codes with it. The console then follows
  the system's console keymap with no keymap setting of its own, and no
  xkbcommon or XKB data. Reading it again is cheap, so it's done on every
  VT acquire, and a `loadkeys` run takes effect at the next switch.
- **Key encoding** to the program goes through libghostty-vt, as in
  `dkde-term`, including the Kitty keyboard protocol.
- **Mouse:** the pointer is drawn only once the mouse moves, and hides
  again on the next key press. Programs that ask for mouse reporting get
  it. Otherwise, dragging selects text.
- **Selection and paste** work within one console: selecting copies, and
  Shift+Insert and the middle button paste. OSC 52 writes go to the same
  buffer. There's no clipboard shared between VTs or with the desktop.

#### Terminal features (v1)

The same libghostty-vt core as `dkde-term` (5.3), and the same features
wherever they make sense without a window:

- 24-bit colour, Kitty keyboard protocol, mouse reporting (SGR mode),
  bracketed paste, synchronized output
- Scrollback (Shift+PageUp/PageDown), with `[console] scrollback-lines`
  (default 2000, lower than `dkde-term` to keep memory small)
- The colour schemes from 5.3 (`[console] colors`, default `campbell`)
- OSC 8 hyperlinks are shown, but there's nothing to open them with
- Not applicable: window titles (OSC 0/2), tabs, focus events, opacity

**Images (kitty graphics protocol)** are the main reason this console
exists beside fbcon, so they're milestone M10. They depend on what
libghostty-vt exposes, the same open point as 5.3. Image data is decoded
with the PNG and raw RGB(A) formats the protocol requires; dkde's vendored
zigimg (3.2) does the PNG decoding, so no system image library is added.
Image memory per console is capped by `[console] image-memory` (default
32 MB), and the oldest images are evicted first.

#### Configuration

The console starts before anyone logs in, so its settings are
system-wide: an exception to 6.1's per-user files.

- **File:** `/etc/dkde/console.conf`. Defaults with a comment for every key
  are in `$PREFIX/share/dkde/console.conf`, and `/etc` holds only what was
  changed, as in 6.1.
- **Format:** the same INI format as every other dkde file, read with an
  INI reader written in Zig, in `termcore` (see *Shared code*), because the
  console must not link GLib. A test reads and writes the same files with
  both this reader and `GKeyFile`, so the two never drift apart.
- **Sections:** `[console]` for everything above. `[vt:N]` overrides keys
  for one VT, for example a larger font on `tty1` only.
- **Changes apply live:** the console watches the file with inotify. Fonts
  and colours change on the next frame. `fallback` takes effect the next
  time the console starts.
- **Missing or invalid values** fall back to the default with a warning,
  never a crash (6.1). An invalid file is not a reason to fall back to
  agetty.

#### Logging

The console writes to standard error, which the init system collects (dinit's
log, the journal, a serial console). Each line has the VT, the time since boot
as in `dmesg`, the level and the part: `dkde-console[tty1] [    12.345] info(drm): ...`.
`[console] log-level` (`error`, `warn`, `info` (default), `debug`) sets how
much, and applies at once. `info` records what was set up (the display and its
mode, the font and the grid, each input device, the login and every restart of
it, a changed configuration file) and every problem, including each setting
that is ignored because its value is invalid and each step that leaves the screen
blank. `debug` adds VT take, release and acquire, keymap reads and font loads.
The fallback to agetty always logs why.

#### Configuration tools

There are two front ends to the same file, so they can never disagree:

- **`dkde-console config`**, a text tool, because the console matters most
  when there's no GUI:
  - `dkde-console config list` shows every key, its value and where it came
    from (default, `/etc`, or `[vt:N]`).
  - `dkde-console config get KEY`
  - `dkde-console config set [--vt N] KEY VALUE` validates the value before
    writing: a font file must exist and load, and a colour scheme must
    exist.
  - `dkde-console config reset [--vt N] KEY` removes the key, so the
    default applies again.
  - `dkde-console config fonts` lists the built-in fonts and the PSF2 files
    found in the usual console-font directories.

  It follows 6.1's static-files rule: setting a value that's already in
  effect writes nothing. It needs root to write and says so plainly when
  run without it.

  The keymap is set with `loadkeys` as on any Linux console, not with this
  tool (see *Input*).
- **A Console page in `dkde-settings`** (5.5): font, size, colour scheme
  and scrollback, with a live preview drawn by the console's own renderer
  code (`src/console/sample.zig`, shared as the `consolefont` module). It
  never writes `/etc` itself. **Apply** asks for the password with the
  elevation dialog the Users page uses and runs `dkde-console config set …`
  for each value, so the console's own validation applies.

#### Shared code

The terminal code `dkde-term` and the console have in common moves into a
new module, **`termcore`**: the pty (`openpty`, `fork`/`exec`,
`TIOCSWINSZ`), the libghostty-vt setup, key-encoding glue, colour schemes,
and the INI reader. `termcore` imports only `std` and libghostty-vt: **no
GTK, GLib or Pango**. `dkde-term` keeps its GTK and Pango code in
`src/term/`.

Move only code that both programs actually use as written. Anything that
would need a flag or a callback to fit both stays where it is, until the
two uses show what the shared form should be.

#### Low-resource operation

dkrescue's budget is under 150 MB in use at the login prompt, with several
consoles running. So:

- **Inactive VTs hold no frame buffers.** Only the console on the visible
  VT has them.
- **Idle footprint:** under 8 MB RSS per console at a login prompt. A
  static binary with no shared libraries helps here.
- **No idle wake-ups:** cursor blink is off by default (`[console]
  cursor-blink`). When it's on, the timer runs only on the active VT.
- Release builds use plain `malloc`, as `common.perf.Gpa` does elsewhere.

#### Build

- `zig build console -Dgui=false` builds only `dkde-console`. It must
  succeed on a system with nothing installed but libc and the kernel
  headers. With `-Dgui=false`, `build.zig` configures only the console and
  `termcore`, and never asks for the GTK-side dependencies in
  `build.zig.zon` (zig-gobject and zig-wayland, which are lazy). Zig has no
  way for `build.zig` to see which step was asked for, so the flag is how
  the console build says it. `zig build console` alone also works where the
  GTK dependencies are present; it only builds less.
- `zig build` still builds everything, the console included.
- `zig build test-console -Dgui=false` runs the console's and `termcore`'s
  tests with no GTK, GLib or other system library in the build graph. If
  either imports one, the build fails. That enforces the dependency list
  above.
- The portability rule in section 1 applies as everywhere else: this links
  for `x86_64-linux-musl` (statically) and glibc.

### 5.12 Polkit agent (`dkde-polkit`, `dkde-polkit-ui`)

**Why it exists.** dkde's own tools run commands through `sudo` with their own
password dialog (5.5), which needs no daemon. Other programs, such as GParted,
NetworkManager, udisks and `pkexec`, ask **polkit**, and when no authentication
agent is running they fail without a word. This is that agent. It is not part of
a minimal system: it matters only where `polkitd` is installed.

**Two programs.** `dkde-polkit` is the agent. It speaks only D-Bus and links GLib
and GIO but not GTK, so while idle it uses about 10 MB (a single GTK program
was 38 MB, and 220 MB with GTK's default renderer). For each request it starts
`dkde-polkit-ui`, a GTK dialog, and answers polkitd with how that went. The two
sit in the same directory and are started in the order: agent first, from the
session.

**What it needs.**
- `polkitd` on the system bus, and a **login session** that logind or elogind
  tracks: polkit sends an agent the requests of its session, found with
  `org.freedesktop.login1.Manager.GetSessionByPID`, else `XDG_SESSION_ID`.
  Without one the agent says so and exits (`--process-subject` registers for the
  one process, which only helps testing with `pkcheck --process`).
- polkit's authentication helper: the socket `/run/polkit/agent-helper.socket`
  when it exists (systemd's socket activation, as on current Ubuntu, where the
  helper is not setuid), else the setuid `polkit-agent-helper-1`.
- Autostart, only where polkit is installed:
  `command -v pkexec >/dev/null 2>&1 && dkde-polkit &`

**Protocol** (polkit 127's sources, and checked against a running polkitd).
The agent exports `org.freedesktop.PolicyKit1.AuthenticationAgent` at
`/org/dkde/PolicyKit1/AuthenticationAgent` on the system bus and calls
`RegisterAuthenticationAgent(subject, locale, path)` (the path is a string,
not an object path). It registers again when polkitd restarts. Only the bus name
that owns polkit's service may call it. `BeginAuthentication` brings the
message, icon, details, a cookie and the identities (users, and groups that the
agent turns into their members); `CancelAuthentication` ends a request.
- The dialog sends the helper the user name and the cookie, one per line, and
  receives lines: `PAM_PROMPT_ECHO_OFF`, `PAM_PROMPT_ECHO_ON`, `PAM_ERROR_MSG`,
  `PAM_TEXT_INFO`, then `SUCCESS` or `FAILURE`. Other lines (the helper's own
  diagnostics) are logged. An answer is the text and one newline. **The helper,
  not the dialog, tells polkitd that authentication worked.**
- The cookie travels to the dialog on its standard input, never in its
  arguments. The password goes from the entry straight to the helper and the
  entry is cleared.
- The dialog shows polkit's message and icon, the program that asked when
  polkit says (pkexec's `command_line`), "Authenticating as <user>" or a choice
  of user, and the helper's own prompts and errors. A wrong password shows
  "Sorry, that didn't work" and asks again with a fresh helper session. If the
  helper never prompts, it gives up after three tries.
- The dialog exits 0 (authenticated), 1 (not), 2 (cancelled). A request
  that polkitd cancels ends the dialog; one that crashes is answered "failed".
  Requests are served one at a time.

**Tested** against polkitd 127 here with `pkcheck --process <agent pid>`:
registration, the dialog with polkit's real message, the helper handshake
through the socket (a live password prompt), cancelling from polkit, a crashed
dialog, and a refused call from another bus name. **Not tested:** a successful
login and a wrong password (they need the user's password), and the registration
through a real logind session, because nothing started from this development
machine belongs to one. Try both on real hardware before relying on it.

## 6. Shared conventions

### 6.1 Configuration

- **Format:** INI-style, read and written with GLib's `GKeyFile`. No
  additional parser dependency.
- **Location:** `$XDG_CONFIG_HOME/dkde/`. One file per component:
  `panel.conf`, `term.conf`, `files.conf`, `hex.conf`. Shared settings like accent
  colour and font live in `dkde.conf`.
- **System defaults:** `$PREFIX/share/dkde/*.conf`. The user's files only
  hold what they changed.
- **State:** recent apps and window sizes go in `$XDG_STATE_HOME/dkde/`,
  never mixed into config.
- **Exception:** `dkde-console` reads `/etc/dkde/console.conf`, because it
  runs before anyone logs in. See 5.11.
- Missing or invalid values fall back to the default and log a warning; they
  never crash a component.
- **Complete defaults:** the system files in `$PREFIX/share/dkde/` list every
  key with its default and a comment. `dkde-setup --write-config` writes them
  (plus a full `[profile:Default]` for the terminal) into `~/.config/dkde/` for
  editing by hand: a missing file becomes a copy, an existing one only gains the
  keys it lacks. It runs only when asked.
- **Static files:** a config file is written only when the user changes a
  setting, and only if that changes its content: setting a value that is
  already in effect writes nothing, and nothing creates or rewrites a config
  file at start-up. Apps that remember something as they run (recent files,
  window sizes) use state files instead. The Settings app additionally holds
  its changes until Apply (see 5.5), through `Config.stage`.

### 6.2 Styling

- One stylesheet, `$PREFIX/share/dkde/style.css`, loaded by every component
  at `GTK_STYLE_PROVIDER_PRIORITY_APPLICATION`.
- User overrides go in `$XDG_CONFIG_HOME/dkde/style.css`, loaded at a higher
  priority.
- Dev override: if `DKDE_DATA_DIR` is set, the system stylesheet and system
  default `*.conf` files are read from that directory instead of
  `$XDG_DATA_DIRS/dkde`. `zig build run-<component>` sets it to `data/`.
- Every app has a classic menu bar (File, Edit, View, ...) under the header,
  built from plain data by `common.menubar`; items show their shortcuts and
  call the same `perform(name)` as keyboard shortcuts. There are no
  hamburger menus. Settings has none: it is a page list, not a document app.
- The header (`common.header`) puts the app icon and title at the left,
  like Windows; windows with their own middle widget (the file manager's
  path bar, the terminal's tabs) show only the icon.
- Window headers are flat with Windows-style caption buttons on the right
  (`gtk-decoration-layout` is set to `:minimize,maximize,close`); the close
  button turns red on hover. All styling is in `style.css`.
- The accent colour and light/dark choice are applied through CSS variables
  defined in that one stylesheet. No component hard-codes a colour.
- The generated appearance variables also redefine GTK's `accent_color` and
  selection names, and `style.css` restates the rules GTK's theme hard-codes in
  blue (suggested-action buttons, switches, check and radio buttons, progress,
  scales, focus rings, menu bar and tab highlights) with `@dkde_accent`. Code
  that draws with cairo gets the accent from `common.style.accentProbe`/
  `accentOf`. The full guide is `docs/theming.md`.
- Default icon theme: **OPEN**, with `hicolor` as the fallback.

### 6.3 Keyboard

Every action reachable by mouse must also be reachable by keyboard. Shared
shortcuts:

| Shortcut | Action |
|---|---|
| Super | Toggle start menu |
| Ctrl+Q | Quit app |
| Ctrl+W | Close tab/window |
| Ctrl+T | New tab (terminal) |
| Ctrl+L | Path entry (files) |
| F2 | Rename (files) |

### 6.4 Code conventions

- `zig fmt` is mandatory, and CI-equivalent checks run it.
- Naming follows the official Zig style guide: `TitleCase` types,
  `camelCase` functions, `snake_case` variables and fields. **OPEN:** confirm
  this, or record a project-specific rule here. Whatever is decided applies
  everywhere, with no exceptions per file.
- Binaries are `dkde-<component>` (kebab-case). GObject subclasses use the
  `Dkde` type-name prefix.
- No global mutable state outside each component's top-level `App` struct.
- Every allocation path has an owner and a matching free. Debug builds use
  `std.heap.DebugAllocator` (or the pinned Zig version's equivalent), and
  leaks are treated as bugs.
- Errors propagate with Zig error unions. They're only shown to the user at
  the UI boundary.
- **Logging.** Every program sets `std_options.logFn = common.log.logFn`.
  `DKDE_LOG=debug|info|warn|error` picks the level (default `warn`),
  `DKDE_LOG_FILE=<path>` also appends to a file and `DKDE_LOG_FILE=auto` uses
  `$XDG_STATE_HOME/dkde/<program>.log` (default `~/.local/state/dkde/`).
  `dkde-session` turns the file on, so a session keeps its warnings and errors.
  Each line is `HH:MM:SS level(scope) program[pid]: message` (UTC). GLib and
  GTK are switched separately with `G_MESSAGES_DEBUG=all`.
- **`dkde-pointer`** is a development aid, not part of the desktop: it moves,
  clicks and scrolls through `wlr-virtual-pointer` and presses keys through
  `zwp_virtual_keyboard_v1` (`dkde-pointer move X Y click sleep MS`, `tap super`,
  `chord ctrl+shift+escape`, with `--size WxH` for the output size), so hover,
  click and shortcut behaviour can be tested in a nested compositor. The
  compositor under test needs dkde's `bin` directory on its own `PATH`, because it
  starts the programs that shortcuts name.

### 6.5 Licence

dkde is MIT-licensed (`LICENSE`). New source files need no header. Do not copy
code from GPL or LGPL projects into the tree; link such libraries dynamically
instead.

Fonts bundled into a binary must be under a licence that allows it (the
SIL Open Font License does), with the licence file next to the font in
`third_party/`.

### 6.6 Documentation

Code is written to be read. A milestone is not done until its code is
documented to this standard.

- Every source file starts with a `//!` module comment: what the file is
  for, which spec section it implements, and how it fits with the files
  around it.
- Every `pub` declaration has a `///` doc comment that says what it does,
  what its parameters mean, who owns returned memory, and which errors it
  can return.
- Comments inside functions explain *why*, not *what*: protocol quirks,
  ordering requirements, workarounds and the upstream issue they work
  around. A comment that restates the code is removed.
- Anything driven by a Wayland protocol, a freedesktop spec or a GTK
  behaviour links to the relevant spec or documentation.
- `docs/ARCHITECTURE.md` describes the components, the shared module, the
  config files and the IPC socket, and is updated in the same change as
  the code it describes.
- `zig build docs` generates Zig autodoc for the `common` module.

### Low-resource operation

dkde targets old, low-memory machines. Measured under WSLg (Mesa llvmpipe), an idle panel went from 228 MB RSS and 31 threads to 53 MB and 14, and a small app from about 270 MB to 43 MB, by:

- **GTK renderer.** `common.perf.init()` runs first in every program and sets `GSK_RENDERER` from `[performance] renderer` in `dkde.conf` (default `cairo`: CPU only, no graphics-driver or GL context; `auto` lets GTK use OpenGL/Vulkan). An explicit `GSK_RENDERER` in the environment wins.
- **malloc.** On glibc only, arenas are capped at 2 (`M_ARENA_MAX`, behind `isGnuLibC()`), since GTK and Mesa start many threads. musl's allocator has no per-thread arenas and no `mallopt`, so nothing is done there.
- **Allocator.** Release builds use plain `malloc` through `common.perf.Gpa`; only Debug builds use `DebugAllocator`.
- **No idle wake-ups.** Timers run only while there is something to update (the clock's 50 ms tick runs only while the stopwatch or timer is running).
- **Release builds.** Plain `zig build` is a Debug build (about 60 times the size). Install with `zig build --release=small` (or `safe`).

## 7. Repository layout

```
build.zig
build.zig.zon
SPEC.md
docs/
  reference/         screenshots: Open-Shell, Nautilus, Windows Terminal
protocols/            vendored wayland protocol XML not in wayland-protocols
data/
  style.css
  *.conf             system defaults
  *.desktop          desktop entries for the apps
  labwc/             example autostart and keybinding snippets
src/
  common/
  panel/
  term/
  files/
  settings/
  termcore/          pty, libghostty-vt setup, key glue, colour schemes, INI reader (no GTK)
  console/           dkde-console: drm, vt, evdev, keymap, psf, render, login, config
third_party/
  terminus/          built-in console font (PSF2) and its licence
data/
  console.conf       console defaults
  dinit.d/dkde-console@
  systemd/dkde-console@.service
  sysvinit/          inittab line for dkde-console
```

**Build steps:**

| Command | Does |
|---|---|
| `zig build` | Builds all four binaries |
| `zig build test` | Runs unit tests |
| `zig build run-<component>` | Builds and runs one component |
| `zig build install --prefix /usr` | Installs binaries and data |
| `zig build console` | Builds only `dkde-console`, with no system libraries |
| `zig build test-console` | Tests `termcore` and the console with no GTK or system libraries in the graph |

## 8. Testing

- **Unit tests** cover all pure logic: desktop entry parsing and filtering,
  search ranking, config read/write and defaults, `app_id` matching, and
  labwc `rc.xml` editing (round-trip without losing other content).
- Unit tests for the PSF2 reader, the kernel-keymap translation (against
  keymap tables captured from `loadkeys`), the INI reader (round-trips
  against `GKeyFile`), and `/etc/issue` escapes.
- The console is tested in QEMU on dkrescue: on `virtio-vga`; on
  `simpledrm` (`-vga std` with no DRM driver); and with no display device
  at all, where it must fall back to agetty.
- **Crash recovery:** `kill -9` on a running console. The next start, or
  the fallback agetty, must show a readable text login.
- **Static check:** on musl, `readelf -l dkde-console` shows no `INTERP`
  header (no dynamic loader needed).
- **Development loop:** labwc runs nested inside an existing Wayland session
  in a window, so the shell can be tested without logging out.
- **Platform check:** each milestone is also verified in a dkrescue QEMU
  image before it's marked done.
- **Manual checklist:** each milestone's acceptance criteria are its manual
  test list.

## 9. Milestones

Each milestone is merged only when all its acceptance criteria pass.

### M0 — Skeleton

- `zig build` produces all four binaries, each opening an empty window.
- zig-gobject and GTK4 linked; `common` loads the stylesheet and config.
- **Done when:** builds on a glibc host and natively inside dkrescue.

### M1 — Panel bar

- Bottom layer-shell bar with exclusive zone, a start button (no menu yet)
  and a clock.
- Height and clock format come from `panel.conf`, and editing the file
  updates the running panel.
- Wallpaper surface.
- **Done when:** maximized windows stop at the top of the bar; config edits
  apply without a restart.

### M2 — Taskbar

- Buttons for all toplevels with icon and title; the active one is
  highlighted.
- Click to activate/minimize, middle click to close, right-click menu.
- **Done when:** opening, closing, retitling and switching windows are all
  reflected correctly, including windows opened before the panel started.

### M3 — Start menu

- Full layout from 5.2: pinned, recent, All Programs, search, places, power.
- IPC socket and `dkde-panel msg toggle-menu`; Super bound in labwc.
- **Done when:** a newly installed `.desktop` file shows up without a
  restart, and type-then-Enter launches the top search result.

### M4 — Terminal

- Tabs, profiles and the full v1 feature list from 5.3.
- **Done when:** `vim`, `htop` and `tmux` run correctly, and kitty keyboard
  protocol mode works in an app that requests it.

### M5 — File manager

- Everything in 5.4.
- **Done when:** copying a large directory shows progress and can be
  cancelled, and Trash works and restores.

### M6 — Settings

- All v1 pages from 5.5.
- **Done when:** every page's changes reach the running component without a
  restart, and labwc files keep their other content.

### M7 — Polish

- A consistent look across all components and a full keyboard-navigation
  pass.
- **Done when:** a dkrescue image boots into a complete dkde session.

### M8 — Console

- 5.11 except TrueType and images: login on DRM, evdev input with the
  kernel keymap, VT switching, fallback, the built-in Terminus font and
  PSF2 files, `console.conf` and `dkde-console config`.
- `termcore` extracted, and `dkde-term` moved onto it with no change in
  behaviour.
- **Done when:** in a dkrescue QEMU image with `dkde-console` on tty1 and
  tty2, `vim`, `htop` and `tmux` run correctly; Ctrl+Alt+F1/F2 switches
  between them and to labwc and back; `kill -9` followed by a restart
  leaves a readable login; with no display device it falls back to
  agetty; `free -m` at the login prompt stays within dkrescue's 150 MB
  budget; and `zig build console` succeeds on a system with only libc.

### M9 — Console fonts and settings page

- TrueType (`glyf`) fonts, rendered in Zig. **Done.**
- The Console page in `dkde-settings`. **Done**; the live change reaches a
  running console through its inotify watch.
- **Done when:** a TrueType monospace font renders cleanly at several
  sizes, and a change made in Settings reaches a running console without
  a restart.

### M10 — Console images

- Kitty graphics protocol, within `image-memory`.
- **Done when:** flow shows its images on the console.

## 10. Working agreement (AI-assisted development)

- One milestone (or part of one) per branch. Every change is reviewed
  before merge.
- No new dependency, protocol, or config key without updating this spec in
  the same change.
- If something in this spec turns out to be wrong or impossible, fix the
  spec first, then the code.
- Unit tests ship with the logic they test.

## 11. Open questions

1. dkde
2. 0.17.0 curl https://www.zvm.app/install.sh | bash
3. zig-gobject: Ghostty's fork.
4. Default icon theme. https://github.com/PapirusDevelopmentTeam/papirus-icon-theme
5. Terminal title bar: imitate the labwc theme, or share a dkde-defined
   look.
6. Naming convention: Zig's official style
7. Minimum labwc version:  0.9.3-1
8. ~~Console: which libghostty-vt build options leave out simdutf and
   highway.~~ Answered: `simd=false` (5.11 *Dependencies*).
9. Console settings page: `sudo` in `dkde-term`, or `sudo -A` with an
   askpass helper.
