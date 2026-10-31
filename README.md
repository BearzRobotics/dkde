# dkde

A small Wayland desktop shell with the layout of classic Windows: taskbar,
Windows 7 style start menu, and a matching set of apps. Written in Zig on
GTK4 (no libadwaita). The compositor is labwc. See `SPEC.md` for the design.

| Binary | What it is |
|---|---|
| `dkde-panel` | Taskbar, start menu, clock, wallpaper |
| `dkde-term` | Terminal (libghostty-vt) |
| `dkde-files` | File manager |
| `dkde-settings` | Settings |
| `dkde-edit` | Text editor |
| `dkde-calc` | Calculator |
| `dkde-view` | Image viewer |
| `dkde-tasks` | Task Manager |
| `dkde-snip` | Screenshots |
| `dkde-setup` | First-run check and fixes |

## Dependencies

### Toolchain

| What | Version | How |
|---|---|---|
| Zig | **0.17.0** exactly | `zvm`: `curl https://www.zvm.app/install.sh \| bash`, then `zvm i 0.17.0` |
| git, curl | any | apt |
| pkg-config | any | apt |

### System libraries (build and run)

Ubuntu 26.04 package names:

```
sudo apt install libgtk-4-dev libgtk4-layer-shell-dev libwayland-dev \
    wayland-protocols pkg-config git curl
```

| Library | Used for |
|---|---|
| GTK 4 (and its chain: GLib, GIO, Pango, Cairo, HarfBuzz, gdk-pixbuf, Graphene) | Every app |
| gtk4-layer-shell | Panel, start menu, wallpaper surfaces |
| wayland-client, wayland-protocols | Taskbar, screenshots |

### Run-time programs and data

```
sudo apt install labwc shared-mime-info papirus-icon-theme
```

| Package | Why |
|---|---|
| labwc (0.9.3 or newer) | The compositor. Must offer `wlr-layer-shell`, `wlr-foreign-toplevel-management` and `wlr-screencopy`; `ext-workspace-v1` (virtual desktops) and `wlr-virtual-pointer` (scrolling screenshots) are used when present |
| shared-mime-info | Content types for the file manager and Open With |
| papirus-icon-theme | Default icons |

### Optional

| Package | Why |
|---|---|
| `webp-pixbuf-loader` | WebP images in the viewer and wallpaper |
| `librsvg2-common` | SVG images in the viewer and wallpaper |
| `wireplumber` (provides the `wpctl` command) | Volume control on PipeWire systems |
| `pulseaudio-utils` (provides `pactl`) | Volume control on PulseAudio, and on WSL |
| `tmux`, `vim`, `htop` | Only to try the terminal with real programs |

Many more optional programs unlock features (network, Bluetooth, printers,
display settings, notifications, login screen); see "Recommended software"
below for the full list and one install command.

### Fetched by `zig build` (pinned by hash in `build.zig.zon`)

| Package | Source |
|---|---|
| zig-gobject (GTK bindings) | `deps.files.ghostty.org`, from ghostty-org/zig-gobject |
| zig-wayland | `deps.files.ghostty.org`, from ifreund/zig-wayland |
| libghostty-vt | Ghostty tag `v1.4.0` (needs Zig 0.17.0) |

Vendored in the repo: `protocols/` holds the protocol XML files that
`wayland-protocols` does not ship or the build must not depend on:
`wlr-foreign-toplevel-management` (taskbar), `wlr-screencopy` (screenshots),
`wlr-virtual-pointer` (scrolling screenshots, `dkde-pointer`) and
`ext-workspace-v1` (virtual desktops).

There is no init-system, systemd, logind, libadwaita or X11 dependency, and no D-Bus
*library* dependency: notifications and the system tray use GIO's own GDBus
when the session has a D-Bus session bus, and are simply off without one.

## Recommended software (everything working)

dkde runs with only the packages in "Run-time programs and data" above, but
several features drive other programs and simply stay hidden or say what is
missing when those are absent. This one command installs everything dkde can
use, on Ubuntu 26.04 (every name below was checked against the Ubuntu package
index):

```
sudo apt install \
    labwc xwayland seatd dbus greetd \
    shared-mime-info papirus-icon-theme webp-pixbuf-loader librsvg2-common \
    fonts-noto-core fonts-noto-color-emoji \
    pipewire pipewire-pulse pipewire-bin wireplumber pulseaudio-utils \
    network-manager bluez rfkill brightnessctl wlr-randr \
    cups cups-client cups-filters \
    gvfs udisks2 chrony sudo passwd \
    tmux vim htop
```

