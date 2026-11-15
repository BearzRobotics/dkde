//! dkde-wm: DKDE's own X11 window manager (experimental; ai/COMPOSITOR-SPEC.md
//! section 5). Plain XCB, no compositing. Windows are not reparented and get
//! no frame: DKDE's programs draw their own title bars, and the layout,
//! shortcuts and settings are the compositor's (shared source, compositor.toml).
//!
//! Standards: ICCCM basics (WM_PROTOCOLS delete and take-focus, WM_STATE,
//! synthetic ConfigureNotify) and EWMH (supporting WM check, client lists,
//! active window, desktops, work area, window state and type, struts).

const std = @import("std");
const c = @import("c");
const shared = @import("shared");

const layout = shared.layout;
const keys = shared.keys;
const config = shared.config;

const version = "0.3.0";
const gpa = std.heap.c_allocator;

// ---- atoms ----------------------------------------------------------------------------------------------------

const Atom = enum {
    WM_PROTOCOLS,
    WM_DELETE_WINDOW,
    WM_TAKE_FOCUS,
    WM_STATE,
    WM_CHANGE_STATE,
    WM_TRANSIENT_FOR,
    UTF8_STRING,
    _NET_SUPPORTED,
    _NET_SUPPORTING_WM_CHECK,
    _NET_WM_NAME,
    _NET_CLIENT_LIST,
    _NET_CLIENT_LIST_STACKING,
    _NET_ACTIVE_WINDOW,
    _NET_NUMBER_OF_DESKTOPS,
    _NET_CURRENT_DESKTOP,
    _NET_DESKTOP_NAMES,
    _NET_DESKTOP_GEOMETRY,
    _NET_DESKTOP_VIEWPORT,
    _NET_WORKAREA,
    _NET_WM_DESKTOP,
    _NET_WM_STATE,
    _NET_WM_STATE_FULLSCREEN,
    _NET_WM_STATE_MAXIMIZED_VERT,
    _NET_WM_STATE_MAXIMIZED_HORZ,
    _NET_WM_STATE_HIDDEN,
    _NET_WM_STATE_DEMANDS_ATTENTION,
    _NET_WM_STATE_SKIP_TASKBAR,
    _NET_WM_STATE_ABOVE,
    _NET_WM_WINDOW_TYPE,
    _NET_WM_WINDOW_TYPE_DOCK,
    _NET_WM_WINDOW_TYPE_DESKTOP,
    _NET_WM_WINDOW_TYPE_DIALOG,
    _NET_WM_WINDOW_TYPE_UTILITY,
    _NET_WM_WINDOW_TYPE_SPLASH,
    _NET_WM_WINDOW_TYPE_TOOLBAR,
    _NET_WM_WINDOW_TYPE_MENU,
    _NET_WM_WINDOW_TYPE_DROPDOWN_MENU,
    _NET_WM_WINDOW_TYPE_POPUP_MENU,
    _NET_WM_WINDOW_TYPE_TOOLTIP,
    _NET_WM_WINDOW_TYPE_NOTIFICATION,
    _NET_WM_WINDOW_TYPE_COMBO,
    _NET_WM_WINDOW_TYPE_DND,
    _NET_WM_STRUT,
    _NET_WM_STRUT_PARTIAL,
    _NET_CLOSE_WINDOW,
    _NET_FRAME_EXTENTS,
};

var atoms: [std.enums.values(Atom).len]c.xcb_atom_t = undefined;

fn atom(a: Atom) c.xcb_atom_t {
    return atoms[@intFromEnum(a)];
}

// ---- state ----------------------------------------------------------------------------------------------------

const Kind = enum { normal, dock, desktop, unmanaged };

const Client = struct {
    win: c.xcb_window_t,
    kind: Kind = .normal,
    /// The floating geometry (kept while tiled, so toggling back restores it).
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 640,
    h: i32 = 480,
    ws: u8 = 0,
    floating: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    minimized: bool = false,
    /// Asked for by the client and kept in its state (a pop-up window that is not a task).
    skip_taskbar: bool = false,
    above: bool = false,
    mapped: bool = false,
    /// UnmapNotify events caused by our own unmap calls, which are not the client leaving.
    ignore_unmap: u8 = 0,
    takes_delete: bool = false,
    takes_focus: bool = false,
    title: []u8 = &.{},
    /// Struts of a dock: left, right, top, bottom.
    strut: [4]u32 = .{ 0, 0, 0, 0 },
};

var conn: *c.xcb_connection_t = undefined;
var screen: *c.xcb_screen_t = undefined;
var root: c.xcb_window_t = 0;
var check_window: c.xcb_window_t = 0;

var clients: std.ArrayList(*Client) = .empty;
/// Bottom to top.
var stack: std.ArrayList(*Client) = .empty;
var focused: ?*Client = null;

var cfg: config.Config = .{};
var ws_count: usize = 4;
var ws_current: u8 = 0;
var ws_policy: [9]layout.Policy = @splat(.floating);
var cascade_index: usize = 0;
var running = true;

const Binding = struct { mods: u8, sym: u32, keycode: u8, action: keys.Action };
var bindings: std.ArrayList(Binding) = .empty;
var super_pending = false;

const Drag = struct {
    client: *Client,
    resize: bool,
    start_x: i32,
    start_y: i32,
    orig: layout.Rect,
    /// -1, 0 or 1 per axis: which edge a resize pulls (0 moves the opposite one).
    sx: i32 = 1,
    sy: i32 = 1,
};
var drag: ?Drag = null;

const log_prefix = "dkde-wm: ";

fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(log_prefix ++ fmt ++ "\n", args);
}

// ---- small helpers --------------------------------------------------------------------------------------------

fn findClient(win: c.xcb_window_t) ?*Client {
    for (clients.items) |cl| if (cl.win == win) return cl;
    return null;
}

fn findAny(win: c.xcb_window_t) ?*Client {
    return findClient(win);
}

fn visible(cl: *const Client) bool {
    return cl.ws == ws_current and !cl.minimized;
}

fn getProp(win: c.xcb_window_t, prop: c.xcb_atom_t, typ: c.xcb_atom_t, words: u32) ?*c.xcb_get_property_reply_t {
    const cookie = c.xcb_get_property(conn, 0, win, prop, typ, 0, words);
    return c.xcb_get_property_reply(conn, cookie, null);
}

fn propU32(reply: *c.xcb_get_property_reply_t) []const u32 {
    const len: usize = @intCast(c.xcb_get_property_value_length(reply));
    const ptr: [*]const u32 = @ptrCast(@alignCast(c.xcb_get_property_value(reply)));
    return ptr[0 .. len / 4];
}

fn setU32(win: c.xcb_window_t, prop: Atom, typ: c.xcb_atom_t, data: []const u32) void {
    _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, win, atom(prop), typ, 32, @intCast(data.len), data.ptr);
}

fn setWindows(win: c.xcb_window_t, prop: Atom, list: []const u32) void {
    setU32(win, prop, c.XCB_ATOM_WINDOW, list);
}

fn setCardinal(win: c.xcb_window_t, prop: Atom, list: []const u32) void {
    setU32(win, prop, c.XCB_ATOM_CARDINAL, list);
}

/// The root window's size, kept up to date when the screen changes (XRandR).
var screen_w: i32 = 0;
var screen_h: i32 = 0;

