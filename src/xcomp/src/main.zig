//! dkde-xcomp: DKDE's X11 compositing manager. It runs next to a window manager (dkde-wm, or any other that
//! sets _NET_WM_WINDOW_OPACITY and the EWMH desktop properties), takes over drawing the screen, and adds the
//! effects the compositor has on Wayland that need a compositing manager on X11: real window opacity, fades and
//! growing on open and close, blur behind translucent windows, the workspace cube, zoom, colour filters, the
//! lens, water ripples, motion blur, snow and the pointer finder. The effects code and settings are the
//! compositor's own (src/compositor/src, shared); this file is the X side: tracking windows, getting their
//! pictures, and the frame loop. The drawing is in gl.zig.
//!
//! How it works: every window that is a child of the root is redirected (the X server keeps its picture off
//! screen), the Composite overlay window is drawn on by EGL/GLES2, and a window's picture is fetched with
//! GetImage when the Damage extension says it changed. Not done here: Scale, Expo, the Alt+Tab ring, wobbly
//! windows, the shelf, fire and paint (they need the window manager's help with pointer input).

const std = @import("std");
const c = @import("c");
const shared = @import("shared");
const gl = @import("gl.zig");

const anim = shared.anim;
const config = shared.config;
const filters = shared.filters;
const snow_mod = shared.snow;
const cube_mod = shared.cube;
const fx = shared.fx;

const version = "0.3.6";
const gpa = std.heap.c_allocator;

var debug_on = false;

fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("dkde-xcomp: " ++ fmt ++ "\n", args);
}

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (debug_on) std.debug.print("dkde-xcomp: " ++ fmt ++ "\n", args);
}

// ---- state ------------------------------------------------------------------------------------------------

/// A top-level window (a child of the root): a client's frame, a panel, a menu.
const Win = struct {
    id: c.xcb_window_t,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    border: i32 = 0,
    mapped: bool = false,
    damage: c.xcb_damage_damage_t = 0,
    /// Its picture, as it was last fetched; tw/th are what the texture holds.
    tex: c.GLuint = 0,
    tw: i32 = 0,
    th: i32 = 0,
    has_alpha: bool = false,
    /// The whole picture must be fetched again (it was just mapped or resized).
    full: bool = true,
    /// The part damaged since the last fetch, in window coordinates; empty when dw is 0.
    dx: i32 = 0,
    dy: i32 = 0,
    dw: i32 = 0,
    dh: i32 = 0,
    opacity: f32 = 1,
    /// An open animation, while it runs.
    open: ?anim.Anim = null,
};

/// A window that closed, still drawn while it fades: it owns its last picture.
const Ghost = struct {
    tex: c.GLuint,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    has_alpha: bool,
    opacity: f32,
    start_ms: u32,
    duration_ms: u32,
};

var conn: *c.xcb_connection_t = undefined;
var screen: *c.xcb_screen_t = undefined;
var root: c.xcb_window_t = 0;
var overlay: c.xcb_window_t = 0;
var owner_window: c.xcb_window_t = 0;
var damage_event: u8 = 0;
var screen_w: i32 = 0;
var screen_h: i32 = 0;
var renderer: *gl.Renderer = undefined;
/// Compositing is on (the windows are redirected and drawn here); off, this only waits to be asked.
var active = false;
var gl_failed = false;
var screen_index: c_int = 0;

var wins: std.ArrayList(*Win) = .empty;
var ghosts: std.ArrayList(Ghost) = .empty;
var layers: std.ArrayList(gl.Layer) = .empty;
var running = true;

var cfg: config.Config = .{};

var a_opacity: c.xcb_atom_t = 0;
var a_current_desktop: c.xcb_atom_t = 0;
var a_number_of_desktops: c.xcb_atom_t = 0;
var a_rootpmap: c.xcb_atom_t = 0;
var a_esetroot: c.xcb_atom_t = 0;
var a_request: c.xcb_atom_t = 0;

/// The root's background picture, if the session set one (_XROOTPMAP_ID).
var bg_tex: c.GLuint = 0;

// Effect state.
var ws_current: usize = 0;
var ws_count: usize = 4;
var cube_turn: ?struct { from: usize, to: usize, start_ms: u32 } = null;
/// Window animations made just before a workspace change (the window manager unmapping and mapping windows) are
/// not shown when the cube turns instead.
var quiet_until: u32 = 0;
var zoom_now: f32 = 1;
var zoom_target: f32 = 1;
var zoom_ms: u32 = 0;
var filter: filters.Filter = .none;
var lens_on = false;
var finder_ms: u32 = 0;
var motion_ms: u32 = 0;
var snow: ?snow_mod.Snow = null;
var snow_ms: u32 = 0;
var ripples: [fx.Post.max_ripples]struct { x: f32 = 0, y: f32 = 0, start_ms: u32 = 0, live: bool = false } = @splat(.{});
var ripple_last: [2]i32 = .{ -1000, -1000 };

var need_paint = true;
var animating = false;
var last_paint_ms: u32 = 0;

// ---- time -------------------------------------------------------------------------------------------------

fn nowMs() u32 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const ms: i64 = @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    return @truncate(@as(u64, @bitCast(ms)));
}

// ---- X helpers --------------------------------------------------------------------------------------------

