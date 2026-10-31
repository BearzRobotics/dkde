//! Where the panel's windows live: layer-shell on Wayland, EWMH dock/desktop
//! windows on X11. The X11 half is only compiled with `-Dx11=true`; without
//! it these functions always take the Wayland path.

const gtk = @import("gtk4");
const build_options = @import("build_options");

const layer_shell = @import("layer_shell.zig");

pub const Layer = layer_shell.Layer;
pub const Edge = layer_shell.Edge;
pub const KeyboardMode = layer_shell.KeyboardMode;
pub const Options = layer_shell.Options;

const x11 = if (build_options.x11) @import("x11.zig") else struct {
    pub fn isActive() bool {
        return false;
    }
    pub fn setup(_: *gtk.Window, _: Options) void {}
    pub fn setExclusiveZone(_: *gtk.Window, _: c_int) void {}
    pub fn setSize(_: *gtk.Window, _: c_int) void {}
};

/// Whether the session is X11 (and this build can drive it).
pub fn isX11() bool {
    return x11.isActive();
}

pub fn setup(window: *gtk.Window, opts: Options) void {
    if (isX11()) return x11.setup(window, opts);
    layer_shell.setup(window, opts);
}

pub fn setExclusiveZone(window: *gtk.Window, zone: c_int) void {
    if (isX11()) return x11.setExclusiveZone(window, zone);
    layer_shell.setExclusiveZone(window, zone);
}

/// Resizes a docked window to a new thickness (a no-op on Wayland, where the
/// window's own size request does it).
pub fn setSize(window: *gtk.Window, size: c_int) void {
    if (isX11()) x11.setSize(window, size);
}
