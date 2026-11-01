#!/bin/sh
# Makes the release source tarball: the committed source plus the Zig
# dependencies (zig-pkg/), so it builds with no network.
#
#   scripts/make-source-tarball.sh [version]      -> dist/dkde-v<version>.tar.gz
#
# The version defaults to the one in build.zig.zon. Run it from a clean
# checkout of the commit being released.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

version=${1:-$(sed -n 's/.*\.version = "\(.*\)".*/\1/p' build.zig.zon | head -n 1)}
name="dkde-v$version"
out="$root/dist"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "make-source-tarball: the working tree has uncommitted changes; they would not be in the tarball." >&2
    exit 1
fi

# Fetch the dependencies into zig-pkg/ if they are not there yet.
if [ ! -d zig-pkg ] || [ -z "$(ls zig-pkg 2>/dev/null)" ]; then
    echo "fetching the Zig dependencies..."
    zig build --fetch
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$out"

git archive --format=tar --prefix="$name/" HEAD | tar -x -C "$stage"
cp -a zig-pkg "$stage/$name/zig-pkg"

# Reproducible-ish: fixed owner and sorted names.
tar --owner=0 --group=0 --numeric-owner --sort=name -C "$stage" -c "$name" | gzip -9n > "$out/$name.tar.gz"
(cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")

echo "wrote $out/$name.tar.gz"
cat "$out/$name.tar.gz.sha256"