fn intern(name: []const u8) c.xcb_atom_t {
    const reply = c.xcb_intern_atom_reply(conn, c.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr), null) orelse return 0;
    defer std.c.free(reply);
    return reply.*.atom;
}

fn cardinal(win: c.xcb_window_t, prop: c.xcb_atom_t) ?u32 {
    const reply = c.xcb_get_property_reply(conn, c.xcb_get_property(conn, 0, win, prop, c.XCB_ATOM_CARDINAL, 0, 1), null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len < 1) return null;
    const data: [*]const u32 = @ptrCast(@alignCast(c.xcb_get_property_value(reply)));
    return data[0];
}

fn cardinals(win: c.xcb_window_t, prop: c.xcb_atom_t, out: []u32) usize {
    const reply = c.xcb_get_property_reply(conn, c.xcb_get_property(conn, 0, win, prop, c.XCB_ATOM_CARDINAL, 0, @intCast(out.len)), null) orelse return 0;
    defer std.c.free(reply);
    if (reply.*.format != 32) return 0;
    const n = @min(out.len, reply.*.value_len);
    const data: [*]const u32 = @ptrCast(@alignCast(c.xcb_get_property_value(reply)));
    @memcpy(out[0..n], data[0..n]);
    return n;
}

// ---- windows ----------------------------------------------------------------------------------------------

fn findWin(id: c.xcb_window_t) ?*Win {
    for (wins.items) |w| if (w.id == id) return w;
    return null;
}

fn indexOf(w: *Win) ?usize {
    for (wins.items, 0..) |o, i| if (o == w) return i;
    return null;
}

fn readOpacity(w: *Win) void {
    if (cardinal(w.id, a_opacity)) |v| {
        w.opacity = @as(f32, @floatFromInt(v)) / 4294967295.0;
    } else {
        w.opacity = 1;
    }
}

/// Starts tracking a child of the root (its geometry and state are read here).
fn addWin(id: c.xcb_window_t) ?*Win {
    if (id == overlay or id == owner_window or findWin(id) != null) return null;
    const attr = c.xcb_get_window_attributes_reply(conn, c.xcb_get_window_attributes(conn, id), null) orelse return null;
    defer std.c.free(attr);
    if (attr.*._class == c.XCB_WINDOW_CLASS_INPUT_ONLY) return null;
    const geo = c.xcb_get_geometry_reply(conn, c.xcb_get_geometry(conn, id), null) orelse return null;
    defer std.c.free(geo);
    const w = gpa.create(Win) catch return null;
    w.* = .{ .id = id, .x = geo.*.x, .y = geo.*.y, .w = geo.*.width, .h = geo.*.height, .border = geo.*.border_width };
    w.mapped = attr.*.map_state == c.XCB_MAP_STATE_VIEWABLE;
    w.has_alpha = geo.*.depth == 32;
    wins.append(gpa, w) catch {
        gpa.destroy(w);
        return null;
    };
    _ = c.xcb_change_window_attributes(conn, id, c.XCB_CW_EVENT_MASK, &[_]u32{c.XCB_EVENT_MASK_PROPERTY_CHANGE});
    w.damage = c.xcb_generate_id(conn);
    _ = c.xcb_damage_create(conn, w.damage, id, c.XCB_DAMAGE_REPORT_LEVEL_RAW_RECTANGLES);
    readOpacity(w);
    return w;
}

/// Stops tracking a window. Its last picture becomes a ghost that fades, when animations are on and it was showing.
fn dropWin(w: *Win, animate: bool) void {
    const was_showing = w.mapped and w.tex != 0;
    if (animate and was_showing and cfg.effects.animations and nowMs() >= quiet_until) {
        ghosts.append(gpa, .{ .tex = w.tex, .x = w.x + w.border, .y = w.y + w.border, .w = w.tw, .h = w.th, .has_alpha = w.has_alpha, .opacity = w.opacity, .start_ms = nowMs(), .duration_ms = cfg.effects.animation_ms }) catch renderer.deleteTexture(w.tex);
    } else {
        renderer.deleteTexture(w.tex);
    }
    w.tex = 0;
    if (indexOf(w)) |i| _ = wins.orderedRemove(i);
    gpa.destroy(w);
    need_paint = true;
}

fn mapWin(w: *Win) void {
    if (w.mapped) return;
    w.mapped = true;
    w.full = true;
    w.dw = 0;
    if (cfg.effects.animations and nowMs() >= quiet_until) w.open = .{ .kind = .open, .start_ms = nowMs(), .duration_ms = cfg.effects.animation_ms };
    need_paint = true;
}

fn unmapWin(w: *Win) void {
    if (!w.mapped) return;
    w.mapped = false;
    if (w.tex != 0) {
        if (cfg.effects.animations and nowMs() >= quiet_until) {
            ghosts.append(gpa, .{ .tex = w.tex, .x = w.x + w.border, .y = w.y + w.border, .w = w.tw, .h = w.th, .has_alpha = w.has_alpha, .opacity = w.opacity, .start_ms = nowMs(), .duration_ms = cfg.effects.animation_ms }) catch renderer.deleteTexture(w.tex);
        } else {
            renderer.deleteTexture(w.tex);
        }
        w.tex = 0;
    }
    w.open = null;
    need_paint = true;
}

