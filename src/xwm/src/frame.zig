//! The title bar and borders drawn around windows that draw no frame of their own
//! (xterm and the like; DKDE's GTK programs draw theirs). The geometry and the
//! hit test are plain functions so they can be tested; drawing uses cairo and
//! pango on an XCB surface, so the text is antialiased like the rest of DKDE.

const std = @import("std");
const c = @import("c");
const look_mod = @import("look.zig");

pub const title_h: i32 = 30;
/// The resize border at the sides and the bottom.
pub const edge: i32 = 4;
const button_w: i32 = 38;

pub const Hit = enum { none, title, minimize, maximize, close, left, right, bottom, bottom_left, bottom_right };

/// How much the frame adds around the client: left, right, top, bottom.
pub const Insets = struct { l: i32, r: i32, t: i32, b: i32 };

pub fn insets(maximized: bool, fullscreen: bool) Insets {
    if (fullscreen) return .{ .l = 0, .r = 0, .t = 0, .b = 0 };
    // A maximized window has no resize border to waste room on.
    if (maximized) return .{ .l = 0, .r = 0, .t = title_h, .b = 0 };
    return .{ .l = edge, .r = edge, .t = title_h, .b = edge };
}

/// What is under (x, y) in a frame `w` by `h` pixels.
pub fn hit(w: i32, h: i32, x: i32, y: i32, maximized: bool) Hit {
    if (x < 0 or y < 0 or x >= w or y >= h) return .none;
    if (y < title_h) {
        // Buttons at the right end of the title bar: minimize, maximize, close.
        const from_right = w - x;
        if (from_right <= button_w) return .close;
        if (from_right <= 2 * button_w) return .maximize;
        if (from_right <= 3 * button_w) return .minimize;
        return .title;
    }
    if (maximized) return .none;
    const left = x < edge;
    const right = x >= w - edge;
    const bottom = y >= h - edge;
    if (bottom and left) return .bottom_left;
    if (bottom and right) return .bottom_right;
    if (bottom) return .bottom;
    if (left) return .left;
    if (right) return .right;
    return .none;
}

test "the title bar buttons sit at the right end, the edges resize" {
    try std.testing.expectEqual(Hit.close, hit(400, 300, 399, 10, false));
    try std.testing.expectEqual(Hit.maximize, hit(400, 300, 400 - button_w - 5, 10, false));
    try std.testing.expectEqual(Hit.minimize, hit(400, 300, 400 - 2 * button_w - 5, 10, false));
    try std.testing.expectEqual(Hit.title, hit(400, 300, 50, 10, false));
    try std.testing.expectEqual(Hit.none, hit(400, 300, 200, 100, false));
    try std.testing.expectEqual(Hit.left, hit(400, 300, 1, 100, false));
    try std.testing.expectEqual(Hit.bottom_right, hit(400, 300, 399, 299, false));
    try std.testing.expectEqual(Hit.bottom, hit(400, 300, 200, 298, false));
    // Maximized: no resize edges, the title bar stays.
    try std.testing.expectEqual(Hit.none, hit(400, 300, 1, 100, true));
    try std.testing.expectEqual(Hit.close, hit(400, 300, 399, 10, true));
    try std.testing.expectEqual(Hit.none, hit(400, 300, 500, 10, false));
}

test "insets" {
    try std.testing.expectEqual(@as(i32, 0), insets(false, true).t);
    try std.testing.expectEqual(@as(i32, 0), insets(true, false).l);
    try std.testing.expectEqual(title_h, insets(false, false).t);
}

/// The visual of the root window, which cairo needs to draw on a window.
pub fn rootVisual(screen: *c.xcb_screen_t) ?*c.xcb_visualtype_t {
    var depth_it = c.xcb_screen_allowed_depths_iterator(screen);
    while (depth_it.rem > 0) : (c.xcb_depth_next(&depth_it)) {
        var vis_it = c.xcb_depth_visuals_iterator(depth_it.data);
        while (vis_it.rem > 0) : (c.xcb_visualtype_next(&vis_it)) {
            if (vis_it.data.*.visual_id == screen.*.root_visual) return vis_it.data;
        }
    }
    return null;
}

