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
#   ZIG        the Zig 0.17.1 compiler             (default zig)
#   MODE       safe | small | fast                 (default safe)
#   CPU        Zig CPU target. "baseline" runs on any x86-64 and is right for
#              an image that must boot on old machines. "native" tunes for the
#              build machine and may not run elsewhere.        (default baseline)
#   TARGET     Zig target triple, only for cross builds, e.g. x86_64-linux-musl
#   FLAGS      extra zig build options, e.g. "-Doptimize=ReleaseSafe"
#   PAM_FORM   system (Slackware, LFS, dkrescue-style system-auth) | debian   (default system)
#   INIT       dinit | systemd | sysvinit | none   which service files to install (default dinit)
#   GREETD_USER  the account greetd runs the greeter as           (default _greetd)
#   COMPOSITOR yes | no   build and install dkde-compositor (wlroots)   (default yes)
#   WM         yes | no   build and install dkde-wm (X11, XCB)          (default yes)
#   WLROOTS    wlroots version for the compositor: 0.19 or 0.20  (default: whichever pkg-config finds)
#   XCB_RANDR_PREFIX  folder with include/ and lib/ of libxcb-randr, if not system-wide
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
COMPOSITOR=${COMPOSITOR:-yes}
WM=${WM:-yes}
WLROOTS=${WLROOTS:-}
XCB_RANDR_PREFIX=${XCB_RANDR_PREFIX:-}

# zig build install adds DESTDIR itself, so it must be in the environment.
export DESTDIR

say() { printf 'dkde: %s\n' "$*"; }
die() { printf 'dkde: %s\n' "$*" >&2; exit 1; }

check() {
    command -v "$ZIG" >/dev/null 2>&1 || die "Zig not found (set ZIG=/path/to/zig); dkde needs Zig 0.17.1 exactly."
    v=$("$ZIG" version)
    [ "$v" = "0.17.1" ] || die "Zig $v found, but dkde needs exactly 0.17.1."
    command -v pkg-config >/dev/null 2>&1 || die "pkg-config is required."
    missing=""
    for m in gtk4 gtk4-layer-shell-0 wayland-client libarchive; do
        pkg-config --exists "$m" 2>/dev/null || missing="$missing $m"
    done
    [ -z "$missing" ] || die "missing development files for:$missing (see packaging/PACKAGING.md)"
    if [ "$COMPOSITOR" = yes ]; then
        if [ -z "$WLROOTS" ]; then
            for v in 0.19 0.20; do pkg-config --exists "wlroots-$v" 2>/dev/null && WLROOTS=$v; done
        fi
        [ -n "$WLROOTS" ] || die "dkde-compositor needs wlroots 0.19 or 0.20 development files (or COMPOSITOR=no)."
        command -v wayland-scanner >/dev/null 2>&1 || die "dkde-compositor needs wayland-scanner (or COMPOSITOR=no)."
        missing=""
        for m in "wlroots-$WLROOTS" wayland-server xkbcommon pixman-1 libinput; do
            pkg-config --exists "$m" 2>/dev/null || missing="$missing $m"
        done
        [ -z "$missing" ] || die "dkde-compositor: missing development files for:$missing (or COMPOSITOR=no)"
    fi
    if [ "$WM" = yes ]; then
        missing=""
        for m in xcb xkbcommon pangocairo cairo; do
            pkg-config --exists "$m" 2>/dev/null || missing="$missing $m"
        done
        [ -n "$XCB_RANDR_PREFIX" ] || pkg-config --exists xcb-randr 2>/dev/null || missing="$missing xcb-randr"
        [ -z "$missing" ] || die "dkde-wm: missing development files for:$missing (or WM=no; XCB_RANDR_PREFIX=DIR for a private libxcb-randr)"
    fi
    [ -d zig-pkg ] || die "no zig-pkg/ directory: use the release tarball, or run 'zig build --fetch' once with a network."
}

build() {
    check
    say "building (mode $MODE, cpu $CPU${TARGET:+, target $TARGET})"
    # --system: never touch the network, read dependencies from zig-pkg/.
    # shellcheck disable=SC2086
    "$ZIG" build --release="$MODE" -Dcpu="$CPU" ${TARGET:+-Dtarget="$TARGET"} \
        --system zig-pkg --prefix "$PREFIX" $FLAGS install
    # The compositor and the X11 window manager are separate Zig packages (so the
    # main build needs neither wlroots nor X11); they share the same vendored
    # dependencies and install into the same prefix.
    if [ "$COMPOSITOR" = yes ]; then
        say "building dkde-compositor (wlroots $WLROOTS)"
        # shellcheck disable=SC2086
        (cd src/compositor && "$ZIG" build --release="$MODE" -Dcpu="$CPU" ${TARGET:+-Dtarget="$TARGET"} \
            -Dwlroots="$WLROOTS" ${XCB_RANDR_PREFIX:+-Dxcb-randr-prefix="$XCB_RANDR_PREFIX"} \
            --system "$src/zig-pkg" --prefix "$PREFIX" $FLAGS install)
        install -D -m 644 data/dkde-compositor.desktop "$DESTDIR$PREFIX/share/wayland-sessions/dkde-compositor.desktop"
    fi
    if [ "$WM" = yes ]; then
        say "building dkde-wm"
        # shellcheck disable=SC2086
        (cd src/xwm && "$ZIG" build --release="$MODE" -Dcpu="$CPU" ${TARGET:+-Dtarget="$TARGET"} \
            ${XCB_RANDR_PREFIX:+-Dxcb-randr-prefix="$XCB_RANDR_PREFIX"} \
            --system "$src/zig-pkg" --prefix "$PREFIX" $FLAGS install)
    fi
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