/// Puts `w` directly above `sibling` (0 = at the bottom).
fn restack(w: *Win, sibling: c.xcb_window_t) void {
    const from = indexOf(w) orelse return;
    _ = wins.orderedRemove(from);
    var at: usize = 0;
    if (sibling != 0) {
        for (wins.items, 0..) |o, i| if (o.id == sibling) {
            at = i + 1;
            break;
        };
    }
    wins.insert(gpa, at, w) catch wins.append(gpa, w) catch {};
}

fn scanTree() void {
    const tree = c.xcb_query_tree_reply(conn, c.xcb_query_tree(conn, root), null) orelse return;
    defer std.c.free(tree);
    const kids = c.xcb_query_tree_children(tree)[0..@intCast(c.xcb_query_tree_children_length(tree))];
    for (kids) |id| _ = addWin(id);
}

/// Redirecting a window that is already showing keeps only its own pixels, not its child windows' (a client
/// inside the window manager's frame): so every child is asked to paint again, with an Expose.
fn repaintClients() void {
    for (wins.items) |w| {
        const tree = c.xcb_query_tree_reply(conn, c.xcb_query_tree(conn, w.id), null) orelse continue;
        defer std.c.free(tree);
        const kids = c.xcb_query_tree_children(tree)[0..@intCast(c.xcb_query_tree_children_length(tree))];
        for (kids) |k| _ = c.xcb_clear_area(conn, 1, k, 0, 0, 0, 0);
    }
}

/// Fetches what changed of a window's picture and puts it in its texture.
fn refresh(w: *Win) void {
    if (!w.mapped or w.w <= 0 or w.h <= 0) return;
    if (w.tex == 0) {
        w.tex = renderer.newTexture();
        w.full = true;
    }
    if (w.w != w.tw or w.h != w.th) w.full = true;
    var rx: i32 = 0;
    var ry: i32 = 0;
    var rw: i32 = w.w;
    var rh: i32 = w.h;
    if (!w.full) {
        if (w.dw <= 0) return;
        rx = std.math.clamp(w.dx, 0, w.w - 1);
        ry = std.math.clamp(w.dy, 0, w.h - 1);
        rw = @min(w.dw, w.w - rx);
        rh = @min(w.dh, w.h - ry);
        if (rw <= 0 or rh <= 0) return;
    }
    // Clear the damage first: what is painted after this fetch raises it again.
    _ = c.xcb_damage_subtract(conn, w.damage, c.XCB_NONE, c.XCB_NONE);
    w.dw = 0;
    const cookie = c.xcb_get_image(conn, c.XCB_IMAGE_FORMAT_Z_PIXMAP, w.id, @intCast(rx), @intCast(ry), @intCast(rw), @intCast(rh), 0xffffffff);
    const reply = c.xcb_get_image_reply(conn, cookie, null) orelse {
        // The window went away or was resized meanwhile; the events say which.
        w.full = true;
        return;
    };
    defer std.c.free(reply);
    const len: usize = @intCast(c.xcb_get_image_data_length(reply));
    const need: usize = @as(usize, @intCast(rw)) * @as(usize, @intCast(rh)) * 4;
    if (len != need) {
        warn("window {x}: a {d}-bit picture is not handled", .{ w.id, reply.*.depth });
        return;
    }
    const data = c.xcb_get_image_data(reply)[0..len];
    debugLog("fetched {x} {d}x{d} at {d},{d} full={} depth={d} px0={x}", .{ w.id, rw, rh, rx, ry, w.full, reply.*.depth, @as(*align(1) const u32, @ptrCast(data.ptr)).* });
    w.has_alpha = reply.*.depth == 32;
    if (w.full) {
        renderer.setImage(gpa, w.tex, rw, rh, data);
        w.tw = rw;
        w.th = rh;
        w.full = false;
    } else {
        renderer.subImage(gpa, w.tex, rx, ry, rw, rh, data);
    }
}

fn loadBackground() void {
    renderer.deleteTexture(bg_tex);
    bg_tex = 0;
    const pm = cardinal(root, a_rootpmap) orelse cardinal(root, a_esetroot) orelse return;
    const geo = c.xcb_get_geometry_reply(conn, c.xcb_get_geometry(conn, pm), null) orelse return;
    defer std.c.free(geo);
    const reply = c.xcb_get_image_reply(conn, c.xcb_get_image(conn, c.XCB_IMAGE_FORMAT_Z_PIXMAP, pm, 0, 0, geo.*.width, geo.*.height, 0xffffffff), null) orelse return;
    defer std.c.free(reply);
    const len: usize = @intCast(c.xcb_get_image_data_length(reply));
    if (len != @as(usize, geo.*.width) * geo.*.height * 4) return;
    bg_tex = renderer.newTexture();
    renderer.setImage(gpa, bg_tex, geo.*.width, geo.*.height, c.xcb_get_image_data(reply)[0..len]);
}

// ---- effects ----------------------------------------------------------------------------------------------

fn pointer() [2]i32 {
    const reply = c.xcb_query_pointer_reply(conn, c.xcb_query_pointer(conn, root), null) orelse return .{ 0, 0 };
    defer std.c.free(reply);
    return .{ reply.*.root_x, reply.*.root_y };
}

