#!/bin/sh
# Build and install dkde from the release tarball (or a checkout), for a
# package or an image. Works offline: it uses the Zig dependencies in
# ./zig-pkg, which the release tarball carries.
#
#   packaging/build.sh                         # build only
#   DESTDIR=/tmp/pkg packaging/build.sh install
#
# Settings (environment variables):
#   PREFIX     install prefix                      (default /usr)
#   DESTDIR    staging root for packaging          (default empty)
#   ZIG        the Zig 0.17.0 compiler             (default zig)
#   MODE       safe | small | fast                 (default safe)
#   CPU        Zig CPU target. "baseline" runs on any x86-64 and is right for
#              an image that must boot on old machines. "native" tunes for the
#              build machine and may not run elsewhere.        (default baseline)
#   TARGET     Zig target triple, only for cross builds, e.g. x86_64-linux-musl
#   FLAGS      extra zig build options, e.g. "-Dx11=true" or "-Dpdf=true"
#   PAM_FORM   system (Slackware, LFS, dkrescue-style system-auth) | debian   (default system)
#   INIT       dinit | systemd | sysvinit | none   which service files to install (default dinit)
#   GREETD_USER  the account greetd runs the greeter as           (default _greetd)
#
# See packaging/PACKAGING.md for the dependencies and what is installed.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
cd "$src"

PREFIX=${PREFIX:-/usr}
DESTDIR=${DESTDIR:-}
ZIG=${ZIG:-zig}
MODE=${MODE:-safe}
CPU=${CPU:-baseline}
TARGET=${TARGET:-}
FLAGS=${FLAGS:-}
PAM_FORM=${PAM_FORM:-system}
INIT=${INIT:-dinit}
GREETD_USER=${GREETD_USER:-_greetd}

# zig build install adds DESTDIR itself, so it must be in the environment.
export DESTDIR

say() { printf 'dkde: %s\n' "$*"; }
die() { printf 'dkde: %s\n' "$*" >&2; exit 1; }

check() {
    command -v "$ZIG" >/dev/null 2>&1 || die "Zig not found (set ZIG=/path/to/zig); dkde needs Zig 0.17.0 exactly."
    v=$("$ZIG" version)
    [ "$v" = "0.17.0" ] || die "Zig $v found, but dkde needs exactly 0.17.0."
    command -v pkg-config >/dev/null 2>&1 || die "pkg-config is required."
    missing=""
    for m in gtk4 gtk4-layer-shell-0 wayland-client; do
        pkg-config --exists "$m" 2>/dev/null || missing="$missing $m"
    done
    [ -z "$missing" ] || die "missing development files for:$missing (see packaging/PACKAGING.md)"
    [ -d zig-pkg ] || die "no zig-pkg/ directory: use the release tarball, or run 'zig build --fetch' once with a network."
}

build() {
    check
    say "building (mode $MODE, cpu $CPU${TARGET:+, target $TARGET})"
    # --system: never touch the network, read dependencies from zig-pkg/.
    # shellcheck disable=SC2086
    "$ZIG" build --release="$MODE" -Dcpu="$CPU" ${TARGET:+-Dtarget="$TARGET"} \
        --system zig-pkg --prefix "$PREFIX" $FLAGS install
}

install_extras() {
    say "installing session files into ${DESTDIR:-/}"
    etc="$DESTDIR/etc"
    # greetd: the greeter session, and the PAM service it logs in through.
    install -d "$etc/greetd" "$etc/pam.d"
    sed "s|_greetd|$GREETD_USER|" data/greetd/config.toml > "$etc/greetd/config.toml"
    if [ "$PAM_FORM" = debian ]; then
        cat > "$etc/pam.d/greetd" <<'PAM'
auth     include  common-auth
account  include  common-account
password include  common-password
session  include  common-session
PAM
    else
        cat > "$etc/pam.d/greetd" <<'PAM'
auth       include    system-auth
account    include    system-account
password   include    system-password
session    include    system-session
PAM
    fi
    case "$INIT" in
    dinit)
        install -d "$etc/dinit.d"
        for f in data/dinit.d/*; do install -m 644 "$f" "$etc/dinit.d/$(basename "$f")"; done
        ;;
    systemd)
        install -D -m 644 data/systemd/greetd.service "$DESTDIR/usr/lib/systemd/system/greetd.service"
        ;;
    sysvinit)
        install -D -m 755 data/sysvinit/greetd "$etc/rc.d/rc.greetd"
        install -D -m 755 data/sysvinit/seatd "$etc/rc.d/rc.seatd"
        ;;
    none) ;;
    *) die "unknown INIT=$INIT" ;;
    esac
    # The user config template is written by dkde-setup on first login, not here.
}

case "${1:-build}" in
check) check ;;
build) build ;;
install) build; install_extras ;;
*) die "usage: $0 [check|build|install]" ;;
esac
say "done"