fn screenRect() layout.Rect {
    return .{ .x = 0, .y = 0, .w = screen_w, .h = screen_h };
}

/// The screen less what panels reserve (their struts).
fn workArea() layout.Rect {
    var edge: [4]u32 = .{ 0, 0, 0, 0 };
    for (clients.items) |cl| {
        if (cl.kind != .dock) continue;
        for (0..4) |i| edge[i] = @max(edge[i], cl.strut[i]);
    }
    return areaAfterStruts(screenRect(), edge);
}

fn areaAfterStruts(screen_rect: layout.Rect, edge: [4]u32) layout.Rect {
    const l: i32 = @intCast(@min(edge[0], @as(u32, @intCast(screen_rect.w)) / 2));
    const r: i32 = @intCast(@min(edge[1], @as(u32, @intCast(screen_rect.w)) / 2));
    const t: i32 = @intCast(@min(edge[2], @as(u32, @intCast(screen_rect.h)) / 2));
    const b: i32 = @intCast(@min(edge[3], @as(u32, @intCast(screen_rect.h)) / 2));
    return .{ .x = screen_rect.x + l, .y = screen_rect.y + t, .w = screen_rect.w - l - r, .h = screen_rect.h - t - b };
}

test "struts shrink the work area, and never take more than half" {
    const s = layout.Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try std.testing.expectEqual(layout.Rect{ .x = 0, .y = 0, .w = 1000, .h = 570 }, areaAfterStruts(s, .{ 0, 0, 0, 30 }));
    try std.testing.expectEqual(layout.Rect{ .x = 40, .y = 20, .w = 940, .h = 580 }, areaAfterStruts(s, .{ 40, 20, 20, 0 }));
    try std.testing.expectEqual(@as(i32, 0), areaAfterStruts(s, .{ 9999, 9999, 0, 0 }).w);
}

fn clampSize(v: i32) u32 {
    return @intCast(@max(v, 1));
}

fn configure(win: c.xcb_window_t, r: layout.Rect) void {
    var values = [_]u32{ @bitCast(r.x), @bitCast(r.y), clampSize(r.w), clampSize(r.h), 0 };
    _ = c.xcb_configure_window(conn, win, c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y | c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT | c.XCB_CONFIG_WINDOW_BORDER_WIDTH, &values);
}

/// Tells a client where it is, as ICCCM asks when we do not move it as it requested.
fn sendConfigureNotify(cl: *const Client, r: layout.Rect) void {
    var ev: c.xcb_configure_notify_event_t = std.mem.zeroes(c.xcb_configure_notify_event_t);
    ev.response_type = c.XCB_CONFIGURE_NOTIFY;
    ev.event = cl.win;
    ev.window = cl.win;
    ev.x = @intCast(r.x);
    ev.y = @intCast(r.y);
    ev.width = @intCast(clampSize(r.w));
    ev.height = @intCast(clampSize(r.h));
    _ = c.xcb_send_event(conn, 0, cl.win, c.XCB_EVENT_MASK_STRUCTURE_NOTIFY, @ptrCast(&ev));
}

fn sendClientMessage(win: c.xcb_window_t, typ: Atom, data0: u32, data1: u32) void {
    var ev: c.xcb_client_message_event_t = std.mem.zeroes(c.xcb_client_message_event_t);
    ev.response_type = c.XCB_CLIENT_MESSAGE;
    ev.format = 32;
    ev.window = win;
    ev.type = atom(typ);
    ev.data.data32[0] = data0;
    ev.data.data32[1] = data1;
    _ = c.xcb_send_event(conn, 0, win, c.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&ev));
}

// ---- publishing what EWMH clients read ----------------------------------------------------------------------

fn publishClientLists() void {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    for (clients.items) |cl| {
        if (cl.kind == .normal) list.append(gpa, cl.win) catch {};
    }
    setWindows(root, ._NET_CLIENT_LIST, list.items);
    list.clearRetainingCapacity();
    for (stack.items) |cl| {
        if (cl.kind == .normal) list.append(gpa, cl.win) catch {};
    }
    setWindows(root, ._NET_CLIENT_LIST_STACKING, list.items);
}

fn publishActive() void {
    const active: u32 = if (focused) |f| f.win else 0;
    setWindows(root, ._NET_ACTIVE_WINDOW, &.{active});
}

fn publishDesktops() void {
    setCardinal(root, ._NET_NUMBER_OF_DESKTOPS, &.{@intCast(ws_count)});
    setCardinal(root, ._NET_CURRENT_DESKTOP, &.{ws_current});
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    for (0..ws_count) |i| names.print(gpa, "{d}\x00", .{i + 1}) catch {};
    _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, root, atom(._NET_DESKTOP_NAMES), atom(.UTF8_STRING), 8, @intCast(names.items.len), names.items.ptr);
    const s = screenRect();
    setCardinal(root, ._NET_DESKTOP_GEOMETRY, &.{ @intCast(s.w), @intCast(s.h) });
    setCardinal(root, ._NET_DESKTOP_VIEWPORT, &.{ 0, 0 });
}

fn publishWorkArea() void {
    const a = workArea();
    var data: [36]u32 = undefined;
    for (0..9) |i| {
        data[i * 4 + 0] = @intCast(a.x);
        data[i * 4 + 1] = @intCast(a.y);
        data[i * 4 + 2] = @intCast(@max(a.w, 0));
        data[i * 4 + 3] = @intCast(@max(a.h, 0));
    }
    setCardinal(root, ._NET_WORKAREA, data[0 .. ws_count * 4]);
}

fn publishClientState(cl: *const Client) void {
    var state: [6]u32 = undefined;
    var n: usize = 0;
    if (cl.skip_taskbar) {
        state[n] = atom(._NET_WM_STATE_SKIP_TASKBAR);
        n += 1;
    }
    if (cl.above) {
        state[n] = atom(._NET_WM_STATE_ABOVE);
        n += 1;
    }
    if (cl.fullscreen) {
        state[n] = atom(._NET_WM_STATE_FULLSCREEN);
        n += 1;
    }
    if (cl.maximized) {
        state[n] = atom(._NET_WM_STATE_MAXIMIZED_VERT);
        state[n + 1] = atom(._NET_WM_STATE_MAXIMIZED_HORZ);
        n += 2;
    }
    if (cl.minimized) {
        state[n] = atom(._NET_WM_STATE_HIDDEN);
        n += 1;
    }
    _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, cl.win, atom(._NET_WM_STATE), c.XCB_ATOM_ATOM, 32, @intCast(n), &state);
    setCardinal(cl.win, ._NET_WM_DESKTOP, &.{cl.ws});
    // ICCCM WM_STATE: 1 normal, 3 iconic.
    const wm_state = [_]u32{ if (cl.minimized) 3 else 1, 0 };
    _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, cl.win, atom(.WM_STATE), atom(.WM_STATE), 32, 2, &wm_state);
}

// ---- layout ------------------------------------------------------------------------------------------------

fn tiledNow(cl: *const Client) bool {
    return cl.kind == .normal and visible(cl) and !cl.floating and !cl.maximized and !cl.fullscreen and ws_policy[cl.ws] == .tiling;
}