fn zoomMoving() bool {
    return @abs(zoom_now - zoom_target) > 0.002;
}

fn tickZoom(now: u32) void {
    if (!zoomMoving()) {
        zoom_now = zoom_target;
        return;
    }
    const dt: f32 = @floatFromInt(@min(now -% zoom_ms, 100));
    zoom_ms = now;
    const k = 1 - std.math.pow(f32, 0.8, dt / 16.0);
    zoom_now += (zoom_target - zoom_now) * k;
}

fn zoomBy(factor: f32) void {
    if (!cfg.effects.zoom) return;
    zoom_target = std.math.clamp(zoom_target * factor, 1.0, 8.0);
    if (zoom_target < 1.05) zoom_target = 1.0;
    zoom_ms = nowMs();
    need_paint = true;
}

fn addRipple(now: u32, x: i32, y: i32) void {
    var slot: usize = 0;
    var oldest: u32 = 0;
    for (ripples, 0..) |r, i| {
        if (!r.live) {
            slot = i;
            break;
        }
        const age = now -% r.start_ms;
        if (age >= oldest) {
            oldest = age;
            slot = i;
        }
    }
    ripples[slot] = .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .start_ms = now, .live = true };
}

fn ripplesLive() bool {
    for (ripples) |r| if (r.live) return true;
    return false;
}

fn perform(req: fx.Request) void {
    switch (req) {
        .zoom_in => zoomBy(1.25),
        .zoom_out => zoomBy(0.8),
        .zoom_reset => {
            zoom_target = 1;
            zoom_ms = nowMs();
            need_paint = true;
        },
        .next_filter => {
            filter = filter.next();
            need_paint = true;
        },
        .show_pointer => {
            finder_ms = nowMs();
            need_paint = true;
        },
        .lens => if (cfg.effects.lens) {
            lens_on = !lens_on;
            need_paint = true;
        },
        _ => {},
    }
    if (!active) reconcile();
}

fn currentPost(now: u32) gl.Post {
    var p: gl.Post = .{};
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    var ptr_known = false;
    var ptr: [2]i32 = .{ 0, 0 };
    if (zoom_now > 1.001 or (lens_on and cfg.effects.lens)) {
        ptr = pointer();
        ptr_known = true;
    }
    // Screen fractions here are from the bottom, as GL has them.
    if (zoom_now > 1.001) {
        p.zoom = zoom_now;
        p.fx = std.math.clamp(@as(f32, @floatFromInt(ptr[0])) / sw, 0, 1);
        p.fy = std.math.clamp(1 - @as(f32, @floatFromInt(ptr[1])) / sh, 0, 1);
    }
    if (lens_on and cfg.effects.lens and ptr_known) {
        p.lens_x = std.math.clamp(@as(f32, @floatFromInt(ptr[0])) / sw, 0, 1);
        p.lens_y = std.math.clamp(1 - @as(f32, @floatFromInt(ptr[1])) / sh, 0, 1);
        p.lens_r = 0.2;
        p.lens_zoom = 2.5;
    }
    if (cfg.effects.water or ripplesLive()) {
        for (&ripples) |*r| {
            if (!r.live) continue;
            const f = anim.fraction(.{ .kind = .open, .start_ms = r.start_ms, .duration_ms = 1700 }, now);
            if (f >= 1) {
                r.live = false;
                continue;
            }
            p.ripples[p.ripple_count] = .{ r.x / sw, 1 - r.y / sh, 0.01 + 0.4 * anim.easeOut(f), 1 - f };
            p.ripple_count += 1;
        }
    }
    if (cfg.effects.motion_blur) {
        if (animating or cube_turn != null or zoomMoving()) motion_ms = now;
        const since = now -% motion_ms;
        if (motion_ms != 0 and since < 180) p.motion = 0.5 * (1 - @as(f32, @floatFromInt(since)) / 180.0);
    }
    if (filter != .none) {
        const m = filters.matrixFor(filter);
        p.m = fx.fromRows(m.rows);
        p.off = m.off;
    }
    return p;
}

fn currentCube(now: u32) ?gl.Cube {
    const turn = cube_turn orelse return null;
    const ms = @max(400, cfg.effects.animation_ms * 2);
    const f = anim.fraction(.{ .kind = .open, .start_ms = turn.start_ms, .duration_ms = ms }, now);
    if (f >= 1) {
        cube_turn = null;
        return null;
    }
    return .{
        .pos = cube_mod.position(turn.from, turn.to, ws_count, anim.easeOut(f)),
        .tilt = 0.28 * @sin(std.math.pi * f),
        .count = ws_count,
        .from = turn.from,
        .to = turn.to,
    };
}

fn onDesktopChanged() void {
    const now_ws: usize = @min(cardinal(root, a_current_desktop) orelse 0, 8);
    if (now_ws == ws_current) return;
    const from = ws_current;
    ws_current = now_ws;
    if (!cfg.effects.cube or ws_count < 3 or from >= ws_count or now_ws >= ws_count) return;
    const now = nowMs();
    // The window manager has unmapped and mapped windows for this change: they are not shown fading.
    quiet_until = now + 700;
    var i = ghosts.items.len;
    while (i > 0) : (i -= 1) {
        if (now -% ghosts.items[i - 1].start_ms < 400) {
            renderer.deleteTexture(ghosts.items[i - 1].tex);
            _ = ghosts.orderedRemove(i - 1);
        }
    }
    for (wins.items) |w| w.open = null;
    cube_turn = .{ .from = from, .to = now_ws, .start_ms = now };
    need_paint = true;
}

