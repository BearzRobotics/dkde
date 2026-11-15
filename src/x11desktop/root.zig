//! The X11 implementation of the shared desktop API (core.desktop), through
//! EWMH and ICCCM (ai/COMPOSITOR-SPEC.md section 6): the window list from
//! `_NET_CLIENT_LIST`, desktops from `_NET_NUMBER_OF_DESKTOPS` and friends,
//! requests as EWMH client messages to the window manager, and root-window
//! capture for screenshots. It works with any EWMH window manager.
//!
//! It opens its own XCB connection and watches it from the GLib main loop.

const std = @import("std");
pub const c = @import("c");
pub const idle = @import("idle.zig");
const outputs_mod = @import("outputs.zig");
const glib = @import("glib2");
const core = @import("core");

const desktop = core.desktop;
const log = std.log.scoped(.x11desktop);

const Atom = enum {
    _NET_CLIENT_LIST,
    _NET_ACTIVE_WINDOW,
    _NET_NUMBER_OF_DESKTOPS,
    _NET_CURRENT_DESKTOP,
    _NET_DESKTOP_NAMES,
    _NET_SUPPORTING_WM_CHECK,
    _NET_WM_NAME,
    _NET_WM_STATE,
    _NET_WM_STATE_HIDDEN,
    _NET_WM_STATE_FULLSCREEN,
    _NET_WM_STATE_MAXIMIZED_VERT,
    _NET_WM_STATE_MAXIMIZED_HORZ,
    _NET_WM_STATE_SKIP_TASKBAR,
    _NET_WM_DESKTOP,
    _NET_CLOSE_WINDOW,
    WM_CHANGE_STATE,
    WM_CLASS,
    UTF8_STRING,
};

const Item = struct {
    win: desktop.Window,
    owner: *X11,
    id: c.xcb_window_t,
    title_buf: []u8 = &.{},
    app_buf: []u8 = &.{},
};

