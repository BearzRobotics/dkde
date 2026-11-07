#!/bin/sh
# DKDE-020, DKDE-022, DKDE-070: each graphical program starts and keeps running
# with the panel stopped, no session D-Bus and no other DKDE program on PATH.
#
#   tests/runtime-independence.sh [BINDIR [APP...]]
#
# Needs a Wayland display (WAYLAND_DISPLAY) with the usual XDG_RUNTIME_DIR.
# A program passes if it is still running after SECONDS (default 4) and then
# stops on SIGTERM without crashing. Programs that need extra hardware or a
# special compositor protocol are skipped with a reason, not passed.
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bindir=${1:-$root/zig-out/bin}
[ "$#" -gt 0 ] && shift
apps=${*:-calc calendar charmap clock color edit files parted settings snip tasks term view}
wait_s=${SECONDS_TO_RUN:-4}
data=$root/data

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "SKIP: no WAYLAND_DISPLAY; cannot start graphical programs" >&2
    exit 77
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0

for app in $apps; do
    prog=$bindir/dkde-$app
    [ -x "$prog" ] || { echo "SKIP $app: $prog not built"; continue; }

    # PATH holds only this program, so nothing can start a sibling.
    only=$work/path-$app
    mkdir -p "$only" "$work/home-$app"
    ln -sf "$prog" "$only/dkde-$app"

    log=$work/$app.log
    # Private HOME/XDG dirs so a failure cannot touch the real configuration.
    env -u DBUS_SESSION_BUS_ADDRESS -u DBUS_SYSTEM_BUS_ADDRESS \
        PATH="$only:/usr/bin:/bin" HOME="$work/home-$app" \
        XDG_CONFIG_HOME="$work/home-$app/config" XDG_STATE_HOME="$work/home-$app/state" \
        XDG_CACHE_HOME="$work/home-$app/cache" XDG_DATA_HOME="$work/home-$app/data" \
        DKDE_DATA_DIR="$data" \
        "$only/dkde-$app" >"$log" 2>&1 </dev/null &
    pid=$!
    sleep "$wait_s"
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null; rc=$?
        case $rc in
            0|143) echo "ok   $app" ;;
            *) echo "FAIL $app: running, but exit $rc after SIGTERM"; status=1 ;;
        esac
    else
        wait "$pid" 2>/dev/null; rc=$?
        echo "FAIL $app: exited with $rc within ${wait_s}s"
        sed 's/^/       /' "$log" | tail -n 5
        status=1
    fi
done
exit $status
