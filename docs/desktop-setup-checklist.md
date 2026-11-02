# Desktop setup checklist

What a system needs around dkde to feel like a complete desktop. dkde itself
runs without any of the "Add" items, but several things people expect (a lock
screen, USB sticks mounting, a browser's file chooser) come from other
programs, and nothing in dkde provides them.

Package names are Debian's; other distributions use similar names. **Nothing
here has been tested on an ISO yet.** Items are marked *verify* where a flag or
file name is from documentation and has not been tried. The current ISO does not
ship these items; this is the list for the next one.

dkde's rule applies to every choice below: **no systemd, no logind, a session
D-Bus only because `dkde-session` starts one** (SPEC.md 2 and 5.10). Prefer a
program that needs neither a system service nor logind.

## 1. Already assumed by dkde

These are listed in SPEC.md. Their absence is reported by `dkde-setup --check`
or by the page that needs them.

| Need | Packages |
|---|---|
| Compositor, session, login | `labwc`, `greetd`, `seatd`, `dbus` |
| Display page, screen off | `wlr-randr` |
| Network, Bluetooth, printers | `network-manager`, `bluez`, `cups` |
| Sound | `pipewire`, `wireplumber` (`wpctl`), `pipewire-pulse` |
| Brightness | `brightnessctl` (or sysfs access) |
| Icons and fonts | `papirus-icon-theme`, `fonts-dejavu` or `fonts-noto` |

## 2. Add: things that would otherwise be missing

| Gap | What to add | Notes |
|---|---|---|
| **Lock screen** | `swaylock` (or `gtklock`) | dkde has no lock screen of its own (SPEC.md 5.1). Without one, Lock does nothing. `swaylock` installs its own PAM file. |
| **USB sticks and cards mounting** | `udevil` (its `devmon`), `eudev` or another udev | Mounts without polkit or D-Bus. **udevil must be installed setuid root** (Debian asks at install; without it devmon needs udisks or pmount), and `udevd` must be running because devmon watches devices through libudev. Needs bash 4 or newer. Autostart: `devmon --no-gui &`, or with notifications as in section 6. Events can run a command: `--exec-on-drive`, `--exec-on-unmount`, `--exec-on-remove`, with `%d` (mount point), `%f` (device) and `%l` (label), per its man page. *Verify* by running it: not tried yet. udisks2 is the alternative, but it needs polkit (see section 4). |
| **Power button and laptop lid** | `acpid` | With no logind, nothing acts on the lid or the power button. `acpid` runs a script; one that calls `loginctl`-free commands (`poweroff`, or a suspend command) is enough. *Verify* on a laptop. |
| **Clock** | `chrony` (or `ntpsec`, or `busybox ntpd`) | Without systemd-timesyncd nothing keeps the time right. |
| **Night light** | `wlsunset` | Starts from the autostart with the user's coordinates. No dkde setting for it yet. |
| **Out-of-memory** | `earlyoom` | For old machines: kills the biggest program before the system freezes. |

## 3. Add if the system runs a browser, Flatpak or screen sharing

| Gap | What to add | Notes |
|---|---|---|
| **Desktop portals** | `xdg-desktop-portal`, `xdg-desktop-portal-wlr`, `xdg-desktop-portal-gtk` | Needed for screen sharing in a browser, and for any sandboxed app's file chooser. A plain Firefox or Chromium uses GTK's own file chooser and does not need them. |
| Portal choice | `~/.config/xdg-desktop-portal/dkde-portals.conf` (named after `XDG_CURRENT_DESKTOP`, which `dkde-session` sets to `dkde`): `[preferred]`, `default=gtk`, `org.freedesktop.impl.portal.ScreenCast=wlr`, `org.freedesktop.impl.portal.Screenshot=wlr` | *Verify.* |
| Portal environment | In the labwc autostart, before anything else: `dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP` | Portals are started by D-Bus; they need to see the session's variables. *Verify* with `dbus-run-session`. |
| **Saved passwords** | `gnome-keyring`; autostart `gnome-keyring-daemon --start --components=secrets` | Browsers and NetworkManager use it for passwords. Without it, they ask every time (or store them in plain text). Unlocking it at login needs a PAM line in greetd's PAM file; *verify*. |

## 4. Authentication agent

**dkde's own tools do not use polkit.** `common.elevate` keeps running commands
through `sudo -S -k` with its own password dialog (SPEC.md 5.5). That needs no
daemon, no policy files and no login-session tracking.

**Other programs that call polkit** (GParted, NetworkManager asking to change a
system connection, udisks2, `pkexec`) fail quietly when no agent is running.
For those, dkde ships **`dkde-polkit`** (SPEC.md 5.12): a small agent that only
speaks D-Bus (about 10 MB idle) and starts `dkde-polkit-ui` for the dialog.

What it needs on the ISO, and only if the ISO ships programs that use polkit:

- `polkitd` (Debian: `polkitd`, plus `pkexec` if wanted), on the system bus.
- **A login session tracked by logind or elogind.** polkit sends an agent the
  requests of its session. This is the real cost of polkit on a system without
  systemd: `elogind` (or systemd). The agent exits with a clear message when it
  finds no session. *Verify* on the ISO that it registers.
- polkit's helper: nothing extra; it is part of `polkitd`. Current Ubuntu uses
  a socket-activated helper (`/run/polkit/agent-helper.socket`); older and
  other systems use the setuid `polkit-agent-helper-1`. The dialog tries the
  socket first and the setuid helper second.
- Autostart: `command -v pkexec >/dev/null 2>&1 && dkde-polkit &`

For a small ISO with no polkit programs, leave all of this out: dkde has its own
partition tool (`dkde-parted`), Network page and automounter, so nothing there
needs it.

**Tested on a development machine with polkitd 127:** registration, the dialog,
the helper handshake, cancel and crash handling. **Not tested:** signing in with
a real password, a wrong password, and registering through a real logind session.

## 5. Not provided, and not a package

Work in dkde itself, in the order that matters most:

1. ~~About page~~ and ~~Language & region page~~: done. Language & region writes
   `~/.config/locale.conf` for the user and needs generated UTF-8 locales on the
   system (`locale -a`); the ISO must ship some besides `C.UTF-8`.
3. ~~Low battery warning~~: done (SPEC.md 5.1). Warns, then sleeps or powers off
   after a grace period. Not tried on a real laptop.
4. ~~A notification when a disk is mounted or removed~~: `dkde-notify` exists
   and works (tested against the panel's notification server), including
   `--mounted`, `--unmounted` and `--removed`, which show the label and mount
   point. The devmon hook lines in section 6 are **not tried** with devmon itself,
   and the label lookup has been seen only in unit tests (the test machine's
   disk has no label).
5. **Do Not Disturb** for the notification toasts.
6. **Input methods** (Chinese, Japanese, Korean typing): not wired up
   (SPEC.md 5.3). Needs `fcitx5` and the Wayland text-input protocol.
7. **Accessibility:** the session sets `NO_AT_BRIDGE=1`, so screen readers
   cannot see dkde apps.

## 6. Autostart, in one place

What `~/.config/labwc/autostart` would hold with everything above, in order
(the first two are already in `data/labwc/autostart`):

```sh
dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
(while true; do dkde-panel; sleep 1; done) &
dkde-idle &
command -v pkexec >/dev/null 2>&1 && dkde-polkit &
devmon --no-gui \
    --exec-on-drive 'dkde-notify --mounted %f' \
    --exec-on-unmount 'dkde-notify --unmounted %f' \
    --exec-on-remove 'dkde-notify --removed %f' &
gnome-keyring-daemon --start --components=secrets &
wlsunset -l LATITUDE -L LONGITUDE &
```

Only `%f` (the device, such as `/dev/sdd1`) is passed to the hook. devmon also
offers `%l` (the volume label) and `%d` (the mount point), but it puts them
through `eval`, and a label is text whoever made the stick chose. `dkde-notify
--mounted DEVICE` looks the label and mount point up itself (from
`/dev/disk/by-label` and `/proc/self/mounts`) and only ever shows them.

And as system services (dinit files for these do not exist yet; `data/dinit.d/`
has the ones that do): `dbus`, `seatd`, `greetd`, `networkmanager`, `bluetooth`,
`cupsd`, `acpid`, `chrony`, `earlyoom`.
