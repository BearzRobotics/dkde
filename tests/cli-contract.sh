#!/bin/sh
# DKDE-024: every installed program answers --help and --version with exit 0,
# and rejects an unknown option with exit 2, without a display or session bus.
#
#   tests/cli-contract.sh [BINDIR]      (default: zig-out/bin)
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bindir=${1:-$root/zig-out/bin}
status=0

for prog in "$bindir"/dkde-*; do
    name=$(basename "$prog")
    # No display, no bus; stdin closed so nothing waits for input.
    run() { env -u DISPLAY -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS timeout 10 "$prog" "$@" </dev/null; }

    out=$(run --version 2>/dev/null); rc=$?
    case $out in
        "$name "*) [ $rc -eq 0 ] || { echo "FAIL $name --version: exit $rc" >&2; status=1; } ;;
        *) echo "FAIL $name --version: unexpected output '$out'" >&2; status=1 ;;
    esac

    run --help >/dev/null 2>&1 || { echo "FAIL $name --help: nonzero exit" >&2; status=1; }

    # dkde-seatd forwards its options to seatd, so it cannot judge them.
    [ "$name" = dkde-seatd ] && continue
    run --no-such-option >/dev/null 2>&1; rc=$?
    [ $rc -eq 2 ] || { echo "FAIL $name --no-such-option: exit $rc, expected 2" >&2; status=1; }
done
[ $status -eq 0 ] && echo "ok   all programs in $bindir follow the command-line contract"
exit $status
