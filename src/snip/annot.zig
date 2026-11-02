//! The geometry and the data of the screenshot editor (SPEC.md 5.6): the
//! selection and its handles, the annotations drawn over it, the numbers that
//! place the toolbar. Plain data and arithmetic with no GTK, so it is unit
//! tested; editor.zig draws and wires it. Everything is in image pixels, the
//! pixels of the frozen screen, whatever size the overlay window has.

const std = @import("std");

pub const Point = struct { x: f64, y: f64 };
pub const RectF = struct { x: f64, y: f64, w: f64, h: f64 };
pub const RectI = struct { x: i32, y: i32, w: i32, h: i32 };

/// The corners of a drag as a rectangle with positive size.
pub fn normalizeF(x0: f64, y0: f64, x1: f64, y1: f64) RectF {
    return .{ .x = @min(x0, x1), .y = @min(y0, y1), .w = @abs(x1 - x0), .h = @abs(y1 - y0) };
}

/// `r` moved and cut to lie inside a `bw` by `bh` image.
pub fn clampRect(r: RectF, bw: f64, bh: f64) RectF {
    const x0 = std.math.clamp(r.x, 0, bw);
    const y0 = std.math.clamp(r.y, 0, bh);
    const x1 = std.math.clamp(r.x + r.w, 0, bw);
    const y1 = std.math.clamp(r.y + r.h, 0, bh);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

pub fn toRectI(r: RectF) RectI {
    return .{
        .x = @intFromFloat(@round(r.x)),
        .y = @intFromFloat(@round(r.y)),
        .w = @intFromFloat(@round(r.w)),
        .h = @intFromFloat(@round(r.h)),
    };
}

// ---- the selection -------------------------------------------------------------------

pub const Handle = enum { none, inside, nw, n, ne, e, se, s, sw, w };

/// What the point `(px, py)` grabs of selection `r`: a corner or edge handle
/// within `tol` pixels, the inside to move it, or nothing.
pub fn hit(r: RectF, px: f64, py: f64, tol: f64) Handle {
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const left = r.x;
    const right = r.x + r.w;
    const top = r.y;
    const bottom = r.y + r.h;
    const near = struct {
        fn at(a: f64, b: f64, ta: f64, tb: f64, t: f64) bool {
            return @abs(a - ta) <= t and @abs(b - tb) <= t;
        }
    }.at;
    // Corners first, so a small selection can still be grabbed by them.
    if (near(px, py, left, top, tol)) return .nw;
    if (near(px, py, right, top, tol)) return .ne;
    if (near(px, py, right, bottom, tol)) return .se;
    if (near(px, py, left, bottom, tol)) return .sw;
    if (near(px, py, cx, top, tol)) return .n;
    if (near(px, py, right, cy, tol)) return .e;
    if (near(px, py, cx, bottom, tol)) return .s;
    if (near(px, py, left, cy, tol)) return .w;
    if (px >= left and px <= right and py >= top and py <= bottom) return .inside;
    return .none;
}

/// The selection `orig` after dragging `handle` by (dx, dy): resized by an
/// edge or corner, or moved by the inside. The result stays inside the image
/// and keeps at least one pixel.
pub fn dragSelection(orig: RectF, handle: Handle, dx: f64, dy: f64, bw: f64, bh: f64) RectF {
    var x0 = orig.x;
    var y0 = orig.y;
    var x1 = orig.x + orig.w;
    var y1 = orig.y + orig.h;
    switch (handle) {
        .none => return orig,
        .inside => {
            // Moved whole: the size stays, the position is kept in the image.
            const nx = std.math.clamp(orig.x + dx, 0, @max(0, bw - orig.w));
            const ny = std.math.clamp(orig.y + dy, 0, @max(0, bh - orig.h));
            return .{ .x = nx, .y = ny, .w = orig.w, .h = orig.h };
        },
        .nw => {
            x0 += dx;
            y0 += dy;
        },
        .n => y0 += dy,
        .ne => {
            x1 += dx;
            y0 += dy;
        },
        .e => x1 += dx,
        .se => {
            x1 += dx;
            y1 += dy;
        },
        .s => y1 += dy,
        .sw => {
            x0 += dx;
            y1 += dy;
        },
        .w => x0 += dx,
    }
    // Dragging an edge past the opposite one turns the rectangle over.
    var r = normalizeF(x0, y0, x1, y1);
    r = clampRect(r, bw, bh);
    if (r.w < 1) r.w = @min(1, bw - r.x);
    if (r.h < 1) r.h = @min(1, bh - r.y);
    return r;
}

/// The cursor name a handle wants.
pub fn cursorFor(h: Handle) [:0]const u8 {
    return switch (h) {
        .nw, .se => "nwse-resize",
        .ne, .sw => "nesw-resize",
        .n, .s => "ns-resize",
        .e, .w => "ew-resize",
        .inside => "move",
        .none => "crosshair",
    };
}

/// Where the top-left corner of a `bar_w` by `bar_h` toolbar goes: just below
/// the selection, flush with its right edge; above it when there is no room
/// below; inside it at the bottom when there is no room either. Always on screen.
pub fn barPosition(sel: RectF, bar_w: f64, bar_h: f64, screen_w: f64, screen_h: f64) Point {
    const gap = 8.0;
    var x = sel.x + sel.w - bar_w;
    var y = sel.y + sel.h + gap;
    if (y + bar_h > screen_h) {
        y = sel.y - bar_h - gap;
        if (y < 0) y = sel.y + sel.h - bar_h - gap;
    }
    x = std.math.clamp(x, 0, @max(0, screen_w - bar_w));
    y = std.math.clamp(y, 0, @max(0, screen_h - bar_h));
    return .{ .x = x, .y = y };
}

// ---- the annotations ---------------------------------------------------------------------

pub const Tool = enum { select, pen, line, arrow, rect, ellipse, marker, pixelate, text, counter };

pub const Shape = struct {
    tool: Tool,
    /// 0xRRGGBB.
    color: u32,
    width: f64,
    /// Two corners: a line, an arrow, a rectangle, an ellipse, a pixelated box.
    /// The one position of a text or a counter is `a`.
    a: Point = .{ .x = 0, .y = 0 },
    b: Point = .{ .x = 0, .y = 0 },
    /// A freehand stroke (pen, marker); owned by whoever made the shape.
    points: []Point = &.{},
    text: []const u8 = "",
    number: u32 = 0,
};

pub const min_width: f64 = 1;
pub const max_width: f64 = 40;
pub const default_width: f64 = 3;

/// The thickness after a wheel step: up for a forward step, within limits.
pub fn stepWidth(width: f64, wheel_dy: f64) f64 {
    const next = if (wheel_dy < 0) width + 1 else width - 1;
    return std.math.clamp(next, min_width, max_width);
}

/// The palette of the toolbar, as 0xRRGGBB.
pub const palette = [_]u32{
    0xE53935, // red
    0xFB8C00, // orange
    0xFDD835, // yellow
    0x43A047, // green
    0x00ACC1, // cyan
    0x1E88E5, // blue
    0x8E24AA, // purple
    0xFFFFFF, // white
    0x000000, // black
};

/// The number the next counter shows: one more than the highest so far, so
/// undoing a counter lets the next one reuse its number.
pub fn nextCounter(shapes: []const Shape) u32 {
    var n: u32 = 0;
    for (shapes) |s| {
        if (s.tool == .counter and s.number > n) n = s.number;
    }
    return n + 1;
}

/// The two ends of an arrow's head: wings that trail back from the tip `b` of
/// the line `a` to `b`, spread to either side. They scale with the thickness.
pub fn arrowWings(a: Point, b: Point, width: f64) [2]Point {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return .{ b, b };
    const ux = dx / len;
    const uy = dy / len;
    // At least a visible head; longer for thicker lines; never longer than the line.
    const head = @min(len, @max(10, width * 4 + 6));
    const spread = 0.45; // radians, about 26 degrees
    const c = @cos(spread);
    const s = @sin(spread);
    return .{
        .{ .x = b.x - head * (ux * c - uy * s), .y = b.y - head * (uy * c + ux * s) },
        .{ .x = b.x - head * (ux * c + uy * s), .y = b.y - head * (uy * c - ux * s) },
    };
}

/// The block size of a pixelated box for a thickness.
pub fn pixelBlock(width: f64) i32 {
    return @intFromFloat(std.math.clamp(@round(width * 2 + 4), 4, 60));
}

/// Replaces `rect` of a picture with blocks of their average colour: the
/// "pixelate" tool. `px` holds rows of `channels` bytes per pixel (3 or 4;
/// an alpha channel is averaged like the others), `stride` bytes apart.
pub fn pixelate(px: []u8, stride: usize, channels: usize, width: i32, height: i32, rect: RectI, block: i32) void {
    if (block < 1 or channels < 3) return;
    const x0 = std.math.clamp(rect.x, 0, width);
    const y0 = std.math.clamp(rect.y, 0, height);
    const x1 = std.math.clamp(rect.x + rect.w, 0, width);
    const y1 = std.math.clamp(rect.y + rect.h, 0, height);
    var by = y0;
    while (by < y1) : (by += block) {
        var bx = x0;
        while (bx < x1) : (bx += block) {
            const ex = @min(bx + block, x1);
            const ey = @min(by + block, y1);
            var sum: [4]u64 = @splat(0);
            var count: u64 = 0;
            var y = by;
            while (y < ey) : (y += 1) {
                var x = bx;
                while (x < ex) : (x += 1) {
                    const at = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(x)) * channels;
                    for (0..channels) |c| sum[c] += px[at + c];
                    count += 1;
                }
            }
            if (count == 0) continue;
            y = by;
            while (y < ey) : (y += 1) {
                var x = bx;
                while (x < ex) : (x += 1) {
                    const at = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(x)) * channels;
                    for (0..channels) |c| px[at + c] = @intCast(sum[c] / count);
                }
            }
        }
    }
}

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;

