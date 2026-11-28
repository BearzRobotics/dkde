#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Starts a compositor nested in a window of your current Wayland session,
# running dkde-panel, so the shell can be tried without logging out (SPEC.md 8).
# It runs dkde-compositor when that is built or installed,
# and otherwise the backup, labwc. DKDE_DEV_LABWC=1 chooses labwc.
# Usage: scripts/dev-session.sh   (after `zig build`)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Desktop entries so the pinned apps resolve without installing.
mkdir -p "$work/data/applications"
cp "$root"/data/*.desktop "$work/data/applications/"

# DKDE_BIN_DIR tries another build (a release one, say) in the nested session.
export PATH="${DKDE_BIN_DIR:-$root/zig-out/bin}:$PATH"
export XDG_DATA_HOME="$work/data"
export XDG_STATE_HOME="$work/state"
export DKDE_DATA_DIR="$root/data"
export GDK_BACKEND=wayland
export NO_AT_BRIDGE=1
export WLR_BACKENDS=wayland

compositor="$root/zig-out/bin/dkde-compositor"
[ -x "$compositor" ] || compositor=$(command -v dkde-compositor || true)
if [ -n "$compositor" ] && [ "${DKDE_DEV_LABWC:-}" != 1 ]; then
    # Only the panel: the usual session programs include the idle watcher, which would lock.
    # Its settings are a throwaway copy of nothing, so yours are not touched.
    mkdir -p "$work/config/dkde"
    printf 'dkde-panel\n' > "$work/config/dkde/autostart"
    export XDG_CONFIG_HOME="$work/config"
    "$compositor"
    exit
fi

# WSLg's /tmp/.X11-unix has no sticky bit, which makes labwc's Xwayland setup
# fatal. A private mount namespace gives labwc its own directory there.
if [ -z "${DKDE_IN_NS:-}" ] && [ ! -k /tmp/.X11-unix ] && [ -d /tmp/.X11-unix ]; then
    cat >&2 <<'NOTE'
note: /tmp/.X11-unix has no sticky bit, which makes labwc exit (it prepares for
Xwayland, which dkde does not use). Using a private mount namespace instead.
sudo will NOT work inside this session. To avoid that, run once in a normal
terminal (not in this session):  sudo chmod +t /tmp/.X11-unix
NOTE
    exec env DKDE_IN_NS=1 unshare -Urm "$0" "$@"
fi
if [ -n "${DKDE_IN_NS:-}" ]; then
    mount -t tmpfs -o mode=1777 tmpfs /tmp/.X11-unix
fi

# A throwaway labwc config: default bindings plus the Super key for the menu.
mkdir -p "$work/labwc"
cat > "$work/labwc/rc.xml" <<XML
<?xml version="1.0"?>
<labwc_config>
  <keyboard>
    <default />
    <keybind key="Super_L" onRelease="yes">
      <action name="Execute" command="dkde-panel msg toggle-menu"/>
    </keybind>
  </keyboard>
</labwc_config>
XML
printf 'dkde-panel\n' > "$work/labwc/autostart"

export WLR_RENDERER=pixman

labwc -C "$work/labwc"
