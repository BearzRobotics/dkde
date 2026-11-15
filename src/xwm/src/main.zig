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
const deco = @import("frame.zig");

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
    _GTK_FRAME_EXTENTS,
    _MOTIF_WM_HINTS,
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
    /// Which monitor it is on (an index into `monitors`).
    mon: u8 = 0,
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
    /// Size limits from WM_NORMAL_HINTS (0 = none).
    min_w: i32 = 0,
    min_h: i32 = 0,
    max_w: i32 = 0,
    max_h: i32 = 0,
    /// The window drawn around it (title bar, resize edges) when it has no frame of its own; 0 = none.
    frame: c.xcb_window_t = 0,
    /// Outer size last given to the frame, for hit tests.
    fw: i32 = 0,
    fh: i32 = 0,
    /// Time of the last click on the title bar, to spot a double click.
    last_click: u32 = 0,
    /// Width of the border WM draws: windows that draw their own frame get none.
    border: u8 = 0,
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
    for (clients.items) |cl| if (cl.win == win or (cl.frame != 0 and cl.frame == win)) return cl;
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

/// One monitor: its rectangle, and what is left of it after the panels on it.
const Monitor = struct { rect: layout.Rect, work: layout.Rect };

var monitors: [8]Monitor = undefined;
var monitor_count: usize = 0;

fn contains(r: layout.Rect, x: i32, y: i32) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}

