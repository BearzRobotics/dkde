//! The drop-down terminal (`dkde-term --dropdown`, bound to F12), in the
//! manner of Guake and Yakuake: one terminal window that slides down from
//! the top of the screen and goes away again with the same key.
//!
//! The first `--dropdown` starts it; later ones only tell it to show or hide
//! itself, through a socket in the runtime folder. On Wayland it is a
//! layer-shell surface across the top of the screen (gtk4-layer-shell, which
//! must be loaded before Wayland: the program starts itself again with the
//! library preloaded); without it, an ordinary window at the top.

const std = @import("std");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const log = std.log.scoped(.term);

extern fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn readlink(path: [*:0]const u8, buf: [*]u8, size: usize) isize;
extern fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
const RTLD_DEFAULT: ?*anyopaque = null;

const layer_lib = "libgtk4-layer-shell.so.0";

/// The socket the running drop-down terminal listens on.
fn socketPath(buf: []u8) ?[:0]const u8 {
    const dir = std.mem.span(glib.getUserRuntimeDir());
    return std.fmt.bufPrintSentinel(buf, "{s}/dkde-term-dropdown.sock", .{dir}, 0) catch null;
}

/// Asks a running drop-down terminal to show or hide itself. True when one
/// answered (this process has nothing more to do).
pub fn toggleRunning() bool {
    var buf: [512]u8 = undefined;
    const path = socketPath(&buf) orelse return false;
    const addr = gio.UnixSocketAddress.new(path);
    defer addr.as(gobject.Object).unref();
    const client = gio.SocketClient.new();
    defer client.as(gobject.Object).unref();
    const conn = client.connect(addr.as(gio.SocketConnectable), null, null) orelse return false;
    defer conn.as(gobject.Object).unref();
    const out = conn.as(gio.IOStream).getOutputStream();
    var msg = "toggle\n".*;
    _ = out.writeAll(&msg, msg.len, null, null, null);
    _ = conn.as(gio.IOStream).close(null, null);
    return true;
}

/// Starts this program again with gtk4-layer-shell preloaded, unless it
/// already is (or the library is missing: then the window is ordinary).
pub fn reexecWithLayerShell(argv: []const [*:0]const u8) void {
    if (glib.getenv("DKDE_TERM_DROPDOWN_CHILD") != null) return;
    var found = false;
    for ([_][]const u8{ "/usr/lib/x86_64-linux-gnu", "/usr/lib64", "/usr/lib", "/usr/local/lib", "/usr/lib/aarch64-linux-gnu" }) |dir| {
        var pbuf: [256]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&pbuf, "{s}/{s}", .{ dir, layer_lib }, 0) catch continue;
        if (std.c.access(p.ptr, std.c.F_OK) == 0) found = true;
    }
    if (!found) return;
    var pre: [1024]u8 = undefined;
    const old = if (glib.getenv("LD_PRELOAD")) |v| std.mem.span(v) else "";
    const value = (if (old.len > 0) std.fmt.bufPrintSentinel(&pre, "{s} {s}", .{ layer_lib, old }, 0) else std.fmt.bufPrintSentinel(&pre, "{s}", .{layer_lib}, 0)) catch return;
    _ = setenv("LD_PRELOAD", value.ptr, 1);
    _ = setenv("DKDE_TERM_DROPDOWN_CHILD", "1", 1);
    var exe: [4096]u8 = undefined;
    const len = readlink("/proc/self/exe", &exe, exe.len - 1);
    if (len <= 0) return;
    const n = exe[0..@intCast(len)];
    exe[n.len] = 0;
    var args: [64:null]?[*:0]const u8 = @splat(null);
    for (argv[0..@min(argv.len, 63)], 0..) |a, i| args[i] = a;
    _ = execv(@ptrCast(exe[0..n.len :0].ptr), &args);
    log.warn("cannot restart with gtk4-layer-shell; the drop-down terminal is an ordinary window", .{});
}

