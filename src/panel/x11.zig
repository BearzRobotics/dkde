//! The X11 backend (SPEC.md 5.9), compiled only with `-Dx11=true`.
//!
//! Window placement and the window list use plain EWMH: the bar is a DOCK
//! window with struts, the wallpaper a DESKTOP window, and the taskbar reads
//! `_NET_CLIENT_LIST`. That works with any EWMH window manager; no compositor
//! is needed. Xlib is declared here by hand, so the only requirement is
//! libX11 itself.

const std = @import("std");
const gdk = @import("gdk4");
const gdkx11 = @import("gdkx114");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

const layer_shell = @import("layer_shell.zig");

const log = std.log.scoped(.x11);

// ---- Xlib -----------------------------------------------------------------

const Display = anyopaque;
const Window = c_ulong;
const Atom = c_ulong;

extern fn XInternAtom(dpy: *Display, name: [*:0]const u8, only_if_exists: c_int) Atom;
extern fn XChangeProperty(dpy: *Display, w: Window, property: Atom, kind: Atom, format: c_int, mode: c_int, data: [*]const u8, nelements: c_int) c_int;
extern fn XMoveResizeWindow(dpy: *Display, w: Window, x: c_int, y: c_int, width: c_uint, height: c_uint) c_int;
extern fn XMoveWindow(dpy: *Display, w: Window, x: c_int, y: c_int) c_int;
extern fn XFlush(dpy: *Display) c_int;
extern fn XFree(data: *anyopaque) c_int;
extern fn XGetWindowProperty(dpy: *Display, w: Window, property: Atom, offset: c_long, length: c_long, delete: c_int, req_type: Atom, actual_type: *Atom, actual_format: *c_int, nitems: *c_ulong, bytes_after: *c_ulong, prop: *?[*]u8) c_int;
extern fn XSendEvent(dpy: *Display, w: Window, propagate: c_int, mask: c_long, event: *Event) c_int;
extern fn XDefaultScreen(dpy: *Display) c_int;
extern fn XDisplayWidth(dpy: *Display, screen: c_int) c_int;
extern fn XDisplayHeight(dpy: *Display, screen: c_int) c_int;
extern fn XRootWindow(dpy: *Display, screen: c_int) Window;

const XA_ATOM: Atom = 4;
const XA_CARDINAL: Atom = 6;
const XA_WINDOW: Atom = 33;
const PropModeReplace = 0;
const SubstructureNotifyMask: c_long = 1 << 19;
const SubstructureRedirectMask: c_long = 1 << 20;

const ClientMessage = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: [5]c_long,
};

const Event = extern union {
    type: c_int,
    client: ClientMessage,
    pad: [24]c_long,
};

// ---- the display -------------------------------------------------------------

/// Whether GDK is running on X11 (rather than Wayland).
pub fn isActive() bool {
    const display = gdk.Display.getDefault() orelse return false;
    return gobject.typeCheckInstanceIsA(@ptrCast(@alignCast(display)), gdkx11.X11Display.getGObjectType()) != 0;
}

fn xdisplay() ?*Display {
    const display = gdk.Display.getDefault() orelse return null;
    const x: *gdkx11.X11Display = @ptrCast(@alignCast(display));
    return @ptrCast(x.getXdisplay());
}

fn atom(dpy: *Display, name: [*:0]const u8) Atom {
    return XInternAtom(dpy, name, 0);
}

fn setLongs(dpy: *Display, w: Window, property: [*:0]const u8, kind: Atom, values: []const c_long) void {
    _ = XChangeProperty(dpy, w, atom(dpy, property), kind, 32, PropModeReplace, @ptrCast(values.ptr), @intCast(values.len));
}

fn xidOf(window: *gtk.Window) ?Window {
    const surface = window.as(gtk.Native).getSurface() orelse return null;
    const x: *gdkx11.X11Surface = @ptrCast(@alignCast(surface));
    return x.getXid();
}

// ---- placing the panel's windows ------------------------------------------------

const Kind = enum { dock, desktop, menu };