/// Places every window, shows those of this workspace and hides the rest.
fn arrange() void {
    const area = workArea();
    const full = screenRect();

    var cells: [128]layout.Rect = undefined;
    var tiled: [128]*Client = undefined;
    var n: usize = 0;
    for (clients.items) |cl| {
        if (n < tiled.len and tiledNow(cl)) {
            tiled[n] = cl;
            n += 1;
        }
    }
    layout.tile(area, n, cfg.options, &cells);

    for (clients.items) |cl| {
        const show = cl.kind == .dock or cl.kind == .desktop or visible(cl);
        if (show) {
            if (cl.kind == .normal) {
                var r: layout.Rect = .{ .x = cl.x, .y = cl.y, .w = cl.w, .h = cl.h };
                if (cl.fullscreen) {
                    r = full;
                } else if (cl.maximized) {
                    r = area;
                } else if (tiledNow(cl)) {
                    for (tiled[0..n], 0..) |t, i| if (t == cl) {
                        r = cells[i];
                    };
                }
                configure(cl.win, r);
                sendConfigureNotify(cl, r);
            }
            if (!cl.mapped) {
                _ = c.xcb_map_window(conn, cl.win);
                cl.mapped = true;
            }
        } else if (cl.mapped) {
            cl.ignore_unmap +|= 1;
            _ = c.xcb_unmap_window(conn, cl.win);
            cl.mapped = false;
        }
        if (cl.kind == .normal) publishClientState(cl);
    }
    restack();
    publishWorkArea();
    _ = c.xcb_flush(conn);
}

/// Applies `stack` to the server: windows in order, then panels on top unless something is fullscreen.
fn restack() void {
    var any_fullscreen = false;
    var below: u32 = 0;
    for (stack.items) |cl| {
        if (cl.kind != .normal or !visible(cl)) continue;
        if (cl.fullscreen) any_fullscreen = true;
        var values = [_]u32{ below, c.XCB_STACK_MODE_ABOVE };
        if (below == 0) {
            values[0] = c.XCB_STACK_MODE_ABOVE;
            _ = c.xcb_configure_window(conn, cl.win, c.XCB_CONFIG_WINDOW_STACK_MODE, &values);
        } else {
            _ = c.xcb_configure_window(conn, cl.win, c.XCB_CONFIG_WINDOW_SIBLING | c.XCB_CONFIG_WINDOW_STACK_MODE, &values);
        }
        below = cl.win;
    }
    // Windows that asked to stay on top (the Start menu) go above the rest.
    for (stack.items) |cl| {
        if (cl.kind == .normal and cl.above and visible(cl)) {
            const v = [_]u32{c.XCB_STACK_MODE_ABOVE};
            _ = c.xcb_configure_window(conn, cl.win, c.XCB_CONFIG_WINDOW_STACK_MODE, &v);
        }
    }
    for (clients.items) |cl| {
        if (cl.kind == .desktop) {
            const v = [_]u32{c.XCB_STACK_MODE_BELOW};
            _ = c.xcb_configure_window(conn, cl.win, c.XCB_CONFIG_WINDOW_STACK_MODE, &v);
        } else if (cl.kind == .dock and !any_fullscreen) {
            const v = [_]u32{c.XCB_STACK_MODE_ABOVE};
            _ = c.xcb_configure_window(conn, cl.win, c.XCB_CONFIG_WINDOW_STACK_MODE, &v);
        }
    }
    publishClientLists();
}

// ---- focus --------------------------------------------------------------------------------------------------

fn raiseInStack(cl: *Client) void {
    for (stack.items, 0..) |s, i| if (s == cl) {
        _ = stack.orderedRemove(i);
        break;
    };
    stack.append(gpa, cl) catch {};
}

fn focusClient(cl: ?*Client) void {
    const target = cl orelse {
        focused = null;
        _ = c.xcb_set_input_focus(conn, c.XCB_INPUT_FOCUS_POINTER_ROOT, root, c.XCB_CURRENT_TIME);
        publishActive();
        _ = c.xcb_flush(conn);
        return;
    };
    if (target.kind != .normal) return;
    focused = target;
    raiseInStack(target);
    _ = c.xcb_set_input_focus(conn, c.XCB_INPUT_FOCUS_POINTER_ROOT, target.win, c.XCB_CURRENT_TIME);
    if (target.takes_focus) sendClientMessage(target.win, .WM_PROTOCOLS, atom(.WM_TAKE_FOCUS), c.XCB_CURRENT_TIME);
    restack();
    publishActive();
    _ = c.xcb_flush(conn);
}

/// The window that should have the focus on this workspace: the topmost visible one.
fn topVisible() ?*Client {
    var i = stack.items.len;
    while (i > 0) : (i -= 1) {
        const cl = stack.items[i - 1];
        if (cl.kind == .normal and visible(cl)) return cl;
    }
    return null;
}

fn focusTop() void {
    focusClient(topVisible());
}

// ---- managing windows ---------------------------------------------------------------------------------------

fn windowKind(win: c.xcb_window_t) struct { kind: Kind, float: bool } {
    const reply = getProp(win, atom(._NET_WM_WINDOW_TYPE), c.XCB_ATOM_ATOM, 16) orelse return .{ .kind = .normal, .float = false };
    defer std.c.free(reply);
    for (propU32(reply)) |t| {
        if (t == atom(._NET_WM_WINDOW_TYPE_DOCK)) return .{ .kind = .dock, .float = false };
        if (t == atom(._NET_WM_WINDOW_TYPE_DESKTOP)) return .{ .kind = .desktop, .float = false };
        if (t == atom(._NET_WM_WINDOW_TYPE_MENU) or t == atom(._NET_WM_WINDOW_TYPE_DROPDOWN_MENU) or t == atom(._NET_WM_WINDOW_TYPE_POPUP_MENU) or
            t == atom(._NET_WM_WINDOW_TYPE_TOOLTIP) or t == atom(._NET_WM_WINDOW_TYPE_NOTIFICATION) or t == atom(._NET_WM_WINDOW_TYPE_COMBO) or
            t == atom(._NET_WM_WINDOW_TYPE_DND)) return .{ .kind = .unmanaged, .float = false };
        if (t == atom(._NET_WM_WINDOW_TYPE_DIALOG) or t == atom(._NET_WM_WINDOW_TYPE_UTILITY) or t == atom(._NET_WM_WINDOW_TYPE_SPLASH) or
            t == atom(._NET_WM_WINDOW_TYPE_TOOLBAR)) return .{ .kind = .normal, .float = true };
    }
    return .{ .kind = .normal, .float = false };
}

fn readTitle(cl: *Client) void {
    var reply = getProp(cl.win, atom(._NET_WM_NAME), atom(.UTF8_STRING), 256);
    if (reply == null or c.xcb_get_property_value_length(reply.?) == 0) {
        if (reply) |r| std.c.free(r);
        reply = getProp(cl.win, c.XCB_ATOM_WM_NAME, c.XCB_GET_PROPERTY_TYPE_ANY, 256);
    }
    const r = reply orelse return;
    defer std.c.free(r);
    const len: usize = @intCast(c.xcb_get_property_value_length(r));
    const ptr: [*]const u8 = @ptrCast(c.xcb_get_property_value(r));
    const copy = gpa.dupe(u8, ptr[0..len]) catch return;
    gpa.free(cl.title);
    cl.title = copy;
}

