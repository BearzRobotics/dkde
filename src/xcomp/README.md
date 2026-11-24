# dkde-xcomp

DKDE's X11 compositing manager. It runs next to a window manager (`dkde-wm`, or any other that sets `_NET_WM_WINDOW_OPACITY` and the EWMH desktop properties), takes over drawing the screen and gives X11 the effects of the Wayland compositor that need one. Pure Zig and XCB, EGL and GLES2 for the drawing; no picom, no scenefx. A separate package (like `src/compositor` and `src/xwm`) so the main build needs no X11 development files.

```
zig build         # needs libxcb with composite, damage and xfixes, EGL and GLESv2 development files
zig build test
# without libxcb-composite0-dev, libxcb-damage0-dev and libxcb-xfixes0-dev installed: -Dxcb-prefix=DIR (DIR/include, DIR/lib)
```

The session script (`dkde-session --x11`) starts it after dkde-wm. It reads `~/.config/dkde/compositor.toml` (the same file as the compositor and dkde-wm, reloaded when it changes) and the shaders and effect code are the compositor's own, shared through `../compositor/src/shared.zig` (`fx.zig`: shaders and the frame settings; `cube.zig`, `anim.zig`, `filters.zig`, `snow.zig`).

## What it does

It composes **only while a setting needs it**: any of `[effects]` `animations`, `blur`, `cube`, `snow`, `zoom`, `lens`, `water`, `motion-blur`, `trailfocus`, `opacify`, a `filter` other than `none`, `[windows] inactive-opacity` below 1, or a `[[rules]]` opacity. Otherwise it only waits (no redirection, no overlay, no GL), so windows are drawn by the X server as usual. Turning the last one off in Settings stops compositing again. A filter, zoom, lens or the pointer finder switched on with a key makes it compose while they are on.

- **Window opacity**: `_NET_WM_WINDOW_OPACITY` (what dkde-wm sets for `inactive-opacity`, `trailfocus`, `opacify`, rule opacity and Super+Ctrl+Up/Down) is applied for real.
- **Animations** (`animations`, `animation-ms`): windows fade and grow when they open and fade as they close (the last picture of a closed window stays and fades).
- **Blur** behind see-through windows (`blur`).
- **Desktop cube** (`cube`, three or more desktops): switching workspace turns a cube, tilted, with a top and a floor reflection. The face of the desktop you leave is its last picture and the one you enter is live; a jump over other desktops shows them as dark faces. The window manager's own fades are not shown during the turn.
- **Screen**: colour filter (`filter`, Super+Ctrl+F steps through them), zoom (`zoom`, Super+= / Super+- / Super+0), lens (`lens`, Super+M), water ripples (`water`), motion blur (`motion-blur`), snow (`snow`), the pointer finder (Super+P). Keys are dkde-wm's; it sends the action to dkde-xcomp as a ClientMessage `_DKDE_COMP_ACTION` on the root window (`fx.Request`).

Not done on X11: Scale, Expo, the Alt+Tab previews, wobbly windows, shelf, fire and paint (they need pointer input and window geometry that only the window manager has), fractional scaling, full-screen unredirection, drop shadows, RandR changes of the screen size while compositing.

## How it works

Every child of the root is redirected (Composite, manual), the overlay window is drawn on with EGL (the XCB platform) and GLES2, and the overlay's input shape is empty so the pointer reaches the windows. A window's picture is fetched with GetImage when Damage says it changed (only the damaged rectangle after the first full fetch) and uploaded to a texture. Frames are redrawn when anything changed or an animation runs (8 ms apart at most). Everything is drawn bottom-up the way GL has it; the post pass (zoom, filter, lens, ripples, motion blur) is the compositor's shader.

When compositing starts on windows that already exist, redirecting loses the pixels of their child windows (a client inside the window manager's frame), so each child is sent an Expose to paint again. Damage is watched before the redirect so that is not missed.

The GetImage path works with every X server, including Xvfb and software GL. A texture-from-pixmap path (EGL images of the windows' pixmaps) would avoid the copy on real GPUs and is the obvious next speed-up.

## Testing

Under Xvfb (`+extension Composite`) with dkde-wm, xterm, xdotool and `import -window root`; Mesa's software GL draws on the overlay. Verified there: the open and close fades, window opacity, blur behind a half-transparent window, the colour filter (from the file and from the key, which starts and stops compositing), zoom, lens, pointer finder, snow, the cube (with a window on another desktop), and a clean exit. Not tried: real hardware or a real X server with a GPU, multiple monitors, high-DPI.