const Placement = struct {
    kind: Kind,
    window: *gtk.Window,
    monitor: ?*gdk.Monitor,
    /// The edge the bar (or, for a menu, the bar the menu belongs to) is on.
    edge: layer_shell.Edge,
    size: c_int,
    zone: c_int,

    fn geometry(self: *const Placement) gdk.Rectangle {
        var rect: gdk.Rectangle = .{ .f_x = 0, .f_y = 0, .f_width = 1280, .f_height = 720 };
        if (self.monitor) |m| m.getGeometry(&rect);
        return rect;
    }

    /// The window's size on the screen, for docks and the wallpaper.
    fn wantedSize(self: *const Placement) ?struct { w: c_int, h: c_int } {
        const g = self.geometry();
        return switch (self.kind) {
            .desktop => .{ .w = g.f_width, .h = g.f_height },
            .dock => if (self.edge == .top or self.edge == .bottom)
                .{ .w = g.f_width, .h = self.size }
            else
                .{ .w = self.size, .h = g.f_height },
            .menu => null,
        };
    }

    /// Moves and sizes the window and (for a dock) reserves its screen edge.
    fn apply(self: *Placement) void {
        // GTK owns the window's size; tell it, or it resizes the window back.
        if (self.wantedSize()) |size| self.window.setDefaultSize(size.w, size.h);
        const dpy = xdisplay() orelse return;
        const xid = xidOf(self.window) orelse return;
        const g = self.geometry();
        const t = self.size;
        switch (self.kind) {
            .desktop => _ = XMoveResizeWindow(dpy, xid, g.f_x, g.f_y, @intCast(g.f_width), @intCast(g.f_height)),
            .dock => {
                const horizontal = self.edge == .top or self.edge == .bottom;
                const x: c_int = if (self.edge == .right) g.f_x + g.f_width - t else g.f_x;
                const y: c_int = if (self.edge == .bottom) g.f_y + g.f_height - t else g.f_y;
                const w: c_int = if (horizontal) g.f_width else t;
                const h: c_int = if (horizontal) t else g.f_height;
                _ = XMoveResizeWindow(dpy, xid, x, y, @intCast(w), @intCast(h));
                self.setStruts(dpy, xid, g);
            },
            .menu => {
                const w = self.window.as(gtk.Widget).getWidth();
                const h = self.window.as(gtk.Widget).getHeight();
                const x: c_int = switch (self.edge) {
                    .left => g.f_x + t,
                    .right => g.f_x + g.f_width - t - w,
                    else => g.f_x,
                };
                const y: c_int = switch (self.edge) {
                    .top => g.f_y + t,
                    else => g.f_y + g.f_height - (if (self.edge == .bottom) t else 0) - h,
                };
                _ = XMoveWindow(dpy, xid, x, y);
            },
        }
        _ = XFlush(dpy);
    }

    fn setStruts(self: *Placement, dpy: *Display, xid: Window, g: gdk.Rectangle) void {
        var partial: [12]c_long = @splat(0);
        const reserve: c_long = self.zone;
        if (reserve > 0) {
            const screen = XDefaultScreen(dpy);
            const sw = XDisplayWidth(dpy, screen);
            const sh = XDisplayHeight(dpy, screen);
            switch (self.edge) {
                .left => {
                    partial[0] = g.f_x + reserve;
                    partial[4] = g.f_y;
                    partial[5] = g.f_y + g.f_height - 1;
                },
                .right => {
                    partial[1] = (sw - (g.f_x + g.f_width)) + reserve;
                    partial[6] = g.f_y;
                    partial[7] = g.f_y + g.f_height - 1;
                },
                .top => {
                    partial[2] = g.f_y + reserve;
                    partial[8] = g.f_x;
                    partial[9] = g.f_x + g.f_width - 1;
                },
                .bottom => {
                    partial[3] = (sh - (g.f_y + g.f_height)) + reserve;
                    partial[10] = g.f_x;
                    partial[11] = g.f_x + g.f_width - 1;
                },
            }
        }
        setLongs(dpy, xid, "_NET_WM_STRUT_PARTIAL", XA_CARDINAL, &partial);
        setLongs(dpy, xid, "_NET_WM_STRUT", XA_CARDINAL, partial[0..4]);
    }

    /// Window type, state and desktop: set while the window is realised but
    /// not yet mapped, which is when window managers read them.
    fn declare(self: *Placement) void {
        const dpy = xdisplay() orelse return;
        const xid = xidOf(self.window) orelse return;
        const type_name: [*:0]const u8 = switch (self.kind) {
            .dock => "_NET_WM_WINDOW_TYPE_DOCK",
            .desktop => "_NET_WM_WINDOW_TYPE_DESKTOP",
            .menu => "_NET_WM_WINDOW_TYPE_POPUP_MENU",
        };
        setLongs(dpy, xid, "_NET_WM_WINDOW_TYPE", XA_ATOM, &.{@as(c_long, @intCast(atom(dpy, type_name)))});

        const states = [_]c_long{
            @intCast(atom(dpy, "_NET_WM_STATE_SKIP_TASKBAR")),
            @intCast(atom(dpy, "_NET_WM_STATE_SKIP_PAGER")),
            @intCast(atom(dpy, "_NET_WM_STATE_STICKY")),
            @intCast(atom(dpy, if (self.kind == .desktop) "_NET_WM_STATE_BELOW" else "_NET_WM_STATE_ABOVE")),
        };
        setLongs(dpy, xid, "_NET_WM_STATE", XA_ATOM, &states);
        // Every virtual desktop.
        setLongs(dpy, xid, "_NET_WM_DESKTOP", XA_CARDINAL, &.{@as(c_long, 0xFFFFFFFF)});
    }
};