fn readProtocols(cl: *Client) void {
    cl.takes_delete = false;
    cl.takes_focus = false;
    const reply = getProp(cl.win, atom(.WM_PROTOCOLS), c.XCB_ATOM_ATOM, 32) orelse return;
    defer std.c.free(reply);
    for (propU32(reply)) |p| {
        if (p == atom(.WM_DELETE_WINDOW)) cl.takes_delete = true;
        if (p == atom(.WM_TAKE_FOCUS)) cl.takes_focus = true;
    }
}

fn readStruts(cl: *Client) void {
    cl.strut = .{ 0, 0, 0, 0 };
    if (getProp(cl.win, atom(._NET_WM_STRUT_PARTIAL), c.XCB_ATOM_CARDINAL, 12)) |r| {
        defer std.c.free(r);
        const v = propU32(r);
        if (v.len >= 4) {
            cl.strut = .{ v[0], v[1], v[2], v[3] };
            return;
        }
    }
    if (getProp(cl.win, atom(._NET_WM_STRUT), c.XCB_ATOM_CARDINAL, 4)) |r| {
        defer std.c.free(r);
        const v = propU32(r);
        if (v.len >= 4) cl.strut = .{ v[0], v[1], v[2], v[3] };
    }
}

fn grabClientButtons(win: c.xcb_window_t) void {
    // A click on a window focuses it; the click is then replayed to the window.
    const mask = c.XCB_EVENT_MASK_BUTTON_PRESS;
    _ = c.xcb_grab_button(conn, 1, win, @intCast(mask), c.XCB_GRAB_MODE_SYNC, c.XCB_GRAB_MODE_ASYNC, c.XCB_NONE, c.XCB_NONE, c.XCB_BUTTON_INDEX_ANY, c.XCB_MOD_MASK_ANY);
}

fn manage(win: c.xcb_window_t) void {
    if (findClient(win) != null) return;
    const geo_cookie = c.xcb_get_geometry(conn, win);
    const geo = c.xcb_get_geometry_reply(conn, geo_cookie, null) orelse return;
    defer std.c.free(geo);

    const info = windowKind(win);
    const cl = gpa.create(Client) catch return;
    cl.* = .{ .win = win, .kind = info.kind, .w = geo.*.width, .h = geo.*.height, .ws = ws_current };
    clients.append(gpa, cl) catch {
        gpa.destroy(cl);
        return;
    };

    switch (cl.kind) {
        .dock => {
            readStruts(cl);
            _ = c.xcb_change_window_attributes(conn, win, c.XCB_CW_EVENT_MASK, &[_]u32{c.XCB_EVENT_MASK_PROPERTY_CHANGE});
        },
        .desktop => {
            cl.x = 0;
            cl.y = 0;
            cl.w = screen_w;
            cl.h = screen_h;
            configure(win, screenRect());
        },
        .unmanaged => {
            _ = c.xcb_map_window(conn, win);
            cl.mapped = true;
        },
        .normal => {
            readTitle(cl);
            readProtocols(cl);
            _ = c.xcb_change_window_attributes(conn, win, c.XCB_CW_EVENT_MASK, &[_]u32{c.XCB_EVENT_MASK_PROPERTY_CHANGE});
            grabClientButtons(win);
            // Dialogs, and windows that belong to another window, float.
            var transient: u32 = 0;
            if (getProp(win, atom(.WM_TRANSIENT_FOR), c.XCB_ATOM_WINDOW, 1)) |r| {
                defer std.c.free(r);
                if (propU32(r).len > 0) transient = propU32(r)[0];
            }
            cl.floating = info.float or transient != 0;
            if (cl.w < 80 or cl.h < 40) {
                cl.w = 640;
                cl.h = 480;
            }
            const area = workArea();
            // Where it asked to be, if it asked; otherwise cascaded.
            if (geo.*.x > 0 or geo.*.y > 0) {
                cl.x = geo.*.x;
                cl.y = geo.*.y;
            } else {
                const p = layout.cascade(area, cascade_index);
                cascade_index += 1;
                cl.x = p.x;
                cl.y = p.y;
            }
            cl.w = @min(cl.w, area.w);
            cl.h = @min(cl.h, area.h);
            // A transient window goes where its parent is.
            if (transient != 0) if (findClient(transient)) |parent| {
                cl.ws = parent.ws;
            };
            // Initial state asked for by the client.
            if (getProp(win, atom(._NET_WM_STATE), c.XCB_ATOM_ATOM, 8)) |r| {
                defer std.c.free(r);
                for (propU32(r)) |s| {
                    if (s == atom(._NET_WM_STATE_SKIP_TASKBAR)) cl.skip_taskbar = true;
                    if (s == atom(._NET_WM_STATE_ABOVE)) cl.above = true;
                    if (s == atom(._NET_WM_STATE_FULLSCREEN)) cl.fullscreen = true;
                    if (s == atom(._NET_WM_STATE_MAXIMIZED_VERT) or s == atom(._NET_WM_STATE_MAXIMIZED_HORZ)) cl.maximized = true;
                }
            }
            stack.append(gpa, cl) catch {};
        },
    }
    arrange();
    if (cl.kind == .normal) focusClient(cl);
}

fn unmanage(cl: *Client) void {
    if (drag) |d| if (d.client == cl) {
        drag = null;
    };
    for (clients.items, 0..) |x, i| if (x == cl) {
        _ = clients.orderedRemove(i);
        break;
    };
    for (stack.items, 0..) |x, i| if (x == cl) {
        _ = stack.orderedRemove(i);
        break;
    };
    const was_focused = focused == cl;
    if (was_focused) focused = null;
    gpa.free(cl.title);
    gpa.destroy(cl);
    arrange();
    if (was_focused) focusTop();
    publishClientLists();
    _ = c.xcb_flush(conn);
}

fn closeClient(cl: *Client) void {
    if (cl.takes_delete) {
        sendClientMessage(cl.win, .WM_PROTOCOLS, atom(.WM_DELETE_WINDOW), c.XCB_CURRENT_TIME);
    } else {
        _ = c.xcb_kill_client(conn, cl.win);
    }
    _ = c.xcb_flush(conn);
}

// ---- workspaces ---------------------------------------------------------------------------------------------

fn switchWorkspace(n: usize) void {
    if (n >= ws_count or n == ws_current) return;
    ws_current = @intCast(n);
    setCardinal(root, ._NET_CURRENT_DESKTOP, &.{ws_current});
    arrange();
    focusTop();
}

fn moveToWorkspace(cl: *Client, n: usize) void {
    if (n >= ws_count or cl.kind != .normal) return;
    cl.ws = @intCast(n);
    arrange();
    if (focused == cl and !visible(cl)) focusTop();
}

fn setMinimized(cl: *Client, on: bool) void {
    cl.minimized = on;
    arrange();
    if (on and focused == cl) focusTop();
    if (!on) focusClient(cl);
}

fn activate(cl: *Client) void {
    if (cl.ws != ws_current) switchWorkspace(cl.ws);
    if (cl.minimized) {
        setMinimized(cl, false);
        return;
    }
    focusClient(cl);
}

fn toggleFloat(cl: *Client) void {
    cl.floating = !cl.floating;
    arrange();
}

// ---- shortcuts ----------------------------------------------------------------------------------------------

var keysyms: ?*c.xcb_get_keyboard_mapping_reply_t = null;
var min_keycode: u8 = 8;
var max_keycode: u8 = 255;