pub const X11 = struct {
    allocator: std.mem.Allocator,
    conn: *c.xcb_connection_t,
    root: c.xcb_window_t,
    screen: *c.xcb_screen_t,
    atoms: [std.enums.values(Atom).len]c.xcb_atom_t = undefined,
    items: std.ArrayList(*Item) = .empty,
    /// `items` as the neutral API sees it, in the window manager's order.
    windows: std.ArrayList(*desktop.Window) = .empty,
    ws: std.ArrayList(*desktop.Workspace) = .empty,
    ws_names: std.ArrayList([]u8) = .empty,
    has_wm: bool = false,
    outputs: outputs_mod.Outputs,
    on_outputs: ?*const fn (*anyopaque) void = null,
    source: c_uint = 0,
    on_windows: *const fn (*anyopaque) void,
    on_workspaces: *const fn (*anyopaque) void,
    data: *anyopaque,

    const vtable: desktop.VTable = .{
        .capabilities = capabilities,
        .windows = windowList,
        .workspaces = workspaceList,
        .activate_workspace = activateWorkspace,
        .outputs = outputList,
        .configure_outputs = configureOutputs,
        .capture = captureOf,
        .destroy = destroy,
    };

    const window_ops: desktop.WindowOps = .{
        .activate = opActivate,
        .set_minimized = opMinimized,
        .set_maximized = opMaximized,
        .close = opClose,
    };

    /// Connects to $DISPLAY. Returns an empty Desktop when there is no X
    /// server or no EWMH window manager on it.
    pub fn create(allocator: std.mem.Allocator, on_windows: *const fn (*anyopaque) void, on_workspaces: *const fn (*anyopaque) void, data: *anyopaque, on_outputs: ?*const fn (*anyopaque) void) desktop.Desktop {
        var num: c_int = 0;
        const conn = c.xcb_connect(null, &num) orelse return .{};
        if (c.xcb_connection_has_error(conn) != 0) {
            c.xcb_disconnect(conn);
            return .{};
        }
        var it = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn));
        var i: c_int = 0;
        while (i < num) : (i += 1) c.xcb_screen_next(&it);

        const self = allocator.create(X11) catch {
            c.xcb_disconnect(conn);
            return .{};
        };
        self.* = .{ .allocator = allocator, .conn = conn, .root = it.data.*.root, .screen = it.data, .on_windows = on_windows, .on_workspaces = on_workspaces, .data = data, .on_outputs = on_outputs, .outputs = outputs_mod.Outputs.init(allocator, conn, it.data.*.root) };
        self.internAtoms();
        self.has_wm = self.wmPresent();
        // Property changes on the root tell us everything about the desktop.
        _ = c.xcb_change_window_attributes(conn, self.root, c.XCB_CW_EVENT_MASK, &[_]u32{c.XCB_EVENT_MASK_PROPERTY_CHANGE});
        self.refreshWorkspaces();
        self.refreshWindows();
        _ = c.xcb_flush(conn);

        const channel = glib.IOChannel.unixNew(c.xcb_get_file_descriptor(conn));
        self.source = glib.ioAddWatch(channel, .{ .in = true, .hup = true, .err = true }, onReadable, self);
        return .{ .backend = .{ .kind = .x11, .ptr = self, .vtable = &vtable } };
    }

    fn a(self: *const X11, name: Atom) c.xcb_atom_t {
        return self.atoms[@intFromEnum(name)];
    }

    fn internAtoms(self: *X11) void {
        var cookies: [std.enums.values(Atom).len]c.xcb_intern_atom_cookie_t = undefined;
        inline for (std.enums.values(Atom), 0..) |name, i| cookies[i] = c.xcb_intern_atom(self.conn, 0, @tagName(name).len, @tagName(name).ptr);
        for (cookies, 0..) |ck, i| {
            const r = c.xcb_intern_atom_reply(self.conn, ck, null);
            self.atoms[i] = if (r) |reply| blk: {
                const v = reply.*.atom;
                std.c.free(reply);
                break :blk v;
            } else 0;
        }
    }

    fn getProp(self: *X11, win: c.xcb_window_t, prop: Atom, typ: c.xcb_atom_t, words: u32) ?*c.xcb_get_property_reply_t {
        return c.xcb_get_property_reply(self.conn, c.xcb_get_property(self.conn, 0, win, self.a(prop), typ, 0, words), null);
    }

    fn u32s(reply: *c.xcb_get_property_reply_t) []const u32 {
        const len: usize = @intCast(c.xcb_get_property_value_length(reply));
        const ptr: [*]const u32 = @ptrCast(@alignCast(c.xcb_get_property_value(reply)));
        return ptr[0 .. len / 4];
    }

    fn bytes(reply: *c.xcb_get_property_reply_t) []const u8 {
        const len: usize = @intCast(c.xcb_get_property_value_length(reply));
        const ptr: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply));
        return ptr[0..len];
    }

    /// Whether a window manager has announced itself (EWMH supporting check).
    fn wmPresent(self: *X11) bool {
        const r = self.getProp(self.root, ._NET_SUPPORTING_WM_CHECK, c.XCB_ATOM_WINDOW, 1) orelse return false;
        defer std.c.free(r);
        return u32s(r).len > 0;
    }

    // ---- reading the desktop -------------------------------------------------------------------------------

    fn refreshWorkspaces(self: *X11) void {
        var count: usize = 0;
        if (self.getProp(self.root, ._NET_NUMBER_OF_DESKTOPS, c.XCB_ATOM_CARDINAL, 1)) |r| {
            defer std.c.free(r);
            if (u32s(r).len > 0) count = u32s(r)[0];
        }
        var current: usize = 0;
        if (self.getProp(self.root, ._NET_CURRENT_DESKTOP, c.XCB_ATOM_CARDINAL, 1)) |r| {
            defer std.c.free(r);
            if (u32s(r).len > 0) current = u32s(r)[0];
        }
        for (self.ws_names.items) |n| self.allocator.free(n);
        self.ws_names.clearRetainingCapacity();
        if (self.getProp(self.root, ._NET_DESKTOP_NAMES, self.a(.UTF8_STRING), 1024)) |r| {
            defer std.c.free(r);
            var parts = std.mem.splitScalar(u8, bytes(r), 0);
            while (parts.next()) |p| {
                if (parts.peek() == null and p.len == 0) break;
                const copy = self.allocator.dupe(u8, p) catch break;
                self.ws_names.append(self.allocator, copy) catch self.allocator.free(copy);
            }
        }
        while (self.ws.items.len > count) self.allocator.destroy(self.ws.pop().?);
        while (self.ws.items.len < count) {
            const w = self.allocator.create(desktop.Workspace) catch break;
            w.* = .{};
            self.ws.append(self.allocator, w) catch {
                self.allocator.destroy(w);
                break;
            };
        }
        for (self.ws.items, 0..) |w, i| {
            w.active = i == current;
            w.name = if (i < self.ws_names.items.len) self.ws_names.items[i] else "";
        }
    }

    fn refreshWindows(self: *X11) void {
        var ids: []const u32 = &.{};
        const reply = self.getProp(self.root, ._NET_CLIENT_LIST, c.XCB_ATOM_WINDOW, 4096);
        defer if (reply) |r| std.c.free(r);
        if (reply) |r| ids = u32s(r);

        // Windows that left.
        var i: usize = 0;
        while (i < self.items.items.len) {
            const it = self.items.items[i];
            if (std.mem.indexOfScalar(u32, ids, it.id) == null) {
                self.freeItem(self.items.orderedRemove(i));
            } else i += 1;
        }
        // Windows that came, and the order the manager gives.
        self.windows.clearRetainingCapacity();
        for (ids) |id| {
            var item: ?*Item = null;
            for (self.items.items) |it| if (it.id == id) {
                item = it;
            };
            if (item == null) {
                const it = self.allocator.create(Item) catch continue;
                it.* = .{ .win = .{ .ops = &window_ops }, .owner = self, .id = id };
                self.items.append(self.allocator, it) catch {
                    self.allocator.destroy(it);
                    continue;
                };
                _ = c.xcb_change_window_attributes(self.conn, id, c.XCB_CW_EVENT_MASK, &[_]u32{c.XCB_EVENT_MASK_PROPERTY_CHANGE});
                item = it;
            }
            self.refreshWindow(item.?);
            if (!self.skipTaskbar(item.?)) self.windows.append(self.allocator, &item.?.win) catch {};
        }
        self.refreshActive();
    }

    fn skipTaskbar(self: *X11, it: *Item) bool {
        const r = self.getProp(it.id, ._NET_WM_STATE, c.XCB_ATOM_ATOM, 16) orelse return false;
        defer std.c.free(r);
        return std.mem.indexOfScalar(u32, u32s(r), self.a(._NET_WM_STATE_SKIP_TASKBAR)) != null;
    }

    fn refreshWindow(self: *X11, it: *Item) void {
        // Title: the UTF-8 name, or the legacy one.
        var title = self.getProp(it.id, ._NET_WM_NAME, self.a(.UTF8_STRING), 256);
        if (title == null or c.xcb_get_property_value_length(title.?) == 0) {
            if (title) |t| std.c.free(t);
            title = c.xcb_get_property_reply(self.conn, c.xcb_get_property(self.conn, 0, it.id, c.XCB_ATOM_WM_NAME, c.XCB_GET_PROPERTY_TYPE_ANY, 0, 256), null);
        }
        if (title) |t| {
            defer std.c.free(t);
            replace(self.allocator, &it.title_buf, bytes(t));
            it.win.title = it.title_buf;
        }
        // Application: WM_CLASS is "instance\0class\0"; the class names it.
        if (self.getProp(it.id, .WM_CLASS, c.XCB_ATOM_STRING, 128)) |r| {
            defer std.c.free(r);
            const text = bytes(r);
            var parts = std.mem.splitScalar(u8, text, 0);
            _ = parts.next();
            const class = parts.next() orelse "";
            replace(self.allocator, &it.app_buf, class);
            it.win.app_id = it.app_buf;
        }
        it.win.minimized = false;
        it.win.maximized = false;
        it.win.fullscreen = false;
        if (self.getProp(it.id, ._NET_WM_STATE, c.XCB_ATOM_ATOM, 16)) |r| {
            defer std.c.free(r);
            for (u32s(r)) |s| {
                if (s == self.a(._NET_WM_STATE_HIDDEN)) it.win.minimized = true;
                if (s == self.a(._NET_WM_STATE_FULLSCREEN)) it.win.fullscreen = true;
                if (s == self.a(._NET_WM_STATE_MAXIMIZED_VERT)) it.win.maximized = true;
            }
        }
        it.win.workspace = null;
        if (self.getProp(it.id, ._NET_WM_DESKTOP, c.XCB_ATOM_CARDINAL, 1)) |r| {
            defer std.c.free(r);
            const v = u32s(r);
            if (v.len > 0 and v[0] != 0xffffffff) it.win.workspace = v[0];
        }
        it.win.ready = true;
    }

    fn refreshActive(self: *X11) void {
        var active: u32 = 0;
        if (self.getProp(self.root, ._NET_ACTIVE_WINDOW, c.XCB_ATOM_WINDOW, 1)) |r| {
            defer std.c.free(r);
            if (u32s(r).len > 0) active = u32s(r)[0];
        }
        for (self.items.items) |it| it.win.activated = it.id == active;
    }

    fn freeItem(self: *X11, it: *Item) void {
        self.allocator.free(it.title_buf);
        self.allocator.free(it.app_buf);
        self.allocator.destroy(it);
    }

    // ---- events ------------------------------------------------------------------------------------------------

    fn onReadable(_: *glib.IOChannel, cond: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *X11 = @ptrCast(@alignCast(data.?));
        if (cond.hup or cond.err or c.xcb_connection_has_error(self.conn) != 0) {
            log.warn("lost the connection to the X server", .{});
            self.source = 0;
            return 0;
        }
        var windows_changed = false;
        var workspaces_changed = false;
        var outputs_changed = false;
        while (c.xcb_poll_for_event(self.conn)) |ev| {
            defer std.c.free(ev);
            if (self.outputs.isEvent(ev.*.response_type)) {
                self.outputs.refresh();
                outputs_changed = true;
                continue;
            }
            if (ev.*.response_type & 0x7f != c.XCB_PROPERTY_NOTIFY) continue;
            const p: *const c.xcb_property_notify_event_t = @ptrCast(ev);
            if (p.window == self.root) {
                if (p.atom == self.a(._NET_CLIENT_LIST)) {
                    self.refreshWindows();
                    windows_changed = true;
                } else if (p.atom == self.a(._NET_ACTIVE_WINDOW)) {
                    self.refreshActive();
                    windows_changed = true;
                } else if (p.atom == self.a(._NET_CURRENT_DESKTOP) or p.atom == self.a(._NET_NUMBER_OF_DESKTOPS) or p.atom == self.a(._NET_DESKTOP_NAMES)) {
                    self.refreshWorkspaces();
                    workspaces_changed = true;
                } else if (p.atom == self.a(._NET_SUPPORTING_WM_CHECK)) {
                    self.has_wm = self.wmPresent();
                    windows_changed = true;
                }
                continue;
            }
            for (self.items.items) |it| if (it.id == p.window) {
                self.refreshWindow(it);
                windows_changed = true;
            };
        }
        if (windows_changed) self.on_windows(self.data);
        if (workspaces_changed) self.on_workspaces(self.data);
        if (outputs_changed) if (self.on_outputs) |f| f(self.data);
        return 1;
    }

    // ---- requests, as EWMH client messages to the window manager -----------------------------------------

    fn sendToRoot(self: *X11, win: c.xcb_window_t, typ: Atom, d: [5]u32) void {
        var ev: c.xcb_client_message_event_t = std.mem.zeroes(c.xcb_client_message_event_t);
        ev.response_type = c.XCB_CLIENT_MESSAGE;
        ev.format = 32;
        ev.window = win;
        ev.type = self.a(typ);
        for (d, 0..) |v, i| ev.data.data32[i] = v;
        _ = c.xcb_send_event(self.conn, 0, self.root, c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY, @ptrCast(&ev));
        _ = c.xcb_flush(self.conn);
    }

    fn itemOf(w: *desktop.Window) *Item {
        return @fieldParentPtr("win", w);
    }

    fn opActivate(w: *desktop.Window) void {
        const it = itemOf(w);
        // Source 2: a pager or taskbar acting for the user.
        it.owner.sendToRoot(it.id, ._NET_ACTIVE_WINDOW, .{ 2, 0, 0, 0, 0 });
    }

    fn opMinimized(w: *desktop.Window, minimized: bool) void {
        const it = itemOf(w);
        // Iconify is ICCCM's WM_CHANGE_STATE; bringing it back is activation.
        if (minimized) it.owner.sendToRoot(it.id, .WM_CHANGE_STATE, .{ 3, 0, 0, 0, 0 }) else opActivate(w);
    }

    fn opMaximized(w: *desktop.Window, maximized: bool) void {
        const it = itemOf(w);
        const s = it.owner;
        s.sendToRoot(it.id, ._NET_WM_STATE, .{ @intFromBool(maximized), s.a(._NET_WM_STATE_MAXIMIZED_VERT), s.a(._NET_WM_STATE_MAXIMIZED_HORZ), 2, 0 });
    }

    fn opClose(w: *desktop.Window) void {
        const it = itemOf(w);
        it.owner.sendToRoot(it.id, ._NET_CLOSE_WINDOW, .{ 0, 2, 0, 0, 0 });
    }

    // ---- the vtable ---------------------------------------------------------------------------------------------

    fn of(p: *anyopaque) *X11 {
        return @ptrCast(@alignCast(p));
    }

    fn capabilities(p: *anyopaque) desktop.Capabilities {
        const self = of(p);
        var caps = desktop.Capabilities.empty;
        // Capture works without a window manager; the rest is the manager's.
        caps.insert(.screenshot_output);
        if (self.outputs.present) {
            caps.insert(.outputs);
            caps.insert(.output_config);
        }
        if (self.has_wm) {
            for ([_]desktop.Capability{ .window_list, .window_activate, .window_minimize, .window_maximize, .window_close, .window_workspace, .workspaces, .workspace_switch }) |cap| caps.insert(cap);
        }
        return caps;
    }

    fn outputList(p: *anyopaque) []const desktop.Output {
        return of(p).outputs.list.items;
    }

    fn configureOutputs(p: *anyopaque, edits: []const desktop.OutputEdit, done: desktop.ConfigDone, ctx: ?*anyopaque) void {
        done(ctx, of(p).outputs.configure(edits));
    }

    fn windowList(p: *anyopaque) []const *desktop.Window {
        return of(p).windows.items;
    }

    fn workspaceList(p: *anyopaque) []const *const desktop.Workspace {
        const self = of(p);
        // Same layout in memory: a slice of mutable pointers is a slice of const ones.
        return @ptrCast(self.ws.items);
    }

    fn activateWorkspace(p: *anyopaque, index: usize) void {
        const self = of(p);
        self.sendToRoot(self.root, ._NET_CURRENT_DESKTOP, .{ @intCast(index), 0, 0, 0, 0 });
    }

    /// The whole screen as RGBA. X11 gives one root window for all outputs.
    fn captureOf(p: *anyopaque, allocator: std.mem.Allocator, target: desktop.CaptureTarget, done: desktop.CaptureDone, ctx: ?*anyopaque) void {
        const self = of(p);
        switch (target) {
            .window => return done(ctx, error.Unsupported),
            .primary, .output => {},
        }
        const w = self.screen.width_in_pixels;
        const h = self.screen.height_in_pixels;
        const reply = c.xcb_get_image_reply(self.conn, c.xcb_get_image(self.conn, c.XCB_IMAGE_FORMAT_Z_PIXMAP, self.root, 0, 0, w, h, 0xffffffff), null) orelse return done(ctx, error.CaptureFailed);
        defer std.c.free(reply);
        // 24-bit depth arrives as 32 bits per pixel, B G R X.
        if (reply.*.depth != 24 and reply.*.depth != 32) return done(ctx, error.BadFormat);
        const len: usize = @intCast(c.xcb_get_image_data_length(reply));
        if (len < @as(usize, w) * h * 4) return done(ctx, error.BadFormat);
        const src: [*]const u8 = c.xcb_get_image_data(reply);
        const rgba = allocator.alloc(u8, @as(usize, w) * h * 4) catch return done(ctx, error.OutOfMemory);
        core.pixels.toRgba(rgba, src[0..len], w, h, @as(usize, w) * 4, .bgra, false);
        done(ctx, .{ .width = w, .height = h, .rgba = rgba });
    }

    fn destroy(p: *anyopaque) void {
        const self = of(p);
        if (self.source != 0) _ = glib.Source.remove(self.source);
        for (self.items.items) |it| self.freeItem(it);
        self.items.deinit(self.allocator);
        self.windows.deinit(self.allocator);
        self.outputs.deinit();
        for (self.ws.items) |w| self.allocator.destroy(w);
        self.ws.deinit(self.allocator);
        for (self.ws_names.items) |n| self.allocator.free(n);
        self.ws_names.deinit(self.allocator);
        c.xcb_disconnect(self.conn);
        self.allocator.destroy(self);
    }
};