| Feature | Packages | Without them |
|---|---|---|
| Desktop, session | `labwc`, `xwayland` (X11 apps), `seatd` (device access without logind) | no desktop |
| Login screen | `greetd` (then see `data/greetd/`, `data/pam/` and "Init systems" below) | log in on a tty and run `dkde-session` |
| Notifications, system tray | `dbus` (provides `dbus-run-session`, which `dkde-session` uses) | both are off; the panel logs it |
| Sound: volume, devices, test tone | `pipewire`, `pipewire-pulse`, `wireplumber` (`wpctl`), `pipewire-bin` (`pw-play`), or `pulseaudio-utils` (`pactl`, `paplay`) | the Sound page and quick-settings volume say what to install |
| Network | `network-manager` (`nmcli`) | Network page and Wi-Fi tile hidden |
| Bluetooth | `bluez` (`bluetoothctl`) | Bluetooth page and tile hidden |
| Airplane mode | `rfkill` | tile hidden |
| Brightness | `brightnessctl` (otherwise dkde writes the backlight in sysfs, which needs permission) | slider hidden on machines with no backlight |
| Display settings | `wlr-randr` 0.4 or newer | Display page says what to install |
| Printers | `cups`, `cups-client`, `cups-filters` | Printers page says what to install |
| Removable drives | `gvfs`, `udisks2` | no automatic drive list |
| Date and time | `chrony` (clock sync; use `ntpd`, `chronyd` or `systemd-timesyncd`, whichever your system has) | the clock is only as right as you set it |
| Images, icons, fonts | `webp-pixbuf-loader`, `librsvg2-common`, `papirus-icon-theme`, `fonts-noto-*` | missing formats and glyphs |
| Elevated actions, user and group management | `sudo`, `passwd` (provides `useradd`, `usermod`, `userdel`, `chpasswd`, `groupadd`, `groupdel`, `gpasswd`; installed by default on Ubuntu) | the admin-password dialog and the User page cannot work |
| Try the terminal | `tmux`, `vim`, `htop` | none |

## Init systems and other distributions

dkde does not depend on any init system, libc or distribution. It is a set of
ordinary programs plus the `dkde-session` script, and runs the same under
dinit, systemd, SysV init (Slackware, LFS) or no service manager at all
(log in on a tty and run `dkde-session`). The reference platform is musl with
dinit; glibc and systemd work too. Only the optional services below need
starting, and only for the features that use them.

| Init | Service files in this repo | Notes |
|---|---|---|
| dinit | `data/dinit.d/`: `greetd`, `seatd`, `dbus`, `networkmanager`, `bluetooth`, `cupsd` | copy to `/etc/dinit.d/`, then `dinitctl enable <name>` |
| systemd | `data/systemd/greetd.service` | the other services (NetworkManager, bluez, cups, dbus) come with their distribution packages; logind provides seats, so no seatd |
| SysV init | `data/sysvinit/greetd`, `data/sysvinit/seatd` | Slackware: install as `/etc/rc.d/rc.greetd` and `rc.seatd`; LFS/BLFS: `/etc/rc.d/init.d/` and link into your runlevel. Slackware and BLFS already have scripts for dbus, NetworkManager, bluez and cups |
| any | `data/pam/greetd` | greetd needs a PAM service named `greetd`; the file shows the Debian and the `system-auth` (Slackware, LFS) forms |

Which services you need:

- **greetd** and **seatd** (or elogind/systemd-logind): only for a graphical
  login. Without them, run `dkde-session` from a tty.
- **dbus system bus**: NetworkManager and BlueZ need it. dkde's own session
  bus comes from `dbus-run-session`, which `dkde-session` uses when present.
- **NetworkManager, bluetoothd, cupsd**: only for the Network, Bluetooth and
  Printers pages and quick settings.

`dkde-setup` recognises logind and elogind (it looks for `/run/systemd/seats`)
and skips the seat-group check when one is running.

**Packages on other distributions.** The apt command above is Ubuntu-specific
(and the only names I verified). Everywhere else, install the *programs* the
table lists by their command names: `labwc`, `wlr-randr`, `nmcli`,
`bluetoothctl`, `rfkill`, `brightnessctl`, `wpctl` or `pactl` (and `pw-play`
or `paplay`), `lpstat`/`lpadmin`/`lpoptions`/`lp`, `dbus-run-session`,
`sudo`, plus `greetd` and `seatd` for a graphical login. Build-time you need
GTK 4, gtk4-layer-shell, the Wayland client library and Zig 0.17.0.

**musl.** The libc calls dkde makes directly (`openpty`, `__errno_location`,
`program_invocation_short_name`) link and run against musl. A full build and
run on a musl system has not been done by me: check that your GTK 4 and
gtk4-layer-shell build there.

**Groups without logind or polkit.** Without logind (systemd-logind or elogind) or polkit, several
features need your user in a few groups (`audio`, `netdev`, `plugdev`,
`bluetooth`, `lpadmin`, plus `video` and `input` for the session) and the
services above running. `dkde-setup` checks the groups and offers the one
`usermod` command that adds the missing ones (log out and in afterwards).