// ---- the frame --------------------------------------------------------------------------------------------

fn buildLayers(now: u32) void {
    layers.clearRetainingCapacity();
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    if (bg_tex != 0) layers.append(gpa, .{ .tex = bg_tex, .x = 0, .y = 0, .w = sw, .h = sh }) catch {};
    for (wins.items) |w| {
        if (!w.mapped or w.tex == 0) continue;
        const x: f32 = @floatFromInt(w.x + w.border);
        const y: f32 = @floatFromInt(w.y + w.border);
        const lw: f32 = @floatFromInt(w.tw);
        const lh: f32 = @floatFromInt(w.th);
        var xf: anim.Xf = .{ .ax = x + lw / 2, .ay = y + lh / 2 };
        if (w.open) |a| {
            xf = anim.at(a, now, x + lw / 2, y + lh / 2);
            if (anim.done(a, now)) w.open = null;
        }
        layers.append(gpa, .{ .tex = w.tex, .x = x, .y = y, .w = lw, .h = lh, .alpha = w.opacity, .has_alpha = w.has_alpha, .xf = xf, .blur = cfg.effects.blur and w.opacity < 0.995 }) catch {};
    }
    var i: usize = 0;
    while (i < ghosts.items.len) {
        const g = ghosts.items[i];
        const f = anim.fraction(.{ .kind = .open, .start_ms = g.start_ms, .duration_ms = g.duration_ms }, now);
        if (f >= 1) {
            renderer.deleteTexture(g.tex);
            _ = ghosts.orderedRemove(i);
            continue;
        }
        const p = anim.easeOut(f);
        const gx: f32 = @floatFromInt(g.x);
        const gy: f32 = @floatFromInt(g.y);
        const gw: f32 = @floatFromInt(g.w);
        const gh: f32 = @floatFromInt(g.h);
        layers.append(gpa, .{ .tex = g.tex, .x = gx, .y = gy, .w = gw, .h = gh, .alpha = g.opacity, .has_alpha = g.has_alpha, .xf = .{ .scale = 1 - 0.12 * p, .alpha = 1 - p, .ax = gx + gw / 2, .ay = gy + gh / 2 } }) catch {};
        i += 1;
    }
    // Snow and the pointer finder, over everything.
    if (cfg.effects.snow) {
        if (snow == null) snow = snow_mod.Snow.init(sw, sh, 160, @as(u64, now) | 1);
        const dt: f32 = @as(f32, @floatFromInt(@min(now -% snow_ms, 100))) / 1000.0;
        snow_ms = now;
        snow.?.step(dt, sw, sh);
        for (snow.?.flakes[0..snow.?.count]) |f| {
            const r = f.r * 1.8;
            layers.append(gpa, .{ .tex = renderer.dot_tex, .x = f.x - r, .y = f.y - r, .w = r * 2, .h = r * 2, .alpha = 0.5 + f.r * 0.1, .has_alpha = true }) catch break;
        }
    } else snow = null;
    if (finder_ms != 0) {
        const f = anim.fraction(.{ .kind = .open, .start_ms = finder_ms, .duration_ms = 900 }, now);
        if (f >= 1) {
            finder_ms = 0;
        } else {
            const ptr = pointer();
            const r = 30 + 160 * anim.easeOut(f);
            const px: f32 = @floatFromInt(ptr[0]);
            const py: f32 = @floatFromInt(ptr[1]);
            layers.append(gpa, .{ .tex = renderer.ring_tex, .x = px - r, .y = py - r, .w = r * 2, .h = r * 2, .alpha = 1 - f, .has_alpha = true, .tint = .{ 0.4, 0.7, 1 } }) catch {};
        }
    }
}

fn anyAnimation() bool {
    if (ghosts.items.len > 0 or cube_turn != null or zoomMoving() or ripplesLive() or finder_ms != 0 or cfg.effects.snow) return true;
    for (wins.items) |w| if (w.open != null) return true;
    return false;
}

fn paint() void {
    const now = nowMs();
    for (wins.items) |w| refresh(w);
    tickZoom(now);
    buildLayers(now);
    const post = currentPost(now);
    const cube = currentCube(now);
    const keep = cfg.effects.cube and cube == null;
    if (!renderer.frame(layers.items, post, cube, keep)) warn("a frame could not be drawn", .{});
    last_paint_ms = now;
    need_paint = false;
    animating = anyAnimation() or post.motion > 0;
}

// ---- events -----------------------------------------------------------------------------------------------

fn onDamage(ev: *const c.xcb_damage_notify_event_t) void {
    const w = findWin(ev.drawable) orelse return;
    if (!w.mapped) return;
    const a = ev.area;
    if (w.dw <= 0) {
        w.dx = a.x;
        w.dy = a.y;
        w.dw = a.width;
        w.dh = a.height;
    } else {
        const x0 = @min(w.dx, @as(i32, a.x));
        const y0 = @min(w.dy, @as(i32, a.y));
        const x1 = @max(w.dx + w.dw, @as(i32, a.x) + a.width);
        const y1 = @max(w.dy + w.dh, @as(i32, a.y) + a.height);
        w.dx = x0;
        w.dy = y0;
        w.dw = x1 - x0;
        w.dh = y1 - y0;
    }
    need_paint = true;
}

