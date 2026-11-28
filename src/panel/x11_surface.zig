// SPDX-License-Identifier: GPL-2.0-or-later
//! Where the panel's windows live on X11: the same requests the layer-shell
//! code takes, answered with EWMH. A bar is a dock window with a strut, the
//! wallpaper a desktop window, the Start menu a skip-taskbar dialog next to
//! the bar, and the pop-ups (volume, notifications) unmanaged windows placed
//! by hand. Placement goes through our own XCB connection because GTK 4 can
//! no longer move a window.

const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gobject = @import("gobject2");
const glib = @import("glib2");
const gdkx11 = @import("gdkx114");
const xc = @import("x11desktop").c;
const layer_shell = @import("layer_shell.zig");

const Options = layer_shell.Options;

const Kind = enum { dock, desktop, menu, popup };

const Info = struct {
    window: *gtk.Window,
    opts: Options,
    zone: c_int,
    mon: gdk.Rectangle,
    kind: Kind,
    xid: u32 = 0,
};

var infos: std.ArrayList(*Info) = .empty;
var conn: ?*xc.xcb_connection_t = null;
var screen: ?*xc.xcb_screen_t = null;
var is_x11: ?bool = null;

/// Whether the panel is running on X11 (and so must use this file).
pub fn active() bool {
    if (is_x11) |v| return v;
    const display = gdk.Display.getDefault();
    const x = display != null and gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display.?)), gdkx11.X11Display.getGObjectType()) != 0;
    is_x11 = x;
    return x;
}

fn connection() ?*xc.xcb_connection_t {
    if (conn) |cn| return cn;
    var num: c_int = 0;
    const cn = xc.xcb_connect(null, &num) orelse return null;
    if (xc.xcb_connection_has_error(cn) != 0) return null;
    var it = xc.xcb_setup_roots_iterator(xc.xcb_get_setup(cn));
    var i: c_int = 0;
    while (i < num) : (i += 1) xc.xcb_screen_next(&it);
    screen = it.data;
    conn = cn;
    return cn;
}

fn atom(cn: *xc.xcb_connection_t, name: []const u8) u32 {
    const r = xc.xcb_intern_atom_reply(cn, xc.xcb_intern_atom(cn, 0, @intCast(name.len), name.ptr), null) orelse return 0;
    defer std.c.free(r);
    return r.*.atom;
}

fn setAtoms(cn: *xc.xcb_connection_t, xid: u32, prop: []const u8, values: []const []const u8) void {
    var list: [4]u32 = undefined;
    for (values, 0..) |v, i| list[i] = atom(cn, v);
    _ = xc.xcb_change_property(cn, xc.XCB_PROP_MODE_REPLACE, xid, atom(cn, prop), xc.XCB_ATOM_ATOM, 32, @intCast(values.len), &list);
}

fn kindOf(opts: Options) Kind {
    if (opts.layer == .background) return .desktop;
    if (opts.layer == .top) return .dock;
    if (opts.menu_side != null) return .menu;
    return .popup;
}

fn monitorRect(monitor: ?*gdk.Monitor) gdk.Rectangle {
    var rect: gdk.Rectangle = .{ .f_x = 0, .f_y = 0, .f_width = 1280, .f_height = 720 };
    if (monitor) |m| {
        m.getGeometry(&rect);
        return rect;
    }
    if (gdk.Display.getDefault()) |d| {
        const list = d.getMonitors();
        if (list.getItem(0)) |item| {
            const m: *gdk.Monitor = @ptrCast(@alignCast(item));
            m.getGeometry(&rect);
            gobject.Object.unref(@ptrCast(@alignCast(item)));
        }
    }
    return rect;
}

pub fn setup(window: *gtk.Window, opts: Options) void {
    const info = std.heap.c_allocator.create(Info) catch return;
    info.* = .{ .window = window, .opts = opts, .zone = opts.exclusive_zone, .mon = monitorRect(opts.monitor), .kind = kindOf(opts) };
    infos.append(std.heap.c_allocator, info) catch return;
    window.setDecorated(0);
    switch (info.kind) {
        .dock => {
            const horizontal = opts.size > 0 and edgeIsHorizontal(opts);
            if (horizontal) window.setDefaultSize(info.mon.f_width, opts.size) else window.setDefaultSize(opts.size, info.mon.f_height);
            // The bar's own sizing asks for the natural width; the dock must span the screen.
            if (horizontal) window.as(gtk.Widget).setSizeRequest(info.mon.f_width, -1) else window.as(gtk.Widget).setSizeRequest(-1, info.mon.f_height);
        },
        .desktop => window.setDefaultSize(info.mon.f_width, info.mon.f_height),
        else => {},
    }
    _ = gtk.Widget.signals.realize.connect(window, *Info, &onRealize, info, .{});
    _ = gtk.Widget.signals.map.connect(window, *Info, &onMap, info, .{});
}

/// A bar spans the width when it is anchored left, right and to one of top or bottom.
fn edgeIsHorizontal(opts: Options) bool {
    var left = false;
    var right = false;
    for (opts.anchors) |e| {
        if (e == .left) left = true;
        if (e == .right) right = true;
    }
    return left and right;
}

