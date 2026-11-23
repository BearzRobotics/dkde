# Running dkde-compositor on a real display (DRM/KMS) in QEMU

The dkbuild live ISO (`/stuff/git/dkbuild/out/dkde/dkde.iso`, FenrirOS: musl, dinit, seatd,
wlroots 0.20) boots to the dkde desktop in about 45 seconds. These steps put our compositor
in place of labwc in that image, so it runs on the VM's virtio-gpu through libseat/seatd.
Nothing here touches the host display or session.

## 1. Build for the image (musl, wlroots 0.20)

The host has wlroots 0.19 (Ubuntu); the image has 0.20.2, so build against the image's own packages.
dkbuild's repository holds apk v3 packages; apk 3 itself is in the ISO, and runs on the host through
the ISO's musl loader (no root needed):

```sh
xorriso -osirrox on -indev dkde.iso -extract /live/rootfs.sfs rootfs.sfs
unsquashfs -d apkx -f rootfs.sfs usr/bin/apk usr/lib/libapk.so.3.0.0 usr/lib/libcrypto.so.3 \
  usr/lib/libssl.so.3 usr/lib/libz.so.1.3.1 usr/lib/libzstd.so.1.5.7 usr/lib/libc.so
ln -s libz.so.1.3.1 apkx/usr/lib/libz.so.1; ln -s libzstd.so.1.5.7 apkx/usr/lib/libzstd.so.1
ln -s libapk.so.3.0.0 apkx/usr/lib/libapk.so.3
APK="apkx/usr/lib/libc.so --library-path apkx/usr/lib apkx/usr/bin/apk"
$APK --root sysroot-musl --usermode --initdb --allow-untrusted --no-cache --no-scripts \
  --repository /stuff/git/dkbuild/repo/x86_64/Packages.adb add wlroots-devel libglvnd-devel
```

Rewrite the `.pc` files' `prefix`/`libdir`/`includedir` to the sysroot (copy them to a folder), then:

```sh
PKG_CONFIG_LIBDIR=<that folder> zig build -Dtarget=x86_64-linux-musl -Dwlroots=0.20 --prefix musl-out
```

## 2. A disk with the program, and the VM

```sh
mke2fs -t ext2 -d share share.img   # share/: dkde-compositor, compositor.toml (64 MB image)
qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 4 -cdrom dkde.iso -boot d \
  -drive file=share.img,if=virtio,format=raw -vga virtio -display none \
  -qmp unix:q.sock,server=on,wait=off -serial unix:ser.sock,server=on,wait=off \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

`qmp.py q.sock screendump '{"filename":"/path/x.ppm"}'` takes a screenshot (`convert x.ppm x.png`);
`qmp.py q.sock send-key '{"keys":[{"type":"qcode","data":"alt"},{"type":"qcode","data":"t"}]}'` presses
keys through the VM's own keyboard (real libinput path). `ser.py ser.sock 'command'` runs a command on
the serial console (log in as `live`, empty password; `echo '' | sudo -S -p '' ...` for root).

## 3. Swap labwc for the compositor

`dkde-session` runs whatever `labwc` is first in PATH. `guest-wrapper.txt` (paste it into the serial
shell, one line at a time) writes `~/bin/labwc`, a script that starts `/mnt/dkde-compositor` and then the
panel, and adds `~/bin` to PATH. Mount the disk (`sudo mount -o ro /dev/vda /mnt`), kill the running
labwc and `dkde-session`; the tty1 autologin restarts the session with our compositor. (The first
attempt can time out waiting for the seat while the old session lets go of the VT; the restart works.)
Run apps from the serial shell with `XDG_RUNTIME_DIR=/tmp/dkde-runtime-1000 WAYLAND_DISPLAY=wayland-0`.

## Shortcut: `vm.sh`

`qemu/vm.sh` does steps 2 and 3 and drives the guest: `VM=/stuff/tmp/vmw BIN=.../musl-out/bin/dkde-compositor qemu/vm.sh up`
(keep `VM` short: unix socket paths over 107 characters fail), then `shot NAME`, `key alt t`, `click X Y [alt]`,
`drag X1 Y1 X2 Y2 [alt] [left|right]`, `run 'COMMAND'`, `push` (copy a new build over the 9p share and restart
the session, about 20 s) and `down`. The program folder is shared with the guest over 9p, so no reboot is needed
between builds. The VM has a virtio tablet, so clicks and drags are absolute (1280x800).

## Testing the GLES effects (virgl)

The effects need wlroots' GLES2 renderer. `vm.sh` takes a few variables for that:

```sh
RENDERER=gles2 GPU="-device virtio-vga-gl" DISPLAY_OPT=egl-headless QEMU_EXTRA="-vnc 127.0.0.1:7" \
  TOML=/path/compositor.toml VM=/stuff/tmp/vmw BIN=.../musl-out/bin/dkde-compositor qemu/vm.sh up
```

(`TOML` is the guest's compositor.toml; the guest then renders on the host GPU through virgl.) QMP `screendump`
does not work with a GL scanout ("no surface"); take screenshots over VNC instead with `python3 qemu/vnc-shot.py
127.0.0.1 5907 out.png`. Keys with a hold time (`qmp.py send-key '{"keys":[...],"hold-time":2500}'`) keep Alt down
for the switcher. The image's greetd starts the first session by itself, so `vm.sh up` does not replace its
compositor: write `compositor=/home/live/bin/labwc` (the wrapper) to `~/.config/dkde/session.conf` in the guest and
sign in at the greeter (press Return). Checked this way, with real pointer events: the Alt+Tab ring, Expo, wobbly
windows (a drag), blur behind dimmed windows, painting on the screen and the negative filter.