test "a drag in any direction is a rectangle" {
    const r = normalizeF(50, 40, 10, 20);
    try testing.expectEqual(@as(f64, 10), r.x);
    try testing.expectEqual(@as(f64, 20), r.y);
    try testing.expectEqual(@as(f64, 40), r.w);
    try testing.expectEqual(@as(f64, 20), r.h);
}

test "what a point grabs" {
    const r: RectF = .{ .x = 100, .y = 100, .w = 200, .h = 100 };
    try testing.expectEqual(Handle.nw, hit(r, 102, 98, 6));
    try testing.expectEqual(Handle.se, hit(r, 300, 200, 6));
    try testing.expectEqual(Handle.n, hit(r, 200, 100, 6));
    try testing.expectEqual(Handle.e, hit(r, 300, 150, 6));
    try testing.expectEqual(Handle.inside, hit(r, 200, 150, 6));
    try testing.expectEqual(Handle.none, hit(r, 50, 50, 6));
    // On a tiny selection the corners win over the edges' middles.
    try testing.expectEqual(Handle.nw, hit(.{ .x = 10, .y = 10, .w = 4, .h = 4 }, 10, 10, 6));
}

test "resizing by a corner and an edge" {
    const r: RectF = .{ .x = 100, .y = 100, .w = 200, .h = 100 };
    const se = dragSelection(r, .se, 50, 20, 1000, 800);
    try testing.expectEqual(@as(f64, 250), se.w);
    try testing.expectEqual(@as(f64, 120), se.h);
    try testing.expectEqual(@as(f64, 100), se.x);
    const w = dragSelection(r, .w, -30, 0, 1000, 800);
    try testing.expectEqual(@as(f64, 70), w.x);
    try testing.expectEqual(@as(f64, 230), w.w);
}