pub fn setExclusiveZone(window: *gtk.Window, zone: c_int) void {
    for (infos.items) |info| if (info.window == window) {
        info.zone = zone;
        if (info.xid != 0) publishStrut(info);
    };
}

fn xidOf(window: *gtk.Window) u32 {
    const native: *gtk.Native = @ptrCast(window);
    const surf = native.getSurface() orelse return 0;
    if (gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(surf)), gdkx11.X11Surface.getGObjectType()) == 0) return 0;
    return @intCast(gdkx11.X11Surface.getXid(@ptrCast(surf)));
}

fn onRealize(_: *gtk.Window, info: *Info) callconv(.c) void {
    const cn = connection() orelse return;
    info.xid = xidOf(info.window);
    if (info.xid == 0) return;
    // The type and state must be there before the window is shown, for the window manager to read.
    switch (info.kind) {
        .dock => setAtoms(cn, info.xid, "_NET_WM_WINDOW_TYPE", &.{"_NET_WM_WINDOW_TYPE_DOCK"}),
        .desktop => setAtoms(cn, info.xid, "_NET_WM_WINDOW_TYPE", &.{"_NET_WM_WINDOW_TYPE_DESKTOP"}),
        .menu => {
            setAtoms(cn, info.xid, "_NET_WM_WINDOW_TYPE", &.{"_NET_WM_WINDOW_TYPE_DIALOG"});
            setAtoms(cn, info.xid, "_NET_WM_STATE", &.{ "_NET_WM_STATE_SKIP_TASKBAR", "_NET_WM_STATE_ABOVE" });
        },
        .popup => setAtoms(cn, info.xid, "_NET_WM_WINDOW_TYPE", &.{"_NET_WM_WINDOW_TYPE_NOTIFICATION"}),
    }
    if (info.kind == .dock) publishStrut(info);
    _ = xc.xcb_flush(cn);
    // Pop-ups follow their own size as it changes.
    const native: *gtk.Native = @ptrCast(info.window);
    if (native.getSurface()) |surf| _ = gdk.Surface.signals.layout.connect(surf, *Info, &onLayout, info, .{});
}

fn onMap(_: *gtk.Window, info: *Info) callconv(.c) void {
    place(info);
    // GTK writes its own _NET_WM_STATE when it maps the window, so a menu's
    // "not a task, stay on top" is asked of the window manager afterwards.
    if (info.kind == .menu) _ = glib.timeoutAdd(150, onMenuState, info);
}

fn onMenuState(data: ?*anyopaque) callconv(.c) c_int {
    const info: *Info = @ptrCast(@alignCast(data.?));
    const cn = connection() orelse return 0;
    const scr = screen orelse return 0;
    if (info.xid == 0) return 0;
    for ([_][]const u8{ "_NET_WM_STATE_SKIP_TASKBAR", "_NET_WM_STATE_ABOVE" }) |name| {
        var ev: xc.xcb_client_message_event_t = std.mem.zeroes(xc.xcb_client_message_event_t);
        ev.response_type = xc.XCB_CLIENT_MESSAGE;
        ev.format = 32;
        ev.window = info.xid;
        ev.type = atom(cn, "_NET_WM_STATE");
        ev.data.data32[0] = 1; // add
        ev.data.data32[1] = atom(cn, name);
        ev.data.data32[3] = 1;
        _ = xc.xcb_send_event(cn, 0, scr.*.root, xc.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | xc.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY, @ptrCast(&ev));
    }
    _ = xc.xcb_flush(cn);
    return 0;
}

fn onLayout(_: *gdk.Surface, _: c_int, _: c_int, info: *Info) callconv(.c) void {
    if (info.kind == .menu or info.kind == .popup) place(info);
}

/// _NET_WM_STRUT_PARTIAL for a bar: the screen edge it sits on, how far it reaches, and which part of the edge.
fn publishStrut(info: *Info) void {
    const cn = connection() orelse return;
    const scr = screen orelse return;
    const sw: i32 = scr.*.width_in_pixels;
    const sh: i32 = scr.*.height_in_pixels;
    const m = info.mon;
    var strut: [12]u32 = @splat(0);
    const zone: i32 = @max(info.zone, 0);
    if (zone > 0) {
        for (info.opts.anchors) |e| {
            switch (e) {
                .left => if (!edgeIsHorizontal(info.opts)) {
                    strut[0] = @intCast(m.f_x + zone);
                    strut[4] = @intCast(m.f_y);
                    strut[5] = @intCast(m.f_y + m.f_height - 1);
                },
                .right => if (!edgeIsHorizontal(info.opts)) {
                    strut[1] = @intCast(@max(sw - (m.f_x + m.f_width), 0) + zone);
                    strut[6] = @intCast(m.f_y);
                    strut[7] = @intCast(m.f_y + m.f_height - 1);
                },
                .top => if (edgeIsHorizontal(info.opts)) {
                    strut[2] = @intCast(m.f_y + zone);
                    strut[8] = @intCast(m.f_x);
                    strut[9] = @intCast(m.f_x + m.f_width - 1);
                },
                .bottom => if (edgeIsHorizontal(info.opts)) {
                    strut[3] = @intCast(@max(sh - (m.f_y + m.f_height), 0) + zone);
                    strut[10] = @intCast(m.f_x);
                    strut[11] = @intCast(m.f_x + m.f_width - 1);
                },
            }
        }
    }
    _ = xc.xcb_change_property(cn, xc.XCB_PROP_MODE_REPLACE, info.xid, atom(cn, "_NET_WM_STRUT_PARTIAL"), xc.XCB_ATOM_CARDINAL, 32, 12, &strut);
    _ = xc.xcb_change_property(cn, xc.XCB_PROP_MODE_REPLACE, info.xid, atom(cn, "_NET_WM_STRUT"), xc.XCB_ATOM_CARDINAL, 32, 4, &strut);
    _ = xc.xcb_flush(cn);
}

