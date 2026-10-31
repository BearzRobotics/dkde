//! Minimal binding for gtk4-layer-shell, covering only what dkde uses.
//! The library must be linked before libwayland (see build.zig).

const gtk = @import("gtk4");
const gdk = @import("gdk4");

pub const Layer = enum(c_int) { background = 0, bottom = 1, top = 2, overlay = 3 };
pub const Edge = enum(c_int) { left = 0, right = 1, top = 2, bottom = 3 };
pub const KeyboardMode = enum(c_int) { none = 0, exclusive = 1, on_demand = 2 };

extern fn gtk_layer_init_for_window(window: *gtk.Window) void;
extern fn gtk_layer_set_namespace(window: *gtk.Window, name_space: [*:0]const u8) void;
extern fn gtk_layer_set_layer(window: *gtk.Window, layer: Layer) void;
extern fn gtk_layer_set_monitor(window: *gtk.Window, monitor: ?*gdk.Monitor) void;
extern fn gtk_layer_set_anchor(window: *gtk.Window, edge: Edge, anchor_to_edge: c_int) void;
extern fn gtk_layer_set_exclusive_zone(window: *gtk.Window, exclusive_zone: c_int) void;
extern fn gtk_layer_set_keyboard_mode(window: *gtk.Window, mode: KeyboardMode) void;

pub const Options = struct {
    name_space: [:0]const u8,
    layer: Layer,
    monitor: ?*gdk.Monitor = null,
    /// Edges the surface is anchored to.
    anchors: []const Edge,
    /// Pixels reserved from other windows; -1 means "ignore other zones".
    exclusive_zone: c_int = 0,
    keyboard_mode: KeyboardMode = .none,
    /// The bar's thickness in pixels. Layer-shell ignores it; the X11 backend
    /// needs it to size and place docks and menus.
    size: c_int = 0,
    /// For a menu: the edge the bar sits on. Layer-shell ignores it.
    menu_side: ?Edge = null,
};

/// Turns `window` into a layer surface. Call before the window is shown.
pub fn setup(window: *gtk.Window, opts: Options) void {
    gtk_layer_init_for_window(window);
    gtk_layer_set_namespace(window, opts.name_space);
    gtk_layer_set_layer(window, opts.layer);
    gtk_layer_set_monitor(window, opts.monitor);
    for (opts.anchors) |edge| gtk_layer_set_anchor(window, edge, 1);
    gtk_layer_set_exclusive_zone(window, opts.exclusive_zone);
    gtk_layer_set_keyboard_mode(window, opts.keyboard_mode);
}

pub fn setExclusiveZone(window: *gtk.Window, zone: c_int) void {
    gtk_layer_set_exclusive_zone(window, zone);
}