fn handle(ev: *c.xcb_generic_event_t) void {
    const kind = ev.response_type & 0x7f;
    if (!active) {
        // Waiting: only requests, and the desktop being tracked for the cube's sake.
        if (kind == c.XCB_CLIENT_MESSAGE) {
            const e: *c.xcb_client_message_event_t = @ptrCast(ev);
            if (e.type == a_request and e.format == 32) perform(@enumFromInt(e.data.data32[0]));
        } else if (kind == c.XCB_PROPERTY_NOTIFY) {
            const e: *c.xcb_property_notify_event_t = @ptrCast(ev);
            if (e.window == root and e.atom == a_current_desktop) ws_current = @min(cardinal(root, a_current_desktop) orelse 0, 8);
        }
        return;
    }
    if (kind == damage_event + c.XCB_DAMAGE_NOTIFY) {
        onDamage(@ptrCast(ev));
        return;
    }
    switch (kind) {
        c.XCB_CREATE_NOTIFY => {
            const e: *c.xcb_create_notify_event_t = @ptrCast(ev);
            if (e.parent == root) _ = addWin(e.window);
        },
        c.XCB_DESTROY_NOTIFY => {
            const e: *c.xcb_destroy_notify_event_t = @ptrCast(ev);
            if (findWin(e.window)) |w| dropWin(w, true);
        },
        c.XCB_REPARENT_NOTIFY => {
            const e: *c.xcb_reparent_notify_event_t = @ptrCast(ev);
            if (e.parent == root) {
                _ = addWin(e.window);
            } else if (findWin(e.window)) |w| dropWin(w, false);
        },
        c.XCB_MAP_NOTIFY => {
            const e: *c.xcb_map_notify_event_t = @ptrCast(ev);
            if (findWin(e.window)) |w| mapWin(w);
        },
        c.XCB_UNMAP_NOTIFY => {
            const e: *c.xcb_unmap_notify_event_t = @ptrCast(ev);
            if (findWin(e.window)) |w| unmapWin(w);
        },
        c.XCB_CONFIGURE_NOTIFY => {
            const e: *c.xcb_configure_notify_event_t = @ptrCast(ev);
            const w = findWin(e.window) orelse return;
            if (e.x != w.x or e.y != w.y) motion_ms = nowMs();
            if (e.width != w.w or e.height != w.h) w.full = true;
            w.x = e.x;
            w.y = e.y;
            w.w = e.width;
            w.h = e.height;
            w.border = e.border_width;
            restack(w, e.above_sibling);
            need_paint = true;
        },
        c.XCB_CIRCULATE_NOTIFY => {
            const e: *c.xcb_circulate_notify_event_t = @ptrCast(ev);
            const w = findWin(e.window) orelse return;
            restack(w, if (e.place == c.XCB_PLACE_ON_TOP and wins.items.len > 0) wins.items[wins.items.len - 1].id else 0);
            need_paint = true;
        },
        c.XCB_CLIENT_MESSAGE => {
            const e: *c.xcb_client_message_event_t = @ptrCast(ev);
            if (e.type == a_request and e.format == 32) perform(@enumFromInt(e.data.data32[0]));
        },
        c.XCB_PROPERTY_NOTIFY => {
            const e: *c.xcb_property_notify_event_t = @ptrCast(ev);
            if (e.window == root) {
                if (e.atom == a_current_desktop) onDesktopChanged();
                if (e.atom == a_rootpmap or e.atom == a_esetroot) {
                    loadBackground();
                    need_paint = true;
                }
                if (e.atom == a_number_of_desktops) ws_count = std.math.clamp(cardinal(root, a_number_of_desktops) orelse 4, 1, 9);
            } else if (e.atom == a_opacity) {
                if (findWin(e.window)) |w| {
                    readOpacity(w);
                    need_paint = true;
                }
            }
        },
        else => {},
    }
}

// ---- settings ---------------------------------------------------------------------------------------------

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
    filter = cfg.effects.filter;
    if (!cfg.effects.zoom) zoom_target = 1;
    if (!cfg.effects.lens) lens_on = false;
    gl_failed = false;
    need_paint = true;
    if (a_request != 0) reconcile();
}

var config_fd: c_int = -1;
var config_name_buf: [256]u8 = undefined;
var config_name: []const u8 = "compositor.toml";

fn watchConfig() void {
    var path_buf: [1024]u8 = undefined;
    const path = configPath(&path_buf) orelse return;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    var dir_buf: [1024]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{path[0..slash]}, 0) catch return;
    _ = c.mkdir(dir.ptr, 0o755);
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