fn placementOf(window: *gtk.Window) ?*Placement {
    const raw = window.as(gobject.Object).getData("dkde-x11-placement") orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn onRealize(_: *gtk.Window, p: *Placement) callconv(.c) void {
    p.declare();
}

fn onMap(_: *gtk.Window, p: *Placement) callconv(.c) void {
    p.apply();
    // A menu's size is only known after its first layout.
    if (p.kind == .menu) _ = glib.idleAdd(onMenuIdle, p);
}

fn onMenuIdle(data: ?*anyopaque) callconv(.c) c_int {
    const p: *Placement = @ptrCast(@alignCast(data.?));
    p.apply();
    return 0;
}

fn onDestroy(_: *gtk.Window, p: *Placement) callconv(.c) void {
    std.heap.c_allocator.destroy(p);
}

/// The X11 counterpart of `layer_shell.setup`.
pub fn setup(window: *gtk.Window, opts: layer_shell.Options) void {
    const kind: Kind = switch (opts.layer) {
        .background, .bottom => .desktop,
        .top => .dock,
        .overlay => .menu,
    };
    const p = std.heap.c_allocator.create(Placement) catch return;
    p.* = .{
        .kind = kind,
        .window = window,
        .monitor = opts.monitor,
        .edge = if (kind == .menu) (opts.menu_side orelse .bottom) else if (opts.anchors.len > 0) opts.anchors[0] else .bottom,
        .size = opts.size,
        .zone = opts.exclusive_zone,
    };
    window.setDecorated(0);
    if (p.wantedSize()) |size| window.setDefaultSize(size.w, size.h);
    window.as(gobject.Object).setData("dkde-x11-placement", p);
    _ = gtk.Widget.signals.realize.connect(window, *Placement, &onRealize, p, .{});
    _ = gtk.Widget.signals.map.connect(window, *Placement, &onMap, p, .{});
    _ = gtk.Widget.signals.destroy.connect(window, *Placement, &onDestroy, p, .{});
}

pub fn setExclusiveZone(window: *gtk.Window, zone: c_int) void {
    const p = placementOf(window) orelse return;
    p.zone = zone;
    p.apply();
}

pub fn setSize(window: *gtk.Window, size: c_int) void {
    const p = placementOf(window) orelse return;
    p.size = size;
    p.apply();
}

// ---- the window list (EWMH) ----------------------------------------------------------

pub const Info = struct {
    id: c_ulong,
    /// Both owned by the caller (`freeInfos`).
    title: []u8,
    app_id: []u8,
    maximized: bool,
    minimized: bool,
    activated: bool,
};

pub fn freeInfos(allocator: std.mem.Allocator, infos: []Info) void {
    for (infos) |i| {
        allocator.free(i.title);
        allocator.free(i.app_id);
    }
    allocator.free(infos);
}

const Prop = struct {
    data: [*]u8,
    count: usize,

    fn free(self: Prop) void {
        _ = XFree(self.data);
    }

    fn longs(self: Prop) []const c_long {
        const ptr: [*]const c_long = @ptrCast(@alignCast(self.data));
        return ptr[0..self.count];
    }
};

fn getProp(dpy: *Display, w: Window, name: [*:0]const u8, kind: Atom) ?Prop {
    var actual_type: Atom = 0;
    var actual_format: c_int = 0;
    var count: c_ulong = 0;
    var after: c_ulong = 0;
    var data: ?[*]u8 = null;
    const status = XGetWindowProperty(dpy, w, atom(dpy, name), 0, 4096, 0, kind, &actual_type, &actual_format, &count, &after, &data);
    if (status != 0 or data == null) return null;
    if (count == 0) {
        _ = XFree(data.?);
        return null;
    }
    return .{ .data = data.?, .count = count };
}

fn hasAtom(list: []const c_long, dpy: *Display, name: [*:0]const u8) bool {
    const wanted: c_long = @intCast(atom(dpy, name));
    for (list) |a| if (a == wanted) return true;
    return false;
}

/// The windows a taskbar should show, in the window manager's order.
pub fn snapshot(allocator: std.mem.Allocator) ![]Info {
    const dpy = xdisplay() orelse return error.NoDisplay;
    const root = XRootWindow(dpy, XDefaultScreen(dpy));

    var out: std.ArrayList(Info) = .empty;
    errdefer freeInfos(allocator, out.items);

    const clients = getProp(dpy, root, "_NET_CLIENT_LIST", XA_WINDOW) orelse return out.toOwnedSlice(allocator);
    defer clients.free();
    var active: c_long = 0;
    if (getProp(dpy, root, "_NET_ACTIVE_WINDOW", XA_WINDOW)) |a| {
        defer a.free();
        active = a.longs()[0];
    }

    for (clients.longs()) |raw| {
        const w: Window = @intCast(raw);
        // Docks, desktops and windows that ask not to be listed.
        if (getProp(dpy, w, "_NET_WM_WINDOW_TYPE", XA_ATOM)) |t| {
            defer t.free();
            const types = t.longs();
            if (hasAtom(types, dpy, "_NET_WM_WINDOW_TYPE_DOCK") or hasAtom(types, dpy, "_NET_WM_WINDOW_TYPE_DESKTOP") or
                hasAtom(types, dpy, "_NET_WM_WINDOW_TYPE_POPUP_MENU")) continue;
        }
        var maximized = false;
        var minimized = false;
        if (getProp(dpy, w, "_NET_WM_STATE", XA_ATOM)) |s| {
            defer s.free();
            const states = s.longs();
            if (hasAtom(states, dpy, "_NET_WM_STATE_SKIP_TASKBAR")) continue;
            minimized = hasAtom(states, dpy, "_NET_WM_STATE_HIDDEN");
            maximized = hasAtom(states, dpy, "_NET_WM_STATE_MAXIMIZED_VERT") and hasAtom(states, dpy, "_NET_WM_STATE_MAXIMIZED_HORZ");
        }

        const title = readText(allocator, dpy, w) catch continue;
        errdefer allocator.free(title);
        const app_id = readClass(allocator, dpy, w) catch {
            allocator.free(title);
            continue;
        };
        out.append(allocator, .{
            .id = w,
            .title = title,
            .app_id = app_id,
            .maximized = maximized,
            .minimized = minimized,
            .activated = @as(c_long, @intCast(w)) == active,
        }) catch {
            allocator.free(title);
            allocator.free(app_id);
            continue;
        };
    }
    return out.toOwnedSlice(allocator);
}

/// `_NET_WM_NAME` (UTF-8), else the legacy `WM_NAME`.
fn readText(allocator: std.mem.Allocator, dpy: *Display, w: Window) ![]u8 {
    const utf8 = atom(dpy, "UTF8_STRING");
    if (getProp(dpy, w, "_NET_WM_NAME", utf8)) |p| {
        defer p.free();
        return allocator.dupe(u8, p.data[0..p.count]);
    }
    if (getProp(dpy, w, "WM_NAME", 31)) |p| { // XA_STRING
        defer p.free();
        return allocator.dupe(u8, p.data[0..p.count]);
    }
    return allocator.dupe(u8, "");
}

/// The window class from `WM_CLASS` ("instance\0Class\0"), used to find the
/// application's desktop entry.
fn readClass(allocator: std.mem.Allocator, dpy: *Display, w: Window) ![]u8 {
    const p = getProp(dpy, w, "WM_CLASS", 31) orelse return allocator.dupe(u8, "");
    defer p.free();
    const bytes = p.data[0..p.count];
    var it = std.mem.splitScalar(u8, bytes, 0);
    const instance = it.next() orelse "";
    const class = it.next() orelse instance;
    return allocator.dupe(u8, if (class.len > 0) class else instance);
}

// ---- window actions -------------------------------------------------------------------

fn sendToRoot(message: [*:0]const u8, w: Window, data: [5]c_long) void {
    const dpy = xdisplay() orelse return;
    var event: Event = .{
        .client = .{
            .type = 33, // ClientMessage
            .serial = 0,
            .send_event = 1,
            .display = dpy,
            .window = w,
            .message_type = atom(dpy, message),
            .format = 32,
            .data = data,
        },
    };
    const root = XRootWindow(dpy, XDefaultScreen(dpy));
    _ = XSendEvent(dpy, root, 0, SubstructureRedirectMask | SubstructureNotifyMask, &event);
    _ = XFlush(dpy);
}

pub fn activate(w: c_ulong) void {
    sendToRoot("_NET_ACTIVE_WINDOW", w, .{ 2, 0, 0, 0, 0 });
}

pub fn close(w: c_ulong) void {
    sendToRoot("_NET_CLOSE_WINDOW", w, .{ 0, 2, 0, 0, 0 });
}

pub fn setMinimized(w: c_ulong, on: bool) void {
    if (on) return sendToRoot("WM_CHANGE_STATE", w, .{ 3, 0, 0, 0, 0 }); // IconicState
    activate(w);
}

pub fn setMaximized(w: c_ulong, on: bool) void {
    const dpy = xdisplay() orelse return;
    sendToRoot("_NET_WM_STATE", w, .{
        if (on) 1 else 0,
        @intCast(atom(dpy, "_NET_WM_STATE_MAXIMIZED_VERT")),
        @intCast(atom(dpy, "_NET_WM_STATE_MAXIMIZED_HORZ")),
        2,
        0,
    });
}