test "dragging an edge past the other turns the selection over" {
    const r: RectF = .{ .x = 100, .y = 100, .w = 50, .h = 50 };
    const n = dragSelection(r, .e, -80, 0, 1000, 800);
    try testing.expectEqual(@as(f64, 70), n.x);
    try testing.expectEqual(@as(f64, 30), n.w);
}

test "the selection stays in the image" {
    const r: RectF = .{ .x = 100, .y = 100, .w = 200, .h = 100 };
    const moved = dragSelection(r, .inside, 5000, 5000, 1000, 800);
    try testing.expectEqual(@as(f64, 800), moved.x);
    try testing.expectEqual(@as(f64, 700), moved.y);
    try testing.expectEqual(@as(f64, 200), moved.w);
    const grown = dragSelection(r, .se, 5000, 5000, 1000, 800);
    try testing.expectEqual(@as(f64, 1000), grown.x + grown.w);
    try testing.expectEqual(@as(f64, 800), grown.y + grown.h);
    // Never zero-sized.
    const collapsed = dragSelection(r, .se, -200, -100, 1000, 800);
    try testing.expect(collapsed.w >= 1 and collapsed.h >= 1);
}

test "the toolbar sits below, then above, then inside, and on screen" {
    const sel: RectF = .{ .x = 100, .y = 100, .w = 300, .h = 200 };
    const below = barPosition(sel, 250, 40, 1280, 720);
    try testing.expectEqual(@as(f64, 308), below.y);
    try testing.expectEqual(@as(f64, 150), below.x); // right edges line up
    // No room below: above.
    const low: RectF = .{ .x = 100, .y = 500, .w = 300, .h = 200 };
    try testing.expectEqual(@as(f64, 452), barPosition(low, 250, 40, 1280, 720).y);
    // Full screen: inside, at the bottom.
    const full: RectF = .{ .x = 0, .y = 0, .w = 1280, .h = 720 };
    const inside = barPosition(full, 250, 40, 1280, 720);
    try testing.expect(inside.y + 40 <= 720 and inside.y >= 0);
    try testing.expect(inside.x + 250 <= 1280);
    // A selection at the left edge keeps the bar on screen.
    const left = barPosition(.{ .x = 0, .y = 50, .w = 60, .h = 60 }, 250, 40, 1280, 720);
    try testing.expectEqual(@as(f64, 0), left.x);
}