fn replace(allocator: std.mem.Allocator, field: *[]u8, value: []const u8) void {
    const copy = allocator.dupe(u8, value) catch return;
    allocator.free(field.*);
    field.* = copy;
}

extern fn g_main_context_iteration(ctx: ?*anyopaque, may_block: c_int) c_int;

const Probe = struct {
    window_calls: usize = 0,
    workspace_calls: usize = 0,
    image: ?desktop.Error!desktop.Image = null,
    config_ok: ?bool = null,

    fn onConfig(ctx: ?*anyopaque, ok: bool) void {
        const self: *Probe = @ptrCast(@alignCast(ctx.?));
        self.config_ok = ok;
    }
    fn onWindows(p: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(p));
        self.window_calls += 1;
    }
    fn onWorkspaces(p: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(p));
        self.workspace_calls += 1;
    }
    fn onCapture(ctx: ?*anyopaque, result: desktop.Error!desktop.Image) void {
        const self: *Probe = @ptrCast(@alignCast(ctx.?));
        self.image = result;
    }
};

fn pump(ms: usize) void {
    var i: usize = 0;
    while (i < ms / 20) : (i += 1) {
        while (g_main_context_iteration(null, 0) != 0) {}
        std.testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
}

// Needs an X server with dkde-wm (or another EWMH window manager) and at least
// one window open, and DKDE_X11_TEST=1:  Xvfb :77 & DISPLAY=:77 dkde-wm & xterm &
test "against a live X server" {
    if (std.c.getenv("DKDE_X11_TEST") == null) return error.SkipZigTest;
    const a = std.testing.allocator;
    var probe: Probe = .{};
    var d = X11.create(a, Probe.onWindows, Probe.onWorkspaces, &probe, null);
    defer d.destroy();
    try std.testing.expectEqual(desktop.BackendKind.x11, d.kind());
    try std.testing.expect(d.has(.window_list) and d.has(.workspaces));
    try std.testing.expectEqual(@as(usize, 4), d.workspaces().len);
    try std.testing.expectEqual(@as(?usize, 0), d.activeWorkspace());
    try std.testing.expect(d.windows().len >= 1);
    const w = d.windows()[0];
    try std.testing.expect(w.title.len > 0 and w.app_id.len > 0);

    // Switching desktops comes back as a change.
    d.activateWorkspace(2);
    pump(500);
    try std.testing.expectEqual(@as(?usize, 2), d.activeWorkspace());
    try std.testing.expect(probe.workspace_calls >= 1);
    d.activateWorkspace(0);
    pump(500);

    // Minimizing and restoring.
    w.setMinimized(true);
    pump(500);
    try std.testing.expect(w.minimized);
    w.activate();
    pump(500);
    try std.testing.expect(!w.minimized and w.activated);

    // Outputs (RandR): the screen is listed with its modes, and re-applying its own mode is accepted.
    try std.testing.expect(d.has(.outputs));
    try std.testing.expect(d.outputs().len >= 1);
    const o = d.outputs()[0];
    try std.testing.expect(o.enabled and o.width > 0 and o.modes.len >= 1);
    var cur: ?desktop.Mode = null;
    for (o.modes) |m| if (m.current) {
        cur = m;
    };
    try std.testing.expect(cur != null);
    probe.config_ok = null;
    d.configureOutput(o.id, .{ .mode = cur.? }, Probe.onConfig, &probe);
    try std.testing.expectEqual(@as(?bool, true), probe.config_ok);
    // Switching off the only screen is refused.
    probe.config_ok = null;
    d.configureOutput(d.outputs()[0].id, .{ .enabled = false }, Probe.onConfig, &probe);
    try std.testing.expectEqual(@as(?bool, false), probe.config_ok);

    // The screenshot.
    d.capture(a, .primary, Probe.onCapture, &probe);
    const img = try probe.image.?;
    defer img.deinit(a);
    try std.testing.expect(img.width > 0 and img.rgba.len == @as(usize, img.width) * img.height * 4);

    // Closing the window removes it.
    const before = d.windows().len;
    w.close();
    pump(1500);
    try std.testing.expect(d.windows().len < before);
}