/// The monitor a rectangle is on: the one holding its centre, else the nearest to it.
fn monitorOf(r: layout.Rect) usize {
    const cx = r.x + @divFloor(r.w, 2);
    const cy = r.y + @divFloor(r.h, 2);
    var best: usize = 0;
    var best_d: i64 = std.math.maxInt(i64);
    for (monitors[0..monitor_count], 0..) |m, i| {
        if (contains(m.rect, cx, cy)) return i;
        const mx = m.rect.x + @divFloor(m.rect.w, 2);
        const my = m.rect.y + @divFloor(m.rect.h, 2);
        const d = @as(i64, cx - mx) * (cx - mx) + @as(i64, cy - my) * (cy - my);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

fn clientRect(cl: *const Client) layout.Rect {
    return .{ .x = cl.x, .y = cl.y, .w = cl.w, .h = cl.h };
}

/// The monitor a client lives on, always a valid index.
fn monitorFor(cl: *const Client) usize {
    return @min(cl.mon, monitor_count - 1);
}

/// What panels reserve on `m`: the struts of the docks standing on it. A strut is measured from the edge of
/// the whole screen, so on a monitor that is not at that edge it only counts where it reaches into the monitor.
fn workAreaOf(m: layout.Rect) layout.Rect {
    var left: i32 = m.x;
    var right: i32 = m.x + m.w;
    var top: i32 = m.y;
    var bottom: i32 = m.y + m.h;
    for (clients.items) |cl| {
        if (cl.kind != .dock) continue;
        const dock_mon = monitorOf(clientRect(cl));
        if (dock_mon >= monitor_count or !std.meta.eql(monitors[dock_mon].rect, m)) continue;
        left = @max(left, @as(i32, @intCast(cl.strut[0])));
        right = @min(right, screen_w - @as(i32, @intCast(cl.strut[1])));
        top = @max(top, @as(i32, @intCast(cl.strut[2])));
        bottom = @min(bottom, screen_h - @as(i32, @intCast(cl.strut[3])));
    }
    // A panel can never take more than half of a monitor.
    left = @min(left, m.x + @divFloor(m.w, 2));
    right = @max(right, m.x + @divFloor(m.w, 2));
    top = @min(top, m.y + @divFloor(m.h, 2));
    bottom = @max(bottom, m.y + @divFloor(m.h, 2));
    return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
}

test "a panel's strut shrinks only the monitor it stands on" {
    monitors[0] = .{ .rect = .{ .x = 0, .y = 0, .w = 1000, .h = 600 }, .work = undefined };
    monitors[1] = .{ .rect = .{ .x = 1000, .y = 0, .w = 800, .h = 600 }, .work = undefined };
    monitor_count = 2;
    screen_w = 1800;
    screen_h = 600;
    defer monitor_count = 0;
    var dock: Client = .{ .win = 9, .kind = .dock, .x = 0, .y = 570, .w = 1000, .h = 30, .strut = .{ 0, 0, 0, 30 } };
    clients.clearRetainingCapacity();
    clients.append(gpa, &dock) catch unreachable;
    defer clients.clearRetainingCapacity();
    try std.testing.expectEqual(layout.Rect{ .x = 0, .y = 0, .w = 1000, .h = 570 }, workAreaOf(monitors[0].rect));
    try std.testing.expectEqual(layout.Rect{ .x = 1000, .y = 0, .w = 800, .h = 600 }, workAreaOf(monitors[1].rect));
    try std.testing.expectEqual(@as(usize, 1), monitorOf(.{ .x = 1200, .y = 100, .w = 100, .h = 100 }));
    try std.testing.expectEqual(@as(usize, 0), monitorOf(.{ .x = -500, .y = 100, .w = 100, .h = 100 }));
}

/// The first monitor's work area, for the one `_NET_WORKAREA` value EWMH has.
fn workArea() layout.Rect {
    return monitors[0].work;
}

/// Reads the monitors from RandR (just the screen when there is none) and works out each one's work area.
fn updateMonitors() void {
    monitor_count = 0;
    if (randr_event_base != null) {
        const res = c.xcb_randr_get_screen_resources_current_reply(conn, c.xcb_randr_get_screen_resources_current(conn, root), null);
        if (res) |r| {
            defer std.c.free(r);
            const crtcs = c.xcb_randr_get_screen_resources_current_crtcs(r)[0..@intCast(c.xcb_randr_get_screen_resources_current_crtcs_length(r))];
            for (crtcs) |crtc| {
                if (monitor_count == monitors.len) break;
                const info = c.xcb_randr_get_crtc_info_reply(conn, c.xcb_randr_get_crtc_info(conn, crtc, r.*.config_timestamp), null) orelse continue;
                defer std.c.free(info);
                if (info.*.mode == 0 or info.*.width == 0) continue;
                monitors[monitor_count] = .{ .rect = .{ .x = info.*.x, .y = info.*.y, .w = info.*.width, .h = info.*.height }, .work = undefined };
                monitor_count += 1;
            }
        }
    }
    if (monitor_count == 0) {
        monitors[0] = .{ .rect = .{ .x = 0, .y = 0, .w = screen_w, .h = screen_h }, .work = undefined };
        monitor_count = 1;
    }
    // Left to right, so monitor 0 is the leftmost (and a panel placed by position finds it).
    std.mem.sort(Monitor, monitors[0..monitor_count], {}, struct {
        fn less(_: void, a: Monitor, b: Monitor) bool {
            return if (a.rect.x != b.rect.x) a.rect.x < b.rect.x else a.rect.y < b.rect.y;
        }
    }.less);
    refreshWorkAreas();
    logMonitors();
}

/// One line per monitor, for bug reports: dkde-wm writes this at start and whenever the layout changes.
fn logMonitors() void {
    warn("screen {d}x{d}, {d} monitor(s){s}", .{ screen_w, screen_h, monitor_count, if (randr_event_base == null) " (no RandR)" else "" });
    for (monitors[0..monitor_count], 0..) |m, i| {
        warn("  monitor {d}: {d}x{d}+{d}+{d}, work area {d}x{d}+{d}+{d}", .{ i, m.rect.w, m.rect.h, m.rect.x, m.rect.y, m.work.w, m.work.h, m.work.x, m.work.y });
    }
}

fn refreshWorkAreas() void {
    for (monitors[0..monitor_count]) |*m| m.work = workAreaOf(m.rect);
}



fn clampSize(v: i32) u32 {
    return @intCast(@max(v, 1));
}

fn configure(win: c.xcb_window_t, r: layout.Rect) void {
    var values = [_]u32{ @bitCast(r.x), @bitCast(r.y), clampSize(r.w), clampSize(r.h), 0 };
    _ = c.xcb_configure_window(conn, win, c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y | c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT | c.XCB_CONFIG_WINDOW_BORDER_WIDTH, &values);
}

/// The size a client accepts: `r` limited by its minimum and maximum.
fn fit(cl: *const Client, r: layout.Rect) layout.Rect {
    var out = r;
    if (cl.min_w > 0) out.w = @max(out.w, cl.min_w);
    if (cl.min_h > 0) out.h = @max(out.h, cl.min_h);
    if (cl.max_w > 0) out.w = @min(out.w, cl.max_w);
    if (cl.max_h > 0) out.h = @min(out.h, cl.max_h);
    return out;
}

test "size hints limit a size both ways" {
    var cl: Client = .{ .win = 1, .min_w = 200, .min_h = 100, .max_w = 400, .max_h = 0 };
    const small = fit(&cl, .{ .x = 5, .y = 6, .w = 50, .h = 50 });
    try std.testing.expectEqual(@as(i32, 200), small.w);
    try std.testing.expectEqual(@as(i32, 100), small.h);
    try std.testing.expectEqual(@as(i32, 5), small.x);
    const big = fit(&cl, .{ .x = 0, .y = 0, .w = 900, .h = 900 });
    try std.testing.expectEqual(@as(i32, 400), big.w);
    try std.testing.expectEqual(@as(i32, 900), big.h);
}

fn outerWin(cl: *const Client) c.xcb_window_t {
    return if (cl.frame != 0) cl.frame else cl.win;
}

fn insetsOf(cl: *const Client) deco.Insets {
    if (cl.frame == 0) return .{ .l = 0, .r = 0, .t = 0, .b = 0 };
    return deco.insets(cl.maximized, cl.fullscreen);
}

var visual: ?*c.xcb_visualtype_t = null;

fn redrawFrame(cl: *Client) void {
    if (cl.frame == 0 or cl.fw <= 0) return;
    const v = visual orelse return;
    deco.draw(conn, v, cl.frame, cl.fw, cl.fh, cl.title, focused == cl, cl.maximized);
}

/// Puts a window at `r` (its outer rectangle, frame included), within its size limits, and tells it.
fn place(cl: *Client, r0: layout.Rect) void {
    const ins = insetsOf(cl);
    // The size limits are the client's, so they apply inside the frame.
    const inner = fit(cl, .{ .x = r0.x, .y = r0.y, .w = r0.w - ins.l - ins.r, .h = r0.h - ins.t - ins.b });
    const outer: layout.Rect = .{ .x = inner.x, .y = inner.y, .w = inner.w + ins.l + ins.r, .h = inner.h + ins.t + ins.b };
    if (cl.frame != 0) {
        var fv = [_]u32{ @bitCast(outer.x), @bitCast(outer.y), clampSize(outer.w), clampSize(outer.h) };
        _ = c.xcb_configure_window(conn, cl.frame, c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y | c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT, &fv);
        var cv = [_]u32{ @bitCast(ins.l), @bitCast(ins.t), clampSize(inner.w), clampSize(inner.h) };
        _ = c.xcb_configure_window(conn, cl.win, c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y | c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT, &cv);
        sendConfigureNotify(cl, .{ .x = outer.x + ins.l, .y = outer.y + ins.t, .w = inner.w, .h = inner.h });
        const changed = cl.fw != outer.w or cl.fh != outer.h;
        cl.fw = outer.w;
        cl.fh = outer.h;
        if (changed) redrawFrame(cl);
        return;
    }
    var values = [_]u32{ @bitCast(outer.x), @bitCast(outer.y), clampSize(outer.w), clampSize(outer.h), 0 };
    _ = c.xcb_configure_window(conn, cl.win, c.XCB_CONFIG_WINDOW_X | c.XCB_CONFIG_WINDOW_Y | c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT | c.XCB_CONFIG_WINDOW_BORDER_WIDTH, &values);
    sendConfigureNotify(cl, outer);
}

const border_focused: u32 = 0x3584e4;
const border_idle: u32 = 0x8a8a8a;

/// The frames show who has the focus, so they are drawn again when it moves.
fn paintBorders() void {
    for (clients.items) |cl| if (cl.kind == .normal and cl.frame != 0) redrawFrame(cl);
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
    refreshWorkAreas();
    const gap_cells = 128;
    var cells: [gap_cells]layout.Rect = undefined;
    var tiled: [gap_cells]*Client = undefined;
    // Each monitor tiles its own windows in its own work area.
    var placed: usize = 0;
    for (monitors[0..monitor_count], 0..) |m, mi| {
        var n: usize = 0;
        const start = placed;
        for (clients.items) |cl| {
            if (placed + n < gap_cells and monitorFor(cl) == mi and tiledNow(cl)) {
                tiled[placed + n] = cl;
                n += 1;
            }
        }
        layout.tile(m.work, n, cfg.options, cells[start..][0..@max(n, 1)]);
        placed += n;
    }
    const n = placed;

    for (clients.items) |cl| {
        const show = cl.kind == .dock or cl.kind == .desktop or visible(cl);
        if (show) {
            if (cl.kind == .normal) {
                var r: layout.Rect = .{ .x = cl.x, .y = cl.y, .w = cl.w, .h = cl.h };
                const mon = monitors[monitorFor(cl)];
                if (cl.fullscreen) {
                    r = mon.rect;
                } else if (cl.maximized) {
                    r = mon.work;
                } else if (tiledNow(cl)) {
                    for (tiled[0..n], 0..) |t, i| if (t == cl) {
                        r = cells[i];
                    };
                }
                place(cl, r);
            }
            if (!cl.mapped) {
                if (cl.frame != 0) _ = c.xcb_map_window(conn, cl.win);
                _ = c.xcb_map_window(conn, outerWin(cl));
                cl.mapped = true;
            }
        } else if (cl.mapped) {
            // Hiding a framed window unmaps the frame; its own unmap is announced for the frame, not the client.
            cl.ignore_unmap +|= 1;
            _ = c.xcb_unmap_window(conn, outerWin(cl));
            cl.mapped = false;
        }
        if (cl.kind == .normal) publishClientState(cl);
    }
    restack();
    publishWorkArea();
    paintBorders();
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
            _ = c.xcb_configure_window(conn, outerWin(cl), c.XCB_CONFIG_WINDOW_STACK_MODE, &values);
        } else {
            _ = c.xcb_configure_window(conn, outerWin(cl), c.XCB_CONFIG_WINDOW_SIBLING | c.XCB_CONFIG_WINDOW_STACK_MODE, &values);
        }
        below = outerWin(cl);
    }
    // Windows that asked to stay on top (the Start menu) go above the rest.
    for (stack.items) |cl| {
        if (cl.kind == .normal and cl.above and visible(cl)) {
            const v = [_]u32{c.XCB_STACK_MODE_ABOVE};
            _ = c.xcb_configure_window(conn, outerWin(cl), c.XCB_CONFIG_WINDOW_STACK_MODE, &v);
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
    paintBorders();
    _ = c.xcb_flush(conn);
}

/// Focus without raising: what moving the pointer onto a window does when focus follows the mouse.
fn focusOnly(target: *Client) void {
    if (target.kind != .normal or focused == target) return;
    focused = target;
    _ = c.xcb_set_input_focus(conn, c.XCB_INPUT_FOCUS_POINTER_ROOT, target.win, c.XCB_CURRENT_TIME);
    if (target.takes_focus) sendClientMessage(target.win, .WM_PROTOCOLS, atom(.WM_TAKE_FOCUS), c.XCB_CURRENT_TIME);
    publishActive();
    paintBorders();
    _ = c.xcb_flush(conn);
}

fn clientEventMask() u32 {
    const base: u32 = c.XCB_EVENT_MASK_PROPERTY_CHANGE;
    return if (cfg.focus_follows_mouse) base | c.XCB_EVENT_MASK_ENTER_WINDOW else base;
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

/// WM_NORMAL_HINTS: the smallest and largest size the window allows.
fn readSizeHints(cl: *Client) void {
    cl.min_w = 0;
    cl.min_h = 0;
    cl.max_w = 0;
    cl.max_h = 0;
    const reply = getProp(cl.win, c.XCB_ATOM_WM_NORMAL_HINTS, c.XCB_ATOM_WM_SIZE_HINTS, 18) orelse return;
    defer std.c.free(reply);
    const v = propU32(reply);
    if (v.len < 9) return;
    const p_min_size: u32 = 1 << 4;
    const p_max_size: u32 = 1 << 5;
    if (v[0] & p_min_size != 0) {
        cl.min_w = @intCast(v[5]);
        cl.min_h = @intCast(v[6]);
    }
    if (v[0] & p_max_size != 0) {
        cl.max_w = @intCast(v[7]);
        cl.max_h = @intCast(v[8]);
    }
}

/// Windows that draw their own frame (GTK's client-side decorations, or Motif hints asking for none) get no
/// border from here; the rest get a thin one that shows which has the focus.
fn readBorder(cl: *Client) void {
    cl.border = 2;
    if (getProp(cl.win, atom(._GTK_FRAME_EXTENTS), c.XCB_ATOM_CARDINAL, 4)) |r| {
        defer std.c.free(r);
        if (propU32(r).len >= 4) cl.border = 0;
    }
    if (cl.border != 0) if (getProp(cl.win, atom(._MOTIF_WM_HINTS), atom(._MOTIF_WM_HINTS), 5)) |r| {
        defer std.c.free(r);
        const v = propU32(r);
        // flags, functions, decorations: bit 1 of the flags says the decorations field is set.
        if (v.len >= 3 and v[0] & 2 != 0 and v[2] == 0) cl.border = 0;
    };
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

fn createFrame(cl: *Client) void {
    const f = c.xcb_generate_id(conn);
    const ins = deco.insets(false, false);
    const mask = c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE | c.XCB_EVENT_MASK_BUTTON_MOTION | c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY;
    _ = c.xcb_create_window(conn, c.XCB_COPY_FROM_PARENT, f, root, @intCast(cl.x), @intCast(cl.y), @intCast(clampSize(cl.w + ins.l + ins.r)), @intCast(clampSize(cl.h + ins.t + ins.b)), 0, c.XCB_WINDOW_CLASS_INPUT_OUTPUT, c.XCB_COPY_FROM_PARENT, c.XCB_CW_EVENT_MASK, &[_]u32{mask});
    _ = c.xcb_reparent_window(conn, cl.win, f, @intCast(ins.l), @intCast(ins.t));
    cl.frame = f;
    const extents = [_]u32{ @intCast(ins.l), @intCast(ins.r), @intCast(ins.t), @intCast(ins.b) };
    _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, cl.win, atom(._NET_FRAME_EXTENTS), c.XCB_ATOM_CARDINAL, 32, 4, &extents);
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
            readSizeHints(cl);
            readBorder(cl);
            _ = c.xcb_change_window_attributes(conn, win, c.XCB_CW_EVENT_MASK, &[_]u32{clientEventMask()});
            grabClientButtons(win);
            // Dialogs, and windows that belong to another window, float.
            var transient: u32 = 0;
            if (getProp(win, atom(.WM_TRANSIENT_FOR), c.XCB_ATOM_WINDOW, 1)) |r| {
                defer std.c.free(r);
                if (propU32(r).len > 0) transient = propU32(r)[0];
            }
            // A window that cannot change size is placed, not tiled.
            cl.floating = info.float or transient != 0 or (cl.min_w > 0 and cl.min_w == cl.max_w and cl.min_h == cl.max_h);
            if (cl.w < 80 or cl.h < 40) {
                cl.w = 640;
                cl.h = 480;
            }
            // New windows open on the monitor the pointer is on.
            var pointer_mon: usize = 0;
            if (c.xcb_query_pointer_reply(conn, c.xcb_query_pointer(conn, root), null)) |q| {
                defer std.c.free(q);
                pointer_mon = monitorOf(.{ .x = q.*.root_x, .y = q.*.root_y, .w = 1, .h = 1 });
            }
            const area = monitors[pointer_mon].work;
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
            // A program that draws no frame of its own gets one: a title bar with the three buttons.
            if (cl.border > 0) {
                cl.border = 0;
                createFrame(cl);
                const ins = deco.insets(false, false);
                cl.w += ins.l + ins.r;
                cl.h += ins.t + ins.b;
            }
            cl.mon = @intCast(monitorOf(clientRect(cl)));
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
    if (cl.frame != 0) {
        // The client goes back to the root if it is still there; the frame is ours to remove.
        _ = c.xcb_reparent_window(conn, cl.win, root, @intCast(cl.x), @intCast(cl.y));
        _ = c.xcb_destroy_window(conn, cl.frame);
    }
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
            const r = layout.regionRect(monitors[monitorFor(f)].work, region);
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

/// Alt + button on a window: left moves, right resizes from the nearest corner.
fn beginDrag(ev: *const c.xcb_button_press_event_t) void {
    const cl = findClient(ev.child) orelse return;
    if (cl.kind != .normal or cl.fullscreen) return;
    const resize = ev.detail == 3;
    var sx: i32 = 1;
    var sy: i32 = 1;
    if (resize) {
        // Pull the corner nearest the pointer.
        const px = ev.root_x - cl.x;
        const py = ev.root_y - cl.y;
        sx = if (px < @divFloor(cl.w, 2)) -1 else 1;
        sy = if (py < @divFloor(cl.h, 2)) -1 else 1;
    }
    startDrag(cl, ev.root_x, ev.root_y, resize, sx, sy);
}

/// Begins moving (or resizing, pulling the edges `sx` and `sy` point to) a window.
fn startDrag(cl: *Client, root_x: i32, root_y: i32, resize: bool, sx: i32, sy: i32) void {
    focusClient(cl);
    // A window the user drags is the user's to place: it leaves the tiling.
    if (!cl.floating or cl.maximized) {
        var r: layout.Rect = .{ .x = cl.x, .y = cl.y, .w = cl.w, .h = cl.h };
        const geo = c.xcb_get_geometry_reply(conn, c.xcb_get_geometry(conn, outerWin(cl)), null);
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
    drag = .{ .client = cl, .resize = resize, .start_x = root_x, .start_y = root_y, .orig = .{ .x = cl.x, .y = cl.y, .w = cl.w, .h = cl.h }, .sx = sx, .sy = sy };
}

/// A click on a frame: the buttons act, the title bar moves (a double click maximizes), the edges resize.
fn onFramePress(cl: *Client, ev: *const c.xcb_button_press_event_t) void {
    if (ev.detail != 1) return;
    focusClient(cl);
    const what = deco.hit(cl.fw, cl.fh, ev.event_x, ev.event_y, cl.maximized);
    switch (what) {
        .close => closeClient(cl),
        .minimize => setMinimized(cl, true),
        .maximize => {
            cl.maximized = !cl.maximized;
            cl.fullscreen = false;
            arrange();
        },
        .title => {
            // Two presses within 400 ms: maximize or restore.
            if (cl.last_click != 0 and ev.time -% cl.last_click < 400) {
                cl.last_click = 0;
                cl.maximized = !cl.maximized;
                arrange();
            } else {
                cl.last_click = ev.time;
                if (!cl.maximized) startDrag(cl, ev.root_x, ev.root_y, false, 0, 0);
            }
        },
        .left => startDrag(cl, ev.root_x, ev.root_y, true, -1, 0),
        .right => startDrag(cl, ev.root_x, ev.root_y, true, 1, 0),
        .bottom => startDrag(cl, ev.root_x, ev.root_y, true, 0, 1),
        .bottom_left => startDrag(cl, ev.root_x, ev.root_y, true, -1, 1),
        .bottom_right => startDrag(cl, ev.root_x, ev.root_y, true, 1, 1),
        .none => {},
    }
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
        // -1 pulls the left or top edge, 1 the right or bottom, 0 leaves that axis alone.
        if (d.sx < 0) {
            nw = @max(min, d.orig.w - dx);
            nx = d.orig.x + (d.orig.w - nw);
        } else if (d.sx > 0) nw = @max(min, d.orig.w + dx);
        if (d.sy < 0) {
            nh = @max(min, d.orig.h - dy);
            ny = d.orig.y + (d.orig.h - nh);
        } else if (d.sy > 0) nh = @max(min, d.orig.h + dy);
        cl.x = nx;
        cl.y = ny;
        cl.w = nw;
        cl.h = nh;
    }
    place(cl, .{ .x = cl.x, .y = cl.y, .w = cl.w, .h = cl.h });
    // Dragged onto another monitor: it belongs to that one now (tiling and maximizing follow).
    cl.mon = @intCast(monitorOf(clientRect(cl)));
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
            // What the client asks for is the size of its own area; ours includes the frame around it.
            const ins = insetsOf(cl);
            if (cl.floating and !cl.maximized and !cl.fullscreen) {
                if (mask & c.XCB_CONFIG_WINDOW_X != 0) cl.x = ev.x - ins.l;
                if (mask & c.XCB_CONFIG_WINDOW_Y != 0) cl.y = ev.y - ins.t;
                if (mask & c.XCB_CONFIG_WINDOW_WIDTH != 0) cl.w = ev.width + ins.l + ins.r;
                if (mask & c.XCB_CONFIG_WINDOW_HEIGHT != 0) cl.h = ev.height + ins.t + ins.b;
            } else if (!cl.maximized and !cl.fullscreen and !tiledNow(cl)) {
                if (mask & c.XCB_CONFIG_WINDOW_WIDTH != 0) cl.w = ev.width + ins.l + ins.r;
                if (mask & c.XCB_CONFIG_WINDOW_HEIGHT != 0) cl.h = ev.height + ins.t + ins.b;
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
    const cl = findClient(ev.window) orelse return;
    // The frame being hidden by us is not the client leaving.
    if (cl.frame != 0 and ev.window == cl.frame) {
        if (ev.event == root and cl.ignore_unmap > 0) cl.ignore_unmap -= 1;
        return;
    }
    // The client's own unmap is reported to its frame (framed) or to the root; only one copy counts.
    const expected = if (cl.frame != 0) cl.frame else root;
    if (ev.event != expected) return;
    if (cl.frame == 0 and cl.ignore_unmap > 0) {
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
    if (ev.atom == atom(._NET_WM_NAME) or ev.atom == c.XCB_ATOM_WM_NAME) {
        readTitle(cl);
        redrawFrame(cl);
    }
    if (ev.atom == atom(.WM_PROTOCOLS)) readProtocols(cl);
    if (ev.atom == c.XCB_ATOM_WM_NORMAL_HINTS) {
        readSizeHints(cl);
        arrange();
    }
    // GTK announces its own frame after it has mapped the window.
    if (cl.kind == .normal and (ev.atom == atom(._GTK_FRAME_EXTENTS) or ev.atom == atom(._MOTIF_WM_HINTS))) {
        readBorder(cl);
        arrange();
    }
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
    if (findClient(ev.event)) |cl| {
        if (cl.frame != 0 and ev.event == cl.frame) {
            onFramePress(cl, ev);
            return;
        }
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
        c.XCB_EXPOSE => {
            const e: *const c.xcb_expose_event_t = @ptrCast(ev);
            if (e.count == 0) if (findClient(e.window)) |cl| if (cl.frame != 0 and e.window == cl.frame) redrawFrame(cl);
        },
        c.XCB_ENTER_NOTIFY => {
            const e: *const c.xcb_enter_notify_event_t = @ptrCast(ev);
            // Only real movement into a window (not a grab ending, not a move into a child).
            if (cfg.focus_follows_mouse and e.mode == c.XCB_NOTIFY_MODE_NORMAL and e.detail != c.XCB_NOTIFY_DETAIL_INFERIOR and drag == null) {
                if (findClient(e.event)) |cl| focusOnly(cl);
            }
        },
        c.XCB_MOTION_NOTIFY => {
            const m: *const c.xcb_motion_notify_event_t = @ptrCast(ev);
            dragMotion(m.root_x, m.root_y);
        },
        c.XCB_MAPPING_NOTIFY => {
            loadKeyboard();
            buildBindings(cfg.keys);
        },
        else => if (randr_event_base) |base| {
            const t = ev.response_type & 0x7f;
            if (t == base or t == base + 1) onScreenChanged();
        },
    }
}

// ---- screen changes (XRandR) --------------------------------------------------------------------------------

var randr_event_base: ?u8 = null;

fn selectScreenChanges() void {
    const data = c.xcb_get_extension_data(conn, &c.xcb_randr_id) orelse return;
    if (data.*.present == 0) return;
    randr_event_base = data.*.first_event;
    // Screen, CRTC and output changes.
    _ = c.xcb_randr_select_input(conn, root, c.XCB_RANDR_NOTIFY_MASK_SCREEN_CHANGE | c.XCB_RANDR_NOTIFY_MASK_CRTC_CHANGE | c.XCB_RANDR_NOTIFY_MASK_OUTPUT_CHANGE);
}

/// The screen or a monitor changed: read the layout again and put every window back within it.
fn onScreenChanged() void {
    const geo = c.xcb_get_geometry_reply(conn, c.xcb_get_geometry(conn, root), null) orelse return;
    defer std.c.free(geo);
    screen_w = geo.*.width;
    screen_h = geo.*.height;
    updateMonitors();
    for (clients.items) |cl| {
        if (cl.kind == .desktop) {
            cl.w = screen_w;
            cl.h = screen_h;
            configure(cl.win, screenRect());
        } else if (cl.kind == .normal) {
            cl.mon = @intCast(monitorOf(clientRect(cl)));
            if (!cl.maximized and !cl.fullscreen) {
                // A floating window that is now off its monitor comes back onto it.
                const m = monitors[monitorFor(cl)].work;
                cl.w = @min(cl.w, m.w);
                cl.h = @min(cl.h, m.h);
                cl.x = std.math.clamp(cl.x, m.x, @max(m.x + m.w - cl.w, m.x));
                cl.y = std.math.clamp(cl.y, m.y, @max(m.y + m.h - cl.h, m.y));
            }
        }
    }
    publishDesktops();
    arrange();
}

// ---- settings that change while running ---------------------------------------------------------------------

var config_fd: c_int = -1;
var config_name_buf: [256]u8 = undefined;
var config_name: []const u8 = "compositor.toml";

/// Words that are safe to hand to `setxkbmap` and `xset` through the shell.
fn plainWord(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == ',' or ch == ':' or ch == '(' or ch == ')' or ch == '+' or ch == '-' or ch == '.')) return false;
    return true;
}

/// Keyboard layout and key repeat from `[input]`; X11 takes them from setxkbmap and xset.
fn applyInput() void {
    const in = cfg.input;
    if (in.layout) |kb_layout| {
        if (!plainWord(kb_layout)) {
            warn("[input] layout {s}: only letters, digits and ,:()+-. are accepted", .{kb_layout});
        } else {
            var cmd: std.ArrayList(u8) = .empty;
            defer cmd.deinit(gpa);
            cmd.print(gpa, "setxkbmap {s}", .{kb_layout}) catch return;
            if (in.variant) |v| if (plainWord(v)) cmd.print(gpa, " -variant {s}", .{v}) catch return;
            if (in.options) |o| if (plainWord(o)) cmd.print(gpa, " -option '' -option {s}", .{o}) catch return;
            runCommand(cmd.items);
        }
    }
    var rate: [64]u8 = undefined;
    if (std.fmt.bufPrint(&rate, "xset r rate {d} {d}", .{ in.repeat_delay, in.repeat_rate })) |cmd| runCommand(cmd) else |_| {}
}

/// Reads compositor.toml again and applies what changed: desktops, layout policy, shortcuts, keyboard.
fn reloadConfig() void {
    const before_policy = cfg.policy;
    loadConfig();
    ws_count = std.math.clamp(cfg.workspaces, 1, 9);
    if (cfg.policy != before_policy) @memset(&ws_policy, cfg.policy);
    if (ws_current >= ws_count) ws_current = @intCast(ws_count - 1);
    for (clients.items) |cl| if (cl.kind == .normal and cl.ws >= ws_count) {
        cl.ws = @intCast(ws_count - 1);
    };
    buildBindings(cfg.keys);
    applyInput();
    // Focus following the mouse can be switched on or off while running.
    for (clients.items) |cl| if (cl.kind == .normal) {
        _ = c.xcb_change_window_attributes(conn, cl.win, c.XCB_CW_EVENT_MASK, &[_]u32{clientEventMask()});
    };
    publishDesktops();
    arrange();
    focusTop();
}

fn watchConfig() void {
    var path_buf: [1024]u8 = undefined;
    const path = configPath(&path_buf) orelse return;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    var dir_buf: [1024]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{path[0..slash]}, 0) catch return;
    _ = c.mkdir(dir.ptr, 0o755);
    // The file's own name: DKDE_COMPOSITOR_CONFIG may point at another.
    const base = path[slash + 1 ..];
    if (base.len > config_name_buf.len) return;
    @memcpy(config_name_buf[0..base.len], base);
    config_name = config_name_buf[0..base.len];
    const fd = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
    if (fd < 0) return;
    if (c.inotify_add_watch(fd, dir.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO) < 0) {
        _ = c.close(fd);
        return;
    }
    config_fd = fd;
}

/// True when compositor.toml was among the files written.
fn configFileChanged() bool {
    var buf: [4096]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
    var changed = false;
    while (true) {
        const n = c.read(config_fd, &buf, buf.len);
        if (n <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const ev: *const c.struct_inotify_event = @ptrCast(@alignCast(&buf[off]));
            const name_ptr: [*]const u8 = @ptrCast(&buf[off + @sizeOf(c.struct_inotify_event)]);
            if (ev.len > 0 and std.mem.eql(u8, std.mem.sliceTo(name_ptr[0..ev.len], 0), config_name)) changed = true;
            off += @sizeOf(c.struct_inotify_event) + ev.len;
        }
    }
    return changed;
}

fn onSignal(_: c_int) callconv(.c) void {
    running = false;
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
    config.free(gpa, cfg);
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
    monitors[0] = .{ .rect = .{ .x = 0, .y = 0, .w = screen_w, .h = screen_h }, .work = .{ .x = 0, .y = 0, .w = screen_w, .h = screen_h } };
    monitor_count = 1;

    // Becoming the window manager: only one client may select this on the root.
    const mask = c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | c.XCB_EVENT_MASK_PROPERTY_CHANGE |
        c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_KEY_RELEASE | c.XCB_EVENT_MASK_BUTTON_PRESS;
    const cookie = c.xcb_change_window_attributes_checked(conn, root, c.XCB_CW_EVENT_MASK, &[_]u32{mask});
    if (c.xcb_request_check(conn, cookie)) |err| {
        std.c.free(err);
        warn("another window manager is already running", .{});
        std.process.exit(1);
    }

    // SIG_IGN is (handler)1; musl's header form does not translate, so it is written out.
    const sig_ign: *align(1) const fn (c_int) callconv(.c) void = @ptrFromInt(1);
    _ = c.signal(c.SIGCHLD, sig_ign);
    // SIGTERM ends the session (Settings' "Log Off"). No SA_RESTART, so the poll below wakes up.
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGINT, onSignal);
    // Programs started from here learn who runs the session.
    _ = c.setenv("DKDE_SESSION_COMPOSITOR", "dkde-wm", 1);
    var pid_buf: [24]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&pid_buf, "{d}", .{c.getpid()}, 0)) |pid| _ = c.setenv("DKDE_SESSION_PID", pid.ptr, 1) else |_| {}
    internAtoms();
    loadConfig();
    ws_count = std.math.clamp(cfg.workspaces, 1, 9);
    @memset(&ws_policy, cfg.policy);
    loadKeyboard();
    buildBindings(cfg.keys);
    visual = deco.rootVisual(screen);
    setCursor();
    selectScreenChanges();
    updateMonitors();
    watchConfig();
    applyInput();
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

    // Events from the X server, and the settings file changing, wake the loop; a signal ends it.
    var fds = [2]c.struct_pollfd{
        .{ .fd = c.xcb_get_file_descriptor(conn), .events = c.POLLIN, .revents = 0 },
        .{ .fd = config_fd, .events = c.POLLIN, .revents = 0 },
    };
    while (running) {
        while (c.xcb_poll_for_event(conn)) |ev| {
            defer std.c.free(ev);
            handle(ev);
        }
        if (c.xcb_connection_has_error(conn) != 0) break;
        _ = c.xcb_flush(conn);
        _ = c.poll(&fds, if (config_fd >= 0) 2 else 1, -1);
        if (config_fd >= 0 and fds[1].revents & c.POLLIN != 0 and configFileChanged()) reloadConfig();
    }
    clearBindings();
    _ = c.xcb_flush(conn);
    c.xcb_disconnect(conn);
}

test {
    _ = layout;
}