fn loadKeyboard() void {
    const setup = c.xcb_get_setup(conn);
    min_keycode = setup.*.min_keycode;
    max_keycode = setup.*.max_keycode;
    const cookie = c.xcb_get_keyboard_mapping(conn, min_keycode, max_keycode - min_keycode + 1);
    if (keysyms) |k| std.c.free(k);
    keysyms = c.xcb_get_keyboard_mapping_reply(conn, cookie, null);
}

/// The key that produces `sym` (as its first symbol), or null.
fn keycodeFor(sym: u32) ?u8 {
    const k = keysyms orelse return null;
    const per: usize = k.*.keysyms_per_keycode;
    const table: [*]const u32 = c.xcb_get_keyboard_mapping_keysyms(k);
    var code: usize = 0;
    while (code <= max_keycode - min_keycode) : (code += 1) {
        for (0..@min(per, 2)) |col| if (table[code * per + col] == sym) return @intCast(code + min_keycode);
    }
    return null;
}

fn symFor(keycode: u8) u32 {
    const k = keysyms orelse return 0;
    if (keycode < min_keycode) return 0;
    const per: usize = k.*.keysyms_per_keycode;
    const table: [*]const u32 = c.xcb_get_keyboard_mapping_keysyms(k);
    return table[(keycode - min_keycode) * per];
}

fn keysymNamed(name: []const u8) ?u32 {
    const z = gpa.dupeSentinel(u8, name, 0) catch return null;
    defer gpa.free(z);
    var sym = c.xkb_keysym_from_name(z.ptr, c.XKB_KEYSYM_NO_FLAGS);
    if (sym == c.XKB_KEY_NoSymbol) sym = c.xkb_keysym_from_name(z.ptr, c.XKB_KEYSYM_CASE_INSENSITIVE);
    return if (sym == c.XKB_KEY_NoSymbol) null else sym;
}

fn x11Mods(mods: u8) u16 {
    var m: u16 = 0;
    if (mods & keys.Mod.shift != 0) m |= c.XCB_MOD_MASK_SHIFT;
    if (mods & keys.Mod.ctrl != 0) m |= c.XCB_MOD_MASK_CONTROL;
    if (mods & keys.Mod.alt != 0) m |= c.XCB_MOD_MASK_1;
    if (mods & keys.Mod.logo != 0) m |= c.XCB_MOD_MASK_4;
    return m;
}

fn modsFromState(state: u16) u8 {
    var m: u8 = 0;
    if (state & c.XCB_MOD_MASK_SHIFT != 0) m |= keys.Mod.shift;
    if (state & c.XCB_MOD_MASK_CONTROL != 0) m |= keys.Mod.ctrl;
    if (state & c.XCB_MOD_MASK_1 != 0) m |= keys.Mod.alt;
    if (state & c.XCB_MOD_MASK_4 != 0) m |= keys.Mod.logo;
    return m;
}

/// Caps Lock and Num Lock must not stop a shortcut: each is grabbed with every combination of them.
const lock_variants = [_]u16{ 0, c.XCB_MOD_MASK_LOCK, c.XCB_MOD_MASK_2, c.XCB_MOD_MASK_LOCK | c.XCB_MOD_MASK_2 };

fn clearBindings() void {
    for (bindings.items) |b| {
        _ = c.xcb_ungrab_key(conn, b.keycode, root, c.XCB_MOD_MASK_ANY);
        if (b.action == .exec) gpa.free(b.action.exec);
    }
    bindings.clearRetainingCapacity();
}

fn addBinding(key_text: []const u8, action_text: []const u8) void {
    const pk = keys.parseKey(key_text) orelse return;
    const sym = keysymNamed(pk.name) orelse {
        warn("unknown key name in a shortcut: {s}", .{pk.name});
        return;
    };
    var action = keys.parseAction(action_text) orelse return;
    var i: usize = 0;
    while (i < bindings.items.len) {
        const b = bindings.items[i];
        if (b.mods == pk.mods and b.sym == sym) {
            if (b.action == .exec) gpa.free(b.action.exec);
            _ = bindings.orderedRemove(i);
        } else i += 1;
    }
    if (action == .none) return;
    const keycode = keycodeFor(sym) orelse return;
    if (action == .exec) action = .{ .exec = gpa.dupe(u8, action.exec) catch return };
    bindings.append(gpa, .{ .mods = pk.mods, .sym = sym, .keycode = keycode, .action = action }) catch {};
}

fn grabBindings() void {
    for (bindings.items) |b| {
        for (lock_variants) |extra| {
            _ = c.xcb_grab_key(conn, 1, root, x11Mods(b.mods) | extra, b.keycode, c.XCB_GRAB_MODE_ASYNC, c.XCB_GRAB_MODE_ASYNC);
        }
    }
    // Alt + left button moves, Alt + right button resizes.
    const mask = c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE | c.XCB_EVENT_MASK_BUTTON_MOTION;
    for ([_]u8{ 1, 3 }) |button| {
        for (lock_variants) |extra| {
            _ = c.xcb_grab_button(conn, 0, root, @intCast(mask), c.XCB_GRAB_MODE_ASYNC, c.XCB_GRAB_MODE_ASYNC, c.XCB_NONE, c.XCB_NONE, button, @as(u16, c.XCB_MOD_MASK_1) | extra);
        }
    }
    _ = c.xcb_flush(conn);
}

fn buildBindings(user: []const keys.Entry) void {
    clearBindings();
    for (keys.defaults) |d| addBinding(d.key, d.action);
    for (user) |e| addBinding(e.key, e.action);
    grabBindings();
}

fn runCommand(cmd: []const u8) void {
    const line = std.fmt.allocPrintSentinel(gpa, "{s} &", .{cmd}, 0) catch return;
    defer gpa.free(line);
    _ = c.system(line.ptr);
}

fn cycle(forward: bool) void {
    // The bottom window of the workspace comes up (forward), or the one below the top.
    if (forward) {
        for (stack.items) |cl| if (cl.kind == .normal and visible(cl)) return focusClient(cl);
    } else {
        var seen: usize = 0;
        var i = stack.items.len;
        while (i > 0) : (i -= 1) {
            const cl = stack.items[i - 1];
            if (cl.kind != .normal or !visible(cl)) continue;
            seen += 1;
            if (seen == 2) return focusClient(cl);
        }
    }
}

fn perform(action: keys.Action) void {
    switch (action) {
        .none => {},
        .quit => running = false,
        .close => if (focused) |f| closeClient(f),
        .next_window => cycle(true),
        .prev_window => cycle(false),
        .maximize => if (focused) |f| {
            f.maximized = !f.maximized;
            f.fullscreen = false;
            arrange();
        },
        .fullscreen => if (focused) |f| {
            f.fullscreen = !f.fullscreen;
            arrange();
        },
        .float => if (focused) |f| toggleFloat(f),
        .toggle_layout => {
            ws_policy[ws_current] = ws_policy[ws_current].toggled();
            arrange();
        },
        .workspace => |n| switchWorkspace(n),
        .workspace_prev => if (ws_current > 0) switchWorkspace(ws_current - 1),
        .workspace_next => switchWorkspace(ws_current + 1),
        .move_to_workspace => |n| if (focused) |f| moveToWorkspace(f, n),
        .move_to_prev => if (focused) |f| if (f.ws > 0) moveToWorkspace(f, f.ws - 1),
        .move_to_next => if (focused) |f| moveToWorkspace(f, f.ws + 1),
        .snap => |region| if (focused) |f| {
            const r = layout.regionRect(workArea(), region);
            f.x = r.x;
            f.y = r.y;
            f.w = r.w;
            f.h = r.h;
            f.floating = true;
            f.maximized = false;
            f.fullscreen = false;
            arrange();
        },
        .exec => |cmd| runCommand(cmd),
    }
}

