#!/bin/sh
# DKDE-014: build and install selected apps from a clean cache into a clean
# prefix, and check that only that app's files were installed.
#
#   tests/build-isolation.sh [app ...]     (default: calc calendar)
#
# Needs the same toolchain and network/package cache as a normal build.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
[ "$#" -gt 0 ] || set -- calc calendar
status=0

for app in "$@"; do
    prefix="$work/prefix-$app"
    cache="$work/cache-$app"
    # A private local cache; the global cache keeps downloaded packages.
    if ! (cd "$root" && zig build -Dapp="$app" --prefix "$prefix" --cache-dir "$cache"); then
        echo "FAIL $app: build failed" >&2
        status=1
        continue
    fi
    bins=$(ls "$prefix/bin" 2>/dev/null | tr '\n' ' ')
    if [ "$bins" != "dkde-$app " ]; then
        echo "FAIL $app: expected only bin/dkde-$app, found: $bins" >&2
        status=1
        continue
    fi
    other=$(find "$prefix/share/applications" -type f 2>/dev/null | grep -v "/dkde-$app.desktop\$" || true)
    if [ -n "$other" ]; then
        echo "FAIL $app: unrelated desktop entries installed: $other" >&2
        status=1
        continue
    fi
    echo "ok   $app: $(cd "$prefix" && find . -type f | sort | tr '\n' ' ')"
done
exit $status
