#!/bin/bash
# Boots the dkbuild dkde ISO in QEMU with dkde-compositor in place of labwc, and gives helpers to drive it.
#
#   qemu/vm.sh up       start the VM and the compositor session (needs build output, see README.md)
#   qemu/vm.sh shot N   screenshot to $VM/N.png
#   qemu/vm.sh key a b  press keys together (qcodes: alt, t, 2, ret ...)
#   qemu/vm.sh run CMD  run a command on the guest's serial console as `live`
#   qemu/vm.sh click X Y [alt]   absolute pointer click (1280x800 screen); with "alt" holds Alt
#   qemu/vm.sh drag X1 Y1 X2 Y2 [alt] [button]   (button: left, right)   press, move, release
#   qemu/vm.sh push     copy $BIN into the shared folder and restart the session
#   qemu/vm.sh restart  restart the session (compositor, panel)
#   qemu/vm.sh down
#
# VM is the work folder (default: ./vm-work) holding q.sock, ser.sock, share.img and the screenshots.
set -u
here=$(cd "$(dirname "$0")" && pwd)
VM=${VM:-$PWD/vm-work}
ISO=${ISO:-/stuff/git/dkbuild/out/dkde/dkde.iso}
BIN=${BIN:-$VM/musl-out/bin/dkde-compositor}
mkdir -p "$VM"

qmp() { python3 "$here/qmp.py" "$VM/q.sock" "$@"; }
ser() { python3 "$here/ser.py" "$VM/ser.sock" "$@"; }

abs() { # x y -> abs events scaled to 0..32767
    python3 - "$1" "$2" <<'P'
import sys, json
x, y = int(sys.argv[1]), int(sys.argv[2])
print(json.dumps([{"type":"abs","data":{"axis":"x","value":x*32767//1279}},{"type":"abs","data":{"axis":"y","value":y*32767//799}}]))
P
}

send() { qmp input-send-event "{\"events\":$1}" >/dev/null; }

case "${1:-}" in
up)
    rm -f "$VM/q.sock" "$VM/ser.sock"
    mkdir -p "$VM/share"; cp "$BIN" "$VM/share/dkde-compositor"
    printf '[windows]\nlayout = "floating"\ngap = 8\n\n[workspaces]\ncount = 4\n' > "$VM/share/compositor.toml"
    setsid nohup qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 4 -cdrom "$ISO" -boot d \
        -virtfs local,path="$VM/share",mount_tag=hostshare,security_model=none,readonly=on -vga virtio -display none \
        -device virtio-tablet-pci -device virtio-keyboard-pci \
        -qmp unix:"$VM/q.sock",server=on,wait=off -serial unix:"$VM/ser.sock",server=on,wait=off \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 > "$VM/qemu.log" 2>&1 &
    echo $! > "$VM/qemu.pid"
    for i in $(seq 1 60); do sleep 3; case "$(ser "" 1)" in *"login:"*) break ;; esac; done
    ser "" 2 >/dev/null; ser "live" 3 >/dev/null
    ser "echo '' | sudo -S -p '' mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt" 3 >/dev/null
    python3 - "$VM/ser.sock" "$here/guest-wrapper.txt" <<'P'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(0.5)
for line in open(sys.argv[2]).read().split("\n"):
    s.sendall((line + "\n").encode()); time.sleep(0.15)
time.sleep(2)
P
    # Restart the session so dkde-session picks up ~/bin/labwc (our compositor).
    pids=$(ser "ps ax -o pid,args" 3 | python3 -c "
import sys
for line in sys.stdin:
    f = line.split(None, 1)
    if len(f) == 2 and f[0].isdigit() and (f[1].startswith(('labwc', 'dkde-panel', 'dkde-idle', '/bin/sh /usr/bin/dkde-session')) or 'labwc/autostart' in f[1]):
        print(f[0])")
    ser "kill $(echo $pids)" 3 >/dev/null
    sleep 25
    ;;
push)  # copy a freshly built compositor into the shared folder, then restart the session (the guest sees it at once)
    cp "$BIN" "$VM/share/dkde-compositor"; "$0" restart ;;
restart)
    pids=$(ser "ps ax -o pid,args" 3 | python3 -c "
import sys
for line in sys.stdin:
    f = line.split(None, 1)
    if len(f) == 2 and f[0].isdigit() and (f[1].startswith(('/mnt/dkde-compositor', 'dkde-panel', 'dkde-idle', 'dkde-calc', 'dkde-term')) or 'bin/labwc' in f[1]):
        print(f[0])")
    ser "kill $(echo $pids)" 3 >/dev/null
    sleep 20 ;;
shot)  qmp screendump "{\"filename\":\"$VM/$2.ppm\"}" >/dev/null; convert "$VM/$2.ppm" "$VM/$2.png"; echo "$VM/$2.png" ;;
key)
    shift; keys=""; for k in "$@"; do keys="$keys{\"type\":\"qcode\",\"data\":\"$k\"},"; done
    qmp send-key "{\"keys\":[${keys%,}]}" >/dev/null ;;
run)   ser "export XDG_RUNTIME_DIR=/tmp/dkde-runtime-1000 WAYLAND_DISPLAY=wayland-0; $2" "${3:-3}" ;;
click)
    [ "${4:-}" = alt ] && { send '[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"alt"}}}]'; sleep 0.4; }
    send "[$(abs "$2" "$3" | tr -d '[]')]"; sleep 0.2
    send '[{"type":"btn","data":{"down":true,"button":"left"}}]'; sleep 0.1
    send '[{"type":"btn","data":{"down":false,"button":"left"}}]'
    [ "${4:-}" = alt ] && { sleep 0.2; send '[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"alt"}}}]'; } ;;
drag)
    b=${7:-left}
    [ "${6:-}" = alt ] && { send '[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"alt"}}}]'; sleep 0.4; }
    send "[$(abs "$2" "$3" | tr -d '[]')]"; sleep 0.3
    send "[{\"type\":\"btn\",\"data\":{\"down\":true,\"button\":\"$b\"}}]"; sleep 0.4
    for f in 1 2 3 4 5 6; do
        x=$(( $2 + ($4 - $2) * f / 6 )); y=$(( $3 + ($5 - $3) * f / 6 ))
        send "[$(abs $x $y | tr -d '[]')]"; sleep 0.15
    done
    send "[{\"type\":\"btn\",\"data\":{\"down\":false,\"button\":\"$b\"}}]"
    [ "${6:-}" = alt ] && { sleep 0.3; send '[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"alt"}}}]'; } ;;
down)  kill "$(cat "$VM/qemu.pid")" 2>/dev/null ;;
*)     sed -n '2,13p' "$0" ;;
esac