// ---- pointer drags -----------------------------------------------------------------------------------------

fn beginDrag(ev: *const c.xcb_button_press_event_t) void {
    const cl = findClient(ev.child) orelse return;
    if (cl.kind != .normal or cl.fullscreen) return;
    focusClient(cl);
    // A window the user drags is the user's to place: it leaves the tiling.
    if (!cl.floating or cl.maximized) {
        var r: layout.Rect = .{ .x = cl.x, .y = cl.y, .w = cl.w, .h = cl.h };
        const geo = c.xcb_get_geometry_reply(conn, c.xcb_get_geometry(conn, cl.win), null);
        if (geo) |g| {
            defer std.c.free(g);
            r = .{ .x = g.*.x, .y = g.*.y, .w = g.*.width, .h = g.*.height };
        }
        cl.x = r.x;
        cl.y = r.y;
        cl.w = r.w;
        cl.h = r.h;
        cl.floating = true;
        cl.maximized = false;
        arrange();
    }
    const resize = ev.detail == 3;
    var d: Drag = .{ .client = cl, .resize = resize, .start_x = ev.root_x, .start_y = ev.root_y, .orig = .{ .x = cl.x, .y = cl.y, .w = cl.w, .h = cl.h } };
    if (resize) {
        // Pull the corner nearest the pointer.
        const px = ev.root_x - cl.x;
        const py = ev.root_y - cl.y;
        d.sx = if (px < @divFloor(cl.w, 2)) -1 else 1;
        d.sy = if (py < @divFloor(cl.h, 2)) -1 else 1;
    }
    drag = d;
}

fn dragMotion(root_x: i32, root_y: i32) void {
    const d = drag orelse return;
    const cl = d.client;
    const dx = root_x - d.start_x;
    const dy = root_y - d.start_y;
    if (!d.resize) {
        cl.x = d.orig.x + dx;
        cl.y = d.orig.y + dy;
    } else {
        const min: i32 = 80;
        var nx = d.orig.x;
        var ny = d.orig.y;
        var nw = d.orig.w;
        var nh = d.orig.h;
        if (d.sx < 0) {
            nw = @max(min, d.orig.w - dx);
            nx = d.orig.x + (d.orig.w - nw);
        } else nw = @max(min, d.orig.w + dx);
        if (d.sy < 0) {
            nh = @max(min, d.orig.h - dy);
            ny = d.orig.y + (d.orig.h - nh);
        } else nh = @max(min, d.orig.h + dy);
        cl.x = nx;
        cl.y = ny;
        cl.w = nw;
        cl.h = nh;
    }
    const r: layout.Rect = .{ .x = cl.x, .y = cl.y, .w = cl.w, .h = cl.h };
    configure(cl.win, r);
    sendConfigureNotify(cl, r);
    _ = c.xcb_flush(conn);
}

// ---- events -------------------------------------------------------------------------------------------------

fn onMapRequest(ev: *const c.xcb_map_request_event_t) void {
    manage(ev.window);
}

fn onConfigureRequest(ev: *const c.xcb_configure_request_event_t) void {
    if (findClient(ev.window)) |cl| {
        if (cl.kind == .normal) {
            const mask = ev.value_mask;
            if (cl.floating and !cl.maximized and !cl.fullscreen) {
                if (mask & c.XCB_CONFIG_WINDOW_X != 0) cl.x = ev.x;
                if (mask & c.XCB_CONFIG_WINDOW_Y != 0) cl.y = ev.y;
                if (mask & c.XCB_CONFIG_WINDOW_WIDTH != 0) cl.w = ev.width;
                if (mask & c.XCB_CONFIG_WINDOW_HEIGHT != 0) cl.h = ev.height;
            } else if (!cl.maximized and !cl.fullscreen and !tiledNow(cl)) {
                if (mask & c.XCB_CONFIG_WINDOW_WIDTH != 0) cl.w = ev.width;
                if (mask & c.XCB_CONFIG_WINDOW_HEIGHT != 0) cl.h = ev.height;
            }
            // What the client asked for may not be what it gets; arrange() tells it either way.
            arrange();
            return;
        }
    }
    // Windows we do not manage get what they ask for.
    var values: [7]u32 = undefined;
    var n: usize = 0;
    const m = ev.value_mask;
    if (m & c.XCB_CONFIG_WINDOW_X != 0) {
        values[n] = @bitCast(@as(i32, ev.x));
        n += 1;
    }
    if (m & c.XCB_CONFIG_WINDOW_Y != 0) {
        values[n] = @bitCast(@as(i32, ev.y));
        n += 1;
    }
    if (m & c.XCB_CONFIG_WINDOW_WIDTH != 0) {
        values[n] = ev.width;
        n += 1;
    }
    if (m & c.XCB_CONFIG_WINDOW_HEIGHT != 0) {
        values[n] = ev.height;
        n += 1;
    }
    if (m & c.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0) {
        values[n] = ev.border_width;
        n += 1;
    }
    if (m & c.XCB_CONFIG_WINDOW_SIBLING != 0) {
        values[n] = ev.sibling;
        n += 1;
    }
    if (m & c.XCB_CONFIG_WINDOW_STACK_MODE != 0) {
        values[n] = ev.stack_mode;
        n += 1;
    }
    _ = c.xcb_configure_window(conn, ev.window, m, &values);
    _ = c.xcb_flush(conn);
}

fn onUnmap(ev: *const c.xcb_unmap_notify_event_t) void {
    // Only the root's copy of the event counts (a window's own is a duplicate).
    if (ev.event != root) return;
    const cl = findClient(ev.window) orelse return;
    if (cl.ignore_unmap > 0) {
        cl.ignore_unmap -= 1;
        return;
    }
    cl.mapped = false;
    unmanage(cl);
}

fn onDestroy(ev: *const c.xcb_destroy_notify_event_t) void {
    if (findClient(ev.window)) |cl| unmanage(cl);
}

fn onProperty(ev: *const c.xcb_property_notify_event_t) void {
    const cl = findClient(ev.window) orelse return;
    if (ev.atom == atom(._NET_WM_NAME) or ev.atom == c.XCB_ATOM_WM_NAME) readTitle(cl);
    if (ev.atom == atom(.WM_PROTOCOLS)) readProtocols(cl);
    if (cl.kind == .dock and (ev.atom == atom(._NET_WM_STRUT) or ev.atom == atom(._NET_WM_STRUT_PARTIAL))) {
        readStruts(cl);
        arrange();
    }
}

fn applyStateAction(flag: *bool, action: u32) void {
    flag.* = switch (action) {
        0 => false,
        1 => true,
        else => !flag.*,
    };
}

