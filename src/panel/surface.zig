// SPDX-License-Identifier: GPL-2.0-or-later
//! Where the panel's windows live: layer-shell surfaces on Wayland, EWMH windows on X11.

const layer_shell = @import("layer_shell.zig");

pub const Layer = layer_shell.Layer;
pub const Edge = layer_shell.Edge;
pub const KeyboardMode = layer_shell.KeyboardMode;
pub const Options = layer_shell.Options;

const x11_surface = @import("x11_surface.zig");

/// Whether this is X11, where the same requests become EWMH ones.
pub const isX11 = x11_surface.active;

pub fn setup(window: *@import("gtk4").Window, opts: Options) void {
    if (x11_surface.active()) x11_surface.setup(window, opts) else layer_shell.setup(window, opts);
}

pub fn setExclusiveZone(window: *@import("gtk4").Window, zone: c_int) void {
    if (x11_surface.active()) x11_surface.setExclusiveZone(window, zone) else layer_shell.setExclusiveZone(window, zone);
}

/// On X11, makes the bar span the screen edge (call after setting its sizes).
pub fn span(window: *@import("gtk4").Window, vertical: bool, thickness: c_int) void {
    if (x11_surface.active()) x11_surface.span(window, vertical, thickness);
}