test "thickness steps with the wheel, within limits" {
    try testing.expectEqual(@as(f64, 4), stepWidth(3, -1));
    try testing.expectEqual(@as(f64, 2), stepWidth(3, 1));
    try testing.expectEqual(min_width, stepWidth(min_width, 1));
    try testing.expectEqual(max_width, stepWidth(max_width, -1));
}

test "counters count on, and undoing one frees its number" {
    var shapes = [_]Shape{
        .{ .tool = .pen, .color = 0, .width = 1 },
        .{ .tool = .counter, .color = 0, .width = 1, .number = 1 },
        .{ .tool = .counter, .color = 0, .width = 1, .number = 2 },
    };
    try testing.expectEqual(@as(u32, 3), nextCounter(&shapes));
    try testing.expectEqual(@as(u32, 2), nextCounter(shapes[0..2]));
    try testing.expectEqual(@as(u32, 1), nextCounter(shapes[0..1]));
}

test "an arrow's wings trail back from the tip on both sides" {
    const wings = arrowWings(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, 3);
    // Both behind the tip, mirrored about the line.
    try testing.expect(wings[0].x < 100 and wings[1].x < 100);
    try testing.expectApproxEqAbs(wings[0].x, wings[1].x, 1e-9);
    try testing.expectApproxEqAbs(wings[0].y, -wings[1].y, 1e-9);
    try testing.expect(@abs(wings[0].y) > 1);
    // A dot has no direction: no head.
    const dot = arrowWings(.{ .x = 5, .y = 5 }, .{ .x = 5, .y = 5 }, 3);
    try testing.expectEqual(@as(f64, 5), dot[0].x);
    // A short line gets a head no longer than itself.
    const short = arrowWings(.{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, 3);
    try testing.expect(@abs(short[0].x - 4) <= 4.001);
}

test "pixelate replaces blocks with their average and leaves the rest" {
    // A 4x2 RGBA picture: left half black, right half white.
    var px: [4 * 2 * 4]u8 = undefined;
    for (0..2) |y| {
        for (0..4) |x| {
            const v: u8 = if (x < 2) 0 else 255;
            const at = y * 16 + x * 4;
            px[at] = v;
            px[at + 1] = v;
            px[at + 2] = v;
            px[at + 3] = 255;
        }
    }
    // One 4x2 block over the whole picture averages black and white to grey.
    pixelate(&px, 16, 4, 4, 2, .{ .x = 0, .y = 0, .w = 4, .h = 2 }, 4);
    try testing.expectEqual(@as(u8, 127), px[0]);
    try testing.expectEqual(@as(u8, 127), px[12]);
    try testing.expectEqual(@as(u8, 255), px[3]);
    // A box covering only the left half touches nothing else.
    var px2: [4 * 2 * 4]u8 = undefined;
    for (0..8) |i| {
        px2[i * 4] = if (i % 4 < 2) 0 else 200;
        px2[i * 4 + 1] = px2[i * 4];
        px2[i * 4 + 2] = px2[i * 4];
        px2[i * 4 + 3] = 255;
    }
    pixelate(&px2, 16, 4, 4, 2, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, 8);
    try testing.expectEqual(@as(u8, 0), px2[0]); // averaged with itself
    try testing.expectEqual(@as(u8, 200), px2[8]); // outside the box
}

test "pixelate is safe on boxes outside or partly outside the picture" {
    var px: [3 * 3 * 3]u8 = @splat(7);
    pixelate(&px, 9, 3, 3, 3, .{ .x = -50, .y = -50, .w = 500, .h = 500 }, 2);
    pixelate(&px, 9, 3, 3, 3, .{ .x = 10, .y = 10, .w = 5, .h = 5 }, 2);
    pixelate(&px, 9, 3, 3, 3, .{ .x = 1, .y = 1, .w = 0, .h = 0 }, 2);
    try testing.expectEqual(@as(u8, 7), px[0]);
}

test "block size follows thickness" {
    try testing.expectEqual(@as(i32, 10), pixelBlock(3));
    try testing.expectEqual(@as(i32, 6), pixelBlock(1));
    try testing.expectEqual(@as(i32, 60), pixelBlock(40));
}