fn configChanged() bool {
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

// ---- turning compositing on and off ------------------------------------------------------------------------

/// Some setting asks for what only a compositing manager can do: while none does, windows are drawn by the X
/// server itself, with no extra cost.
fn configWants() bool {
    const e = cfg.effects;
    if (e.animations or e.blur or e.cube or e.snow or e.zoom or e.lens or e.water or e.motion_blur or e.trailfocus or e.opacify) return true;
    if (cfg.inactive_opacity < 0.999 or filter != .none) return true;
    for (cfg.rules) |r| if (r.opacity != null) return true;
    return false;
}

/// Something is on the screen that needs it right now (a filter or zoom someone switched on with a key, ...).
fn runtimeWants() bool {
    return filter != .none or zoom_target > 1.001 or zoomMoving() or lens_on or finder_ms != 0 or ripplesLive() or ghosts.items.len > 0 or cube_turn != null;
}

fn wanted() bool {
    return configWants() or runtimeWants();
}

fn activate() void {
    if (active or gl_failed) return;
    const comp_v = c.xcb_composite_query_version_reply(conn, c.xcb_composite_query_version(conn, 0, 4), null) orelse {
        gl_failed = true;
        warn("the X server has no Composite extension: not compositing", .{});
        return;
    };
    const too_old = comp_v.*.major_version == 0 and comp_v.*.minor_version < 2;
    std.c.free(comp_v);
    if (too_old) {
        gl_failed = true;
        warn("Composite is older than 0.2 (no overlay window): not compositing", .{});
        return;
    }
    const ov = c.xcb_composite_get_overlay_window_reply(conn, c.xcb_composite_get_overlay_window(conn, root), null) orelse {
        gl_failed = true;
        warn("cannot get the composite overlay window: not compositing", .{});
        return;
    };
    overlay = ov.*.overlay_win;
    std.c.free(ov);
    // The overlay lets the pointer through to the windows below.
    const region = c.xcb_generate_id(conn);
    _ = c.xcb_xfixes_create_region(conn, region, 0, null);
    _ = c.xcb_xfixes_set_window_shape_region(conn, overlay, c.XCB_SHAPE_SK_INPUT, 0, 0, region);
    _ = c.xcb_xfixes_destroy_region(conn, region);
    ws_count = std.math.clamp(cardinal(root, a_number_of_desktops) orelse cfg.workspaces, 1, 9);
    ws_current = @min(cardinal(root, a_current_desktop) orelse 0, 8);
    renderer = gl.Renderer.init(gpa, conn, screen_index, overlay, screen.root_visual, screen_w, screen_h) orelse {
        _ = c.xcb_composite_release_overlay_window(conn, root);
        _ = c.xcb_flush(conn);
        gl_failed = true;
        warn("cannot start GLES2 drawing on the overlay window: not compositing", .{});
        return;
    };
    active = true;
    // Damage is watched before the windows are redirected: redirecting makes the clients paint again, and what
    // they paint in answer must not be missed.
    scanTree();
    _ = c.xcb_composite_redirect_subwindows(conn, root, c.XCB_COMPOSITE_REDIRECT_MANUAL);
    repaintClients();
    loadBackground();
    need_paint = true;
    _ = c.xcb_flush(conn);
    warn("compositing a {d}x{d} screen ({d} windows)", .{ screen_w, screen_h, wins.items.len });
    for (wins.items) |w| debugLog("  window {x} {d}x{d}+{d}+{d} mapped={}", .{ w.id, w.w, w.h, w.x, w.y, w.mapped });
}

fn deactivate() void {
    if (!active) return;
    active = false;
    for (wins.items) |w| {
        renderer.deleteTexture(w.tex);
        gpa.destroy(w);
    }
    wins.clearRetainingCapacity();
    for (ghosts.items) |g| renderer.deleteTexture(g.tex);
    ghosts.clearRetainingCapacity();
    renderer.deleteTexture(bg_tex);
    bg_tex = 0;
    renderer.destroy(gpa);
    _ = c.xcb_composite_unredirect_subwindows(conn, root, c.XCB_COMPOSITE_REDIRECT_MANUAL);
    _ = c.xcb_composite_release_overlay_window(conn, root);
    cube_turn = null;
    animating = false;
    need_paint = false;
    _ = c.xcb_flush(conn);
    warn("not compositing (no effect needs it now)", .{});
}

/// Starts or stops compositing to match what is wanted.
fn reconcile() void {
    if (active and !wanted()) {
        deactivate();
    } else if (!active and wanted()) activate();
}

fn onSignal(_: c_int) callconv(.c) void {
    running = false;
}

// ---- start ------------------------------------------------------------------------------------------------

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    warn(fmt, args);
    std.process.exit(1);
}