const Layer = struct {
    init_for_window: *const fn (*gtk.Window) callconv(.c) void,
    set_layer: *const fn (*gtk.Window, c_int) callconv(.c) void,
    set_anchor: *const fn (*gtk.Window, c_int, c_int) callconv(.c) void,
    set_keyboard_mode: *const fn (*gtk.Window, c_int) callconv(.c) void,
    set_namespace: *const fn (*gtk.Window, [*:0]const u8) callconv(.c) void,
    is_supported: *const fn () callconv(.c) c_int,
};

fn layerShell() ?Layer {
    // Only on Wayland (asking under X11 makes the library complain).
    const display = gdk.Display.getDefault() orelse return null;
    const wl_type = gobject.typeFromName("GdkWaylandDisplay");
    if (wl_type == 0 or gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display)), wl_type) == 0) return null;
    var l: Layer = undefined;
    inline for (.{
        .{ "init_for_window", "gtk_layer_init_for_window" },
        .{ "set_layer", "gtk_layer_set_layer" },
        .{ "set_anchor", "gtk_layer_set_anchor" },
        .{ "set_keyboard_mode", "gtk_layer_set_keyboard_mode" },
        .{ "set_namespace", "gtk_layer_set_namespace" },
        .{ "is_supported", "gtk_layer_is_supported" },
    }) |f| {
        const sym = dlsym(RTLD_DEFAULT, f[1]) orelse return null;
        @field(l, f[0]) = @ptrCast(@alignCast(sym));
    }
    if (l.is_supported() == 0) return null;
    return l;
}

/// Turns `window` into the drop-down: across the top, `percent` of the
/// screen's height, above other windows.
pub fn setUp(window: *gtk.Window, percent: u32) void {
    var height: c_int = 400;
    if (gdk.Display.getDefault()) |display| {
        const monitors = display.getMonitors();
        if (monitors.getItem(0)) |item| {
            defer gobject.Object.unref(@ptrCast(@alignCast(item)));
            const mon: *gdk.Monitor = @ptrCast(@alignCast(item));
            var geo: gdk.Rectangle = undefined;
            mon.getGeometry(&geo);
            height = @divTrunc(geo.f_height * @as(c_int, @intCast(@min(percent, 95))), 100);
            window.setDefaultSize(geo.f_width, height);
        }
    }
    window.setDecorated(0);
    if (layerShell()) |l| {
        l.init_for_window(window);
        l.set_namespace(window, "dkde-dropdown");
        l.set_layer(window, 2); // top
        l.set_anchor(window, 2, 1); // top edge
        l.set_anchor(window, 0, 1); // left
        l.set_anchor(window, 1, 1); // right
        l.set_keyboard_mode(window, 2); // on demand
        window.as(gtk.Widget).setSizeRequest(-1, height);
    }
}

/// Listens for "toggle" from later `--dropdown` runs.
pub fn listen(window: *gtk.Window) void {
    var buf: [512]u8 = undefined;
    const path = socketPath(&buf) orelse return;
    std.Io.Dir.cwd().deleteFile(@import("common").fsio.io(), path) catch {};
    const service = gio.SocketService.new();
    const addr = gio.UnixSocketAddress.new(path);
    defer addr.as(gobject.Object).unref();
    var err: ?*glib.Error = null;
    if (service.as(gio.SocketListener).addAddress(addr.as(gio.SocketAddress), .stream, .default, null, null, &err) == 0) {
        if (err) |e| e.free();
        log.warn("the drop-down terminal cannot listen on {s}", .{path});
        return;
    }
    _ = gio.SocketService.signals.incoming.connect(service, *gtk.Window, &onIncoming, window, .{});
    service.start();
}

fn onIncoming(_: *gio.SocketService, conn: *gio.SocketConnection, _: ?*gobject.Object, window: *gtk.Window) callconv(.c) c_int {
    _ = conn;
    toggle(window);
    return 1;
}

pub fn toggle(window: *gtk.Window) void {
    const w = window.as(gtk.Widget);
    if (w.getVisible() != 0 and window.isActive() != 0) {
        w.setVisible(0);
    } else {
        window.present();
    }
}