## Build

```
zig build                 # all binaries into zig-out/bin
zig build test            # unit tests
zig build install --prefix /usr
```

(For everyday use, build with `-Doptimize=ReleaseSafe`; see "Install" below.)

Debug builds still compile libghostty-vt with `ReleaseFast`; in Debug mode it
checks itself on every linefeed and is far too slow.

## Install

This puts dkde on your system for everyday use. (To just look at it without
installing, see "Try it without logging out" below.)

**1. Install the dependencies.** Build-time packages and Zig 0.17.0 from
"Dependencies", and whatever you want from "Recommended software".

**2. Build and install.** Use a release build: the default is a Debug build,
which is much larger and slower (the panel is 23 MB instead of 5 MB). The first
build downloads the Zig dependencies, so it needs a network connection, and
takes a couple of minutes.

```
git clone <this repository> dkde && cd dkde
zig build -Doptimize=ReleaseSafe install --prefix /usr/local     # or --prefix /usr
```

Run it as root, or with `sudo`, if the prefix is a system directory. What is
installed under the prefix:

| Path | What |
|---|---|
| `bin/dkde-*` | The programs: `dkde-panel`, `dkde-term`, `dkde-files`, `dkde-settings`, `dkde-edit`, `dkde-calc`, `dkde-view`, `dkde-tasks`, `dkde-snip`, `dkde-setup`, `dkde-greeter`, and the session scripts `dkde-session`, `dkde-greeter-session`, `dkde-greeter-start`, `dkde-xsession`, `dkde-startx` (`dkde-pointer` is a test tool you can delete) |
| `share/applications/` | Start menu entries for the apps |
| `share/wayland-sessions/dkde.desktop` | The session entry for login managers (GDM, SDDM, greetd's own menu and so on) |
| `share/xsessions/dkde-x11.desktop` | The Xorg session entry (see "Xorg") |
| `share/dkde/` | The stylesheet, default config, example labwc files and the service files for dinit, systemd, SysV init, PAM and greetd |

dkde finds `share/dkde` through `XDG_DATA_DIRS`, whose default includes
`/usr/local/share` and `/usr/share`. With any other prefix, add
`<prefix>/share` to `XDG_DATA_DIRS` (and `<prefix>/bin` to `PATH`).

For a package (Slackware `makepkg`, an LFS package user, or your own),
install into a staging directory instead and archive that:
`zig build -Doptimize=ReleaseSafe install --prefix "$PKG/usr"`.

**3. Run the first-run check as your normal user.**

```
dkde-setup
```

It sets up your labwc autostart and keybindings, creates your Desktop,
Documents and other home folders, and prints the one command (needing root)
that adds you to the groups some features need. Log out and in after any
group change.

**4. Start it.** Any one of these:

- *From a text console*, with no login manager: log in and run
  `dkde-session`. It makes `XDG_RUNTIME_DIR` if your system does not, starts a
  session D-Bus when it can, and runs labwc, which starts the panel.
- *With greetd and the dkde login screen:* install `greetd` and `seatd` (or
  use elogind/systemd), copy `share/dkde/greetd/config.toml` to
  `/etc/greetd/config.toml` and `share/dkde/pam/greetd` to
  `/etc/pam.d/greetd`, then enable the greetd service for your init system
  (files in `share/dkde/`; see "Init systems"). Reboot or start the service.
- *With a login manager you already use* (GDM, SDDM, LightDM and so on):
  choose the "dkde" session on its login screen. The entry is installed by
  step 2; some login managers need a restart to notice it.

**5. Settings.** Open Settings (start menu, or `dkde-settings`) for the
look, taskbar, terminal profiles, display, network and the rest.

**Updating** is the same as installing: pull, then run the `zig build ...
install` command again and log out and in. Your settings live in
`~/.config/dkde/` and are not touched.

**Uninstalling.** Zig has no uninstall command. Delete the files listed in the
table above from your prefix (or, if you installed from a staging directory,
the files that package contains), and optionally `~/.config/dkde/`,
`~/.local/state/dkde/` and `~/.cache/dkde/`.

**Status.** I have only tested the staging step (the file list above comes from
a real `zig build install`) and running programs from the build tree in a
nested labwc. Installing under `/usr`, the login screen, and every service file
are untested on a real system, so expect to adjust paths.

## Try it without logging out

```
scripts/dev-session.sh
```

This starts labwc in a window of your current Wayland session, running the
panel. Click inside it, then use the Start button (or the Super key).

### WSL2 (WSLg) note

labwc is built with Xwayland support and, at startup, insists that
`/tmp/.X11-unix` has the sticky bit. dkde does not use X11, but on WSLg the
directory lacks the bit and labwc exits. The script works around this with a
private mount namespace, **which makes `sudo` fail inside the nested session**
(setuid programs cannot work in it).

To avoid the workaround, run this **once in a normal WSL terminal, not inside
the nested session**, and start the script again:

```
sudo chmod +t /tmp/.X11-unix
```

WSLg recreates the directory when WSL restarts, so repeat it after a restart.
On a regular Wayland-only system none of this applies.

## Handy options

- `dkde-settings --page <id>` opens Settings on a page: `appearance`,
  `taskbar`, `startmenu`, `terminal`, `keyboard`, `audio`, `mouse`,
  `defaults` or `users`.
- **Logs.** Every program logs warnings and errors to stderr. Set
  `DKDE_LOG=debug` (or `info`, `warn`, `error`) to choose how much, and
  `DKDE_LOG_FILE=auto` to also write `~/.local/state/dkde/<program>.log`
  (`dkde-session` does that by default; times are UTC). For GTK's own
  messages use `G_MESSAGES_DEBUG=all`. Example:
  `DKDE_LOG=debug dkde-panel 2>&1 | less`.
- `dkde-pointer move 640 719 sleep 500 click` drives the pointer through
  `wlr-virtual-pointer`; it is a test aid for nested compositors.
- Administrator actions (Settings > User, start menu > right-click an app >
  Run as administrator, Files > Open Folder as Administrator) ask for your
  password in a dkde dialog and run through `sudo`, so your account must be
  allowed to use sudo. There is no polkit agent in a dkde session.

## First-run check: `dkde-setup`

```
dkde-setup --check     # only report (exit status 1 if something is missing)
dkde-setup             # report, then offer fixes
dkde-setup --yes       # apply the user-level fixes without asking
```

It checks the labwc `autostart`, keybindings and `environment`, that the
dkde programs and desktop entries are installed, the icon theme, and (when
relevant) the WSL `/tmp/.X11-unix` permission, seat groups on systems
without logind, the device and service groups (`audio`, `netdev`,
`plugdev`, `bluetooth`, `lpadmin`; only those that exist on your system), and
a login-manager session entry. It also creates the standard home folders
(Desktop, Documents, Downloads, Music, Pictures, Videos, Templates, Public)
and `user-dirs.dirs` when they are missing.

User-level fixes only touch files in your own config directory: existing
labwc files are added to, never replaced, and backed up once. Anything that
needs root is shown with the exact command and the reason, and runs only if
you answer `y`.

## Xorg (optional)

dkde is Wayland-first; the default build has no X11 code. To run it on Xorg:

```
sudo apt install libx11-dev openbox xinit    # build and run extras
zig build -Dx11=true
scripts/dkde-startx            # from a text console
```

`scripts/dkde-startx` runs `startx` with `scripts/dkde-xsession`, which starts
a window manager (`openbox`, or whatever `DKDE_WM` names; any EWMH-compliant
one works) and then the panel. `DKDE_COMPOSITOR=picom` adds an optional
compositor, needed only for shadows and a see-through terminal. For a
graphical login screen, `dkde-setup` can install
`/usr/share/xsessions/dkde-x11.desktop`.

On X11 the panel and the screenshot tool use X instead of Wayland; every
other app is plain GTK4 and runs on either. Auto-hide is Wayland-only.
Status: the panel's window list and start menu were tried under labwc's
Xwayland; placing the bar relies on the window manager honouring dock hints
(Openbox and similar do), and that has not been tried on a real Xorg session.

## Using it for real

Example labwc files are in `data/labwc/`: an `autostart` that restarts the
panel and keybindings for Super (start menu), Print / Shift+Print
(screenshots), Ctrl+Shift+Esc (Task Manager) and virtual desktops
(Ctrl+Alt+Left/Right to switch, add Shift to carry the window along). The
number of desktops is under Settings > Taskbar.

For a graphical login, install `greetd` and copy `data/greetd/config.toml` to
`/etc/greetd/`; `dkde-greeter` is the login screen and `dkde-session` the
session it starts. Run the panel under a session D-Bus (`dkde-session` does
this when `dbus-run-session` is installed) to get notifications and the
system tray.

## License

dkde is released under the [MIT License](LICENSE). Copyright (c) 2026 Dakota
James Owen Keeler.

Things dkde builds on keep their own licenses: GTK 4 and gtk4-layer-shell are
dynamically linked system libraries (LGPL); libghostty-vt (Ghostty) and
zig-wayland, fetched by `zig build`, are MIT, as I read their license files;
the zig-gobject package I fetched ships no license file, so check its
upstream before redistributing binaries; and the protocol XML files in
`protocols/` keep their own copyright and permission notices. The Papirus icon
theme is a separate package and is not bundled.