/// --version and --help answer on stdout, like every dkde program.
fn say(text: []const u8) void {
    _ = std.c.write(1, text.ptr, text.len);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            say("dkde-xcomp " ++ version ++ "\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            say("Usage: dkde-xcomp [--help] [--version]\n\nDKDE's X11 compositing manager: run it next to dkde-wm for window opacity, fades,\nblur, the workspace cube, zoom, colour filters and the lens. Settings:\n~/.config/dkde/compositor.toml (shared with dkde-compositor and dkde-wm).\n");
            return;
        }
        std.debug.print("dkde-xcomp: unknown option {s}\n", .{arg});
        std.process.exit(2);
    }
    const dev = shared.developer.read_file();
    shared.developer.redirectStderr(dev, "dkde-xcomp");
    debug_on = dev.debug();

    var screen_num: c_int = 0;
    conn = c.xcb_connect(null, &screen_num) orelse fail("cannot connect to the X server", .{});
    if (c.xcb_connection_has_error(conn) != 0) fail("cannot connect to the X server (is DISPLAY set?)", .{});
    var it = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn));
    var i: c_int = 0;
    while (i < screen_num) : (i += 1) c.xcb_screen_next(&it);
    screen = it.data;
    root = screen.root;
    screen_w = screen.width_in_pixels;
    screen_h = screen.height_in_pixels;

    // The extensions: each one has to be asked its version before it can be used.
    const comp_v = c.xcb_composite_query_version_reply(conn, c.xcb_composite_query_version(conn, 0, 4), null) orelse fail("the X server has no Composite extension", .{});
    if (comp_v.*.major_version == 0 and comp_v.*.minor_version < 2) fail("Composite is older than 0.2 (no overlay window)", .{});
    std.c.free(comp_v);
    const dmg_v = c.xcb_damage_query_version_reply(conn, c.xcb_damage_query_version(conn, 1, 1), null) orelse fail("the X server has no Damage extension", .{});
    std.c.free(dmg_v);
    const xf_v = c.xcb_xfixes_query_version_reply(conn, c.xcb_xfixes_query_version(conn, 2, 0), null) orelse fail("the X server has no XFixes extension", .{});
    std.c.free(xf_v);
    const dmg_ext = c.xcb_get_extension_data(conn, &c.xcb_damage_id) orelse fail("no Damage extension data", .{});
    damage_event = dmg_ext.*.first_event;

    // One compositing manager per screen: the selection says who it is.
    var sel_buf: [32]u8 = undefined;
    const sel_name = std.fmt.bufPrint(&sel_buf, "_NET_WM_CM_S{d}", .{screen_num}) catch unreachable;
    const a_sel = intern(sel_name);
    const owner = c.xcb_get_selection_owner_reply(conn, c.xcb_get_selection_owner(conn, a_sel), null) orelse fail("cannot read the compositing selection", .{});
    const taken = owner.*.owner != 0;
    std.c.free(owner);
    if (taken) fail("another compositing manager is already running", .{});
    owner_window = c.xcb_generate_id(conn);
    _ = c.xcb_create_window(conn, c.XCB_COPY_FROM_PARENT, owner_window, root, -10, -10, 1, 1, 0, c.XCB_WINDOW_CLASS_INPUT_OUTPUT, c.XCB_COPY_FROM_PARENT, 0, null);
    _ = c.xcb_set_selection_owner(conn, owner_window, a_sel, c.XCB_CURRENT_TIME);

    a_opacity = intern("_NET_WM_WINDOW_OPACITY");
    a_current_desktop = intern("_NET_CURRENT_DESKTOP");
    a_number_of_desktops = intern("_NET_NUMBER_OF_DESKTOPS");
    a_rootpmap = intern("_XROOTPMAP_ID");
    a_esetroot = intern("ESETROOT_PMAP_ID");
    a_request = intern(fx.request_message);

    screen_index = screen_num;
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGINT, onSignal);
    watchConfig();
    // Watch the root for requests and desktop changes; compositing starts when a setting wants it.
    _ = c.xcb_change_window_attributes(conn, root, c.XCB_CW_EVENT_MASK, &[_]u32{c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | c.XCB_EVENT_MASK_PROPERTY_CHANGE});
    warn("{s} starting", .{version});
    loadConfig();
    _ = c.xcb_flush(conn);

    var fds = [2]c.struct_pollfd{
        .{ .fd = c.xcb_get_file_descriptor(conn), .events = c.POLLIN, .revents = 0 },
        .{ .fd = config_fd, .events = c.POLLIN, .revents = 0 },
    };
    var water_ms: u32 = 0;
    while (running) {
        while (c.xcb_poll_for_event(conn)) |ev| {
            defer std.c.free(ev);
            handle(ev);
        }
        if (c.xcb_connection_has_error(conn) != 0) break;
        const now = nowMs();
        // Water: ripples start where the pointer has moved (sampled while the effect is on).
        if (active and cfg.effects.water and now -% water_ms >= 33) {
            water_ms = now;
            const ptr = pointer();
            const dx = ptr[0] - ripple_last[0];
            const dy = ptr[1] - ripple_last[1];
            if (dx * dx + dy * dy > 30 * 30) {
                ripple_last = ptr;
                addRipple(now, ptr[0], ptr[1]);
                need_paint = true;
            }
        }
        const frame_ms: u32 = 8;
        const since = now -% last_paint_ms;
        if (active and (need_paint or animating) and since >= frame_ms) paint();
        if (active and !need_paint and !animating and !wanted()) deactivate();
        _ = c.xcb_flush(conn);
        var timeout: c_int = -1;
        if (active and (need_paint or animating)) {
            timeout = @intCast(frame_ms -| (nowMs() -% last_paint_ms));
        } else if (active and cfg.effects.water) timeout = 33;
        _ = c.poll(&fds, if (config_fd >= 0) 2 else 1, timeout);
        if (config_fd >= 0 and fds[1].revents & c.POLLIN != 0 and configChanged()) loadConfig();
    }
    if (active) deactivate();
    _ = c.xcb_flush(conn);
    c.xcb_disconnect(conn);
}

test {
    _ = fx;
}