fn onClientMessage(ev: *const c.xcb_client_message_event_t) void {
    const d = ev.data.data32;
    if (ev.window == root) {
        if (ev.type == atom(._NET_CURRENT_DESKTOP)) switchWorkspace(d[0]);
        return;
    }
    const cl = findClient(ev.window) orelse return;
    if (ev.type == atom(._NET_ACTIVE_WINDOW)) {
        activate(cl);
    } else if (ev.type == atom(._NET_CLOSE_WINDOW)) {
        closeClient(cl);
    } else if (ev.type == atom(._NET_WM_DESKTOP)) {
        moveToWorkspace(cl, d[0]);
    } else if (ev.type == atom(.WM_CHANGE_STATE)) {
        if (d[0] == 3) setMinimized(cl, true);
    } else if (ev.type == atom(._NET_WM_STATE)) {
        for ([_]u32{ d[1], d[2] }) |prop| {
            if (prop == 0) continue;
            if (prop == atom(._NET_WM_STATE_FULLSCREEN)) {
                applyStateAction(&cl.fullscreen, d[0]);
            } else if (prop == atom(._NET_WM_STATE_MAXIMIZED_VERT) or prop == atom(._NET_WM_STATE_MAXIMIZED_HORZ)) {
                applyStateAction(&cl.maximized, d[0]);
            } else if (prop == atom(._NET_WM_STATE_SKIP_TASKBAR)) {
                applyStateAction(&cl.skip_taskbar, d[0]);
            } else if (prop == atom(._NET_WM_STATE_ABOVE)) {
                applyStateAction(&cl.above, d[0]);
            } else if (prop == atom(._NET_WM_STATE_HIDDEN)) {
                var m = cl.minimized;
                applyStateAction(&m, d[0]);
                cl.minimized = m;
            }
        }
        arrange();
        if (cl.minimized and focused == cl) focusTop();
    }
}

fn onKeyPress(ev: *const c.xcb_key_press_event_t) void {
    const sym = symFor(ev.detail);
    const mods = modsFromState(ev.state);
    // A tap of the Super key alone is its own shortcut: it fires on release.
    if (sym == c.XKB_KEY_Super_L or sym == c.XKB_KEY_Super_R) {
        super_pending = true;
        return;
    }
    super_pending = false;
    for (bindings.items) |b| {
        if (b.keycode == ev.detail and b.mods == mods) return perform(b.action);
    }
}

fn onKeyRelease(ev: *const c.xcb_key_release_event_t) void {
    const sym = symFor(ev.detail);
    if ((sym == c.XKB_KEY_Super_L or sym == c.XKB_KEY_Super_R) and super_pending) {
        super_pending = false;
        for (bindings.items) |b| if (b.mods == 0 and b.sym == c.XKB_KEY_Super_L) perform(b.action);
    }
}

fn onButtonPress(ev: *const c.xcb_button_press_event_t) void {
    const state = ev.state & ~@as(u16, c.XCB_MOD_MASK_LOCK | c.XCB_MOD_MASK_2);
    if (ev.event == root and state == c.XCB_MOD_MASK_1) {
        beginDrag(ev);
        return;
    }
    // A plain click on a window: focus it, then let the window have the click.
    if (findClient(ev.event)) |cl| {
        if (cl.kind == .normal and focused != cl) focusClient(cl);
    }
    _ = c.xcb_allow_events(conn, c.XCB_ALLOW_REPLAY_POINTER, ev.time);
    _ = c.xcb_flush(conn);
}

fn handle(ev: *c.xcb_generic_event_t) void {
    switch (ev.response_type & 0x7f) {
        c.XCB_MAP_REQUEST => onMapRequest(@ptrCast(ev)),
        c.XCB_CONFIGURE_REQUEST => onConfigureRequest(@ptrCast(ev)),
        c.XCB_UNMAP_NOTIFY => onUnmap(@ptrCast(ev)),
        c.XCB_DESTROY_NOTIFY => onDestroy(@ptrCast(ev)),
        c.XCB_PROPERTY_NOTIFY => onProperty(@ptrCast(ev)),
        c.XCB_CLIENT_MESSAGE => onClientMessage(@ptrCast(ev)),
        c.XCB_KEY_PRESS => onKeyPress(@ptrCast(ev)),
        c.XCB_KEY_RELEASE => onKeyRelease(@ptrCast(ev)),
        c.XCB_BUTTON_PRESS => onButtonPress(@ptrCast(ev)),
        c.XCB_BUTTON_RELEASE => drag = null,
        c.XCB_MOTION_NOTIFY => {
            const m: *const c.xcb_motion_notify_event_t = @ptrCast(ev);
            dragMotion(m.root_x, m.root_y);
        },
        c.XCB_MAPPING_NOTIFY => {
            loadKeyboard();
            buildBindings(cfg.keys);
        },
        else => if (randr_event_base) |base| {
            if (ev.response_type & 0x7f == base) onScreenChanged();
        },
    }
}

// ---- screen changes (XRandR) --------------------------------------------------------------------------------

// The RandR headers are not needed for this: one request (select events on the root) and one event (the screen
// changed) are written out by hand, so the window manager builds with XCB's core alone.
var randr_ext: c.xcb_extension_t = .{ .name = "RANDR", .global_id = 0 };
var randr_event_base: ?u8 = null;

fn selectScreenChanges() void {
    const data = c.xcb_get_extension_data(conn, &randr_ext) orelse return;
    if (data.*.present == 0) return;
    randr_event_base = data.*.first_event;
    // RRSelectInput (minor opcode 4): window, enable mask (ScreenChangeNotify = 1).
    const Request = extern struct { major: u8, minor: u8, length: u16, window: u32, enable: u16, pad: u16 };
    var req: Request = .{ .major = 0, .minor = 4, .length = 0, .window = root, .enable = 1, .pad = 0 };
    var parts: [4]c.struct_iovec = undefined;
    parts[2] = .{ .iov_base = &req, .iov_len = @sizeOf(Request) };
    parts[3] = .{ .iov_base = null, .iov_len = 0 };
    var proto: c.xcb_protocol_request_t = .{ .count = 2, .ext = &randr_ext, .opcode = 4, .isvoid = 1 };
    _ = c.xcb_send_request(conn, 0, &parts[2], &proto);
}

/// The screen got a different size (a monitor plugged in, a mode set): read it again and lay everything out anew.
fn onScreenChanged() void {
    const geo = c.xcb_get_geometry_reply(conn, c.xcb_get_geometry(conn, root), null) orelse return;
    defer std.c.free(geo);
    if (geo.*.width == screen_w and geo.*.height == screen_h) return;
    screen_w = geo.*.width;
    screen_h = geo.*.height;
    for (clients.items) |cl| {
        if (cl.kind == .desktop) {
            cl.w = screen_w;
            cl.h = screen_h;
            configure(cl.win, screenRect());
        } else if (cl.kind == .normal and !cl.maximized and !cl.fullscreen) {
            // A floating window that is now off the screen comes back onto it.
            cl.w = @min(cl.w, screen_w);
            cl.h = @min(cl.h, screen_h);
            cl.x = std.math.clamp(cl.x, 0, @max(screen_w - cl.w, 0));
            cl.y = std.math.clamp(cl.y, 0, @max(screen_h - cl.h, 0));
        }
    }
    publishDesktops();
    arrange();
}

// ---- start up ----------------------------------------------------------------------------------------------

fn internAtoms() void {
    var cookies: [atoms.len]c.xcb_intern_atom_cookie_t = undefined;
    inline for (std.enums.values(Atom), 0..) |a, i| {
        cookies[i] = c.xcb_intern_atom(conn, 0, @tagName(a).len, @tagName(a).ptr);
    }
    for (0..atoms.len) |i| {
        const reply = c.xcb_intern_atom_reply(conn, cookies[i], null);
        if (reply) |r| {
            atoms[i] = r.*.atom;
            std.c.free(r);
        } else atoms[i] = 0;
    }
}