fn surfaceSize(info: *Info) struct { w: i32, h: i32 } {
    const native: *gtk.Native = @ptrCast(info.window);
    const surf = native.getSurface() orelse return .{ .w = 1, .h = 1 };
    const scale = surf.getScaleFactor();
    return .{ .w = surf.getWidth() * scale, .h = surf.getHeight() * scale };
}

fn move(cn: *xc.xcb_connection_t, xid: u32, x: i32, y: i32, size: ?struct { w: i32, h: i32 }) void {
    if (size) |s| {
        var v = [_]u32{ @bitCast(x), @bitCast(y), @intCast(@max(s.w, 1)), @intCast(@max(s.h, 1)) };
        _ = xc.xcb_configure_window(cn, xid, xc.XCB_CONFIG_WINDOW_X | xc.XCB_CONFIG_WINDOW_Y | xc.XCB_CONFIG_WINDOW_WIDTH | xc.XCB_CONFIG_WINDOW_HEIGHT, &v);
    } else {
        var v = [_]u32{ @bitCast(x), @bitCast(y) };
        _ = xc.xcb_configure_window(cn, xid, xc.XCB_CONFIG_WINDOW_X | xc.XCB_CONFIG_WINDOW_Y, &v);
    }
}

fn has(info: *const Info, e: layer_shell.Edge) bool {
    for (info.opts.anchors) |a| if (a == e) return true;
    return false;
}

/// Puts the window where its anchors say.
fn place(info: *Info) void {
    const cn = connection() orelse return;
    if (info.xid == 0) info.xid = xidOf(info.window);
    if (info.xid == 0) return;
    const m = info.mon;
    switch (info.kind) {
        .desktop => move(cn, info.xid, m.f_x, m.f_y, .{ .w = m.f_width, .h = m.f_height }),
        .dock => {
            const t = info.opts.size;
            if (edgeIsHorizontal(info.opts)) {
                const y = if (has(info, .bottom)) m.f_y + m.f_height - t else m.f_y;
                move(cn, info.xid, m.f_x, y, .{ .w = m.f_width, .h = t });
            } else {
                const x = if (has(info, .right)) m.f_x + m.f_width - t else m.f_x;
                move(cn, info.xid, x, m.f_y, .{ .w = t, .h = m.f_height });
            }
        },
        .menu => {
            const s = surfaceSize(info);
            const bar = info.opts.size;
            const side = info.opts.menu_side orelse .bottom;
            // In the corner beside the bar, as the layer-shell menu is.
            var x = m.f_x;
            var y = m.f_y + m.f_height - s.h;
            switch (side) {
                .bottom => y = m.f_y + m.f_height - bar - s.h,
                .top => y = m.f_y + bar,
                .left => x = m.f_x + bar,
                .right => x = m.f_x + m.f_width - bar - s.w,
            }
            move(cn, info.xid, x, y, null);
        },
        .popup => {
            const s = surfaceSize(info);
            var x = m.f_x + @divFloor(m.f_width - s.w, 2);
            var y = m.f_y + @divFloor(m.f_height - s.h, 2);
            if (has(info, .left)) x = m.f_x;
            if (has(info, .right)) x = m.f_x + m.f_width - s.w;
            if (has(info, .top)) y = m.f_y;
            if (has(info, .bottom)) y = m.f_y + m.f_height - s.h;
            move(cn, info.xid, x, y, null);
        },
    }
    _ = xc.xcb_flush(cn);
}

/// Makes a bar span its screen edge again after the caller has set its own sizes (X11 has no anchors to do it).
pub fn span(window: *gtk.Window, vertical: bool, thickness: c_int) void {
    for (infos.items) |info| if (info.window == window) {
        info.opts.size = thickness;
        if (vertical) {
            window.as(gtk.Widget).setSizeRequest(thickness, info.mon.f_height);
            window.setDefaultSize(thickness, info.mon.f_height);
        } else {
            window.as(gtk.Widget).setSizeRequest(info.mon.f_width, thickness);
            window.setDefaultSize(info.mon.f_width, thickness);
        }
        if (info.xid != 0) {
            place(info);
            publishStrut(info);
        }
    };
}