/// Draws the whole frame: edge, title bar, title, and the three buttons.
pub fn draw(conn: *c.xcb_connection_t, visual: *c.xcb_visualtype_t, win: c.xcb_window_t, w: i32, h: i32, title: []const u8, focused: bool, maximized: bool, look: *const look_mod.Look) void {
    const surface = c.cairo_xcb_surface_create(conn, win, visual, w, h) orelse return;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return;
    defer c.cairo_destroy(cr);
    const col = look_mod.colors(look, focused);

    // The edge colour everywhere, then the title bar over the top part.
    c.cairo_set_source_rgb(cr, col.edge[0], col.edge[1], col.edge[2]);
    c.cairo_paint(cr);
    c.cairo_set_source_rgb(cr, col.bar[0], col.bar[1], col.bar[2]);
    c.cairo_rectangle(cr, 0, 0, @floatFromInt(w), title_h);
    c.cairo_fill(cr);

    // The title, left aligned, cut with an ellipsis before the buttons.
    const layout = c.pango_cairo_create_layout(cr) orelse return;
    defer c.g_object_unref(layout);
    // The interface font from the shared look, in bold; Sans 10 when none is set.
    var font_name: [112]u8 = undefined;
    const wanted = if (look.font().len > 0) look.font() else "Sans 10";
    const font_z = std.fmt.bufPrintSentinel(&font_name, "{s}", .{wanted}, 0) catch "Sans 10";
    const font = c.pango_font_description_from_string(font_z.ptr);
    defer c.pango_font_description_free(font);
    c.pango_font_description_set_weight(font, c.PANGO_WEIGHT_BOLD);
    c.pango_layout_set_font_description(layout, font);
    c.pango_layout_set_text(layout, title.ptr, @intCast(title.len));
    c.pango_layout_set_ellipsize(layout, c.PANGO_ELLIPSIZE_END);
    c.pango_layout_set_width(layout, (w - 3 * button_w - 20) * c.PANGO_SCALE);
    var tw: c_int = 0;
    var th: c_int = 0;
    c.pango_layout_get_pixel_size(layout, &tw, &th);
    c.cairo_set_source_rgb(cr, col.text[0], col.text[1], col.text[2]);
    c.cairo_move_to(cr, 12, @floatFromInt(@divFloor(title_h - th, 2)));
    c.pango_cairo_show_layout(cr, layout);

    // The buttons: a line, a box (two overlapping when maximized) and a cross.
    c.cairo_set_line_width(cr, 1.5);
    const fw: f64 = @floatFromInt(w);
    const cy: f64 = @as(f64, title_h) / 2;
    const bw: f64 = button_w;
    // Close.
    const cx = fw - bw / 2;
    c.cairo_move_to(cr, cx - 5, cy - 5);
    c.cairo_line_to(cr, cx + 5, cy + 5);
    c.cairo_move_to(cr, cx + 5, cy - 5);
    c.cairo_line_to(cr, cx - 5, cy + 5);
    c.cairo_stroke(cr);
    // Maximize or restore.
    const mx = fw - bw - bw / 2;
    if (maximized) {
        c.cairo_rectangle(cr, mx - 3.5, cy - 2.5, 7, 7);
        c.cairo_rectangle(cr, mx - 1.5, cy - 5.5, 7, 7);
    } else {
        c.cairo_rectangle(cr, mx - 5, cy - 5, 10, 10);
    }
    c.cairo_stroke(cr);
    // Minimize.
    const nx = fw - 2 * bw - bw / 2;
    c.cairo_move_to(cr, nx - 5, cy + 4);
    c.cairo_line_to(cr, nx + 5, cy + 4);
    c.cairo_stroke(cr);
    c.cairo_surface_flush(surface);
}