fn setCursor() void {
    // The usual arrow, from the standard cursor font (glyph 68, "left_ptr").
    const font = c.xcb_generate_id(conn);
    _ = c.xcb_open_font(conn, font, 6, "cursor");
    const cursor = c.xcb_generate_id(conn);
    _ = c.xcb_create_glyph_cursor(conn, cursor, font, font, 68, 69, 0, 0, 0, 0xffff, 0xffff, 0xffff);
    _ = c.xcb_change_window_attributes(conn, root, c.XCB_CW_CURSOR, &[_]u32{cursor});
}

fn publishSupport() void {
    const supported = [_]Atom{
        ._NET_SUPPORTED,                  ._NET_SUPPORTING_WM_CHECK,     ._NET_CLIENT_LIST,                ._NET_CLIENT_LIST_STACKING,
        ._NET_ACTIVE_WINDOW,              ._NET_NUMBER_OF_DESKTOPS,      ._NET_CURRENT_DESKTOP,            ._NET_DESKTOP_NAMES,
        ._NET_DESKTOP_GEOMETRY,           ._NET_DESKTOP_VIEWPORT,        ._NET_WORKAREA,                   ._NET_WM_DESKTOP,
        ._NET_WM_STATE,                   ._NET_WM_STATE_FULLSCREEN,     ._NET_WM_STATE_MAXIMIZED_VERT,    ._NET_WM_STATE_MAXIMIZED_HORZ,
        ._NET_WM_STATE_HIDDEN,            ._NET_WM_WINDOW_TYPE,          ._NET_WM_WINDOW_TYPE_DOCK,        ._NET_WM_WINDOW_TYPE_DESKTOP,
        ._NET_WM_WINDOW_TYPE_DIALOG,      ._NET_WM_STRUT,                ._NET_WM_STRUT_PARTIAL,           ._NET_CLOSE_WINDOW,
        ._NET_WM_NAME,                    ._NET_WM_STATE_SKIP_TASKBAR,   ._NET_WM_STATE_ABOVE,
    };
    var list: [supported.len]u32 = undefined;
    for (supported, 0..) |a, i| list[i] = atom(a);
    _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, root, atom(._NET_SUPPORTED), c.XCB_ATOM_ATOM, 32, list.len, &list);

    // The window clients look for to learn which window manager this is.
    check_window = c.xcb_generate_id(conn);
    _ = c.xcb_create_window(conn, 0, check_window, root, -10, -10, 1, 1, 0, c.XCB_WINDOW_CLASS_INPUT_ONLY, c.XCB_COPY_FROM_PARENT, 0, null);
    setWindows(check_window, ._NET_SUPPORTING_WM_CHECK, &.{check_window});
    setWindows(root, ._NET_SUPPORTING_WM_CHECK, &.{check_window});
    const name = "dkde-wm";
    _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, check_window, atom(._NET_WM_NAME), atom(.UTF8_STRING), 8, name.len, name);
}

fn configPath(buf: []u8) ?[:0]const u8 {
    if (std.c.getenv("DKDE_COMPOSITOR_CONFIG")) |p| return std.fmt.bufPrintSentinel(buf, "{s}", .{std.mem.span(p)}, 0) catch null;
    if (std.c.getenv("XDG_CONFIG_HOME")) |d| return std.fmt.bufPrintSentinel(buf, "{s}/dkde/compositor.toml", .{std.mem.span(d)}, 0) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.config/dkde/compositor.toml", .{std.mem.span(home)}, 0) catch null;
}

fn readFile(path: [:0]const u8) ?[]u8 {
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        out.appendSlice(gpa, buf[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn loadConfig() void {
    var path_buf: [1024]u8 = undefined;
    cfg = .{};
    const path = configPath(&path_buf) orelse return;
    const text = readFile(path) orelse return;
    defer gpa.free(text);
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| gpa.free(w);
        warnings.deinit(gpa);
    }
    cfg = config.parse(gpa, text, &warnings) catch cfg;
    for (warnings.items) |w| warn("{s}: {s}", .{ path, w });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("dkde-wm {s}\n", .{version});
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: dkde-wm [--help] [--version]\n\nDKDE's X11 window manager. Settings: ~/.config/dkde/compositor.toml (shared with dkde-compositor).\n", .{});
            return;
        }
        std.debug.print("dkde-wm: unknown option {s}\n", .{arg});
        std.process.exit(2);
    }

    var screen_num: c_int = 0;
    conn = c.xcb_connect(null, &screen_num) orelse {
        warn("cannot connect to the X server", .{});
        std.process.exit(1);
    };
    if (c.xcb_connection_has_error(conn) != 0) {
        warn("cannot connect to the X server (is DISPLAY set?)", .{});
        std.process.exit(1);
    }
    var it = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn));
    var i: c_int = 0;
    while (i < screen_num) : (i += 1) c.xcb_screen_next(&it);
    screen = it.data;
    root = screen.root;
    screen_w = screen.width_in_pixels;
    screen_h = screen.height_in_pixels;

    // Becoming the window manager: only one client may select this on the root.
    const mask = c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | c.XCB_EVENT_MASK_PROPERTY_CHANGE |
        c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_KEY_RELEASE | c.XCB_EVENT_MASK_BUTTON_PRESS;
    const cookie = c.xcb_change_window_attributes_checked(conn, root, c.XCB_CW_EVENT_MASK, &[_]u32{mask});
    if (c.xcb_request_check(conn, cookie)) |err| {
        std.c.free(err);
        warn("another window manager is already running", .{});
        std.process.exit(1);
    }

    _ = c.signal(c.SIGCHLD, c.SIG_IGN);
    internAtoms();
    loadConfig();
    ws_count = std.math.clamp(cfg.workspaces, 1, 9);
    @memset(&ws_policy, cfg.policy);
    loadKeyboard();
    buildBindings(cfg.keys);
    setCursor();
    selectScreenChanges();
    publishSupport();
    publishDesktops();
    publishWorkArea();
    publishClientLists();
    publishActive();
    _ = c.xcb_flush(conn);

    // Windows that exist already (a restart of the window manager) are adopted.
    if (c.xcb_query_tree_reply(conn, c.xcb_query_tree(conn, root), null)) |tree| {
        defer std.c.free(tree);
        const kids = c.xcb_query_tree_children(tree)[0..@intCast(c.xcb_query_tree_children_length(tree))];
        for (kids) |w| {
            if (w == check_window) continue;
            const attr = c.xcb_get_window_attributes_reply(conn, c.xcb_get_window_attributes(conn, w), null) orelse continue;
            defer std.c.free(attr);
            if (attr.*.override_redirect == 0 and attr.*.map_state == c.XCB_MAP_STATE_VIEWABLE) {
                // Our own unmap/map of an adopted window must not look like it leaving.
                manage(w);
            }
        }
    }

    while (running) {
        const ev = c.xcb_wait_for_event(conn) orelse break;
        defer std.c.free(ev);
        handle(ev);
        if (c.xcb_connection_has_error(conn) != 0) break;
    }
    clearBindings();
    _ = c.xcb_flush(conn);
    c.xcb_disconnect(conn);
}

test {
    _ = layout;
}
