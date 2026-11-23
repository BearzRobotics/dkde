//! Where windows go, with no wlroots in it (so it is tested, and dkde-wm can use it too):
//! Put (send a window to a corner, an edge or the centre), smart placement of a new window
//! where it covers the least, and edge magnetism while a window is dragged.

const std = @import("std");
const layout = @import("layout.zig");
const Rect = layout.Rect;

/// The nine places Put knows: the corners, the edge middles and the centre.
pub const Position = enum {
    top_left,
    top,
    top_right,
    left,
    center,
    right,
    bottom_left,
    bottom,
    bottom_right,
};

pub fn parsePosition(name: []const u8) ?Position {
    for (std.enums.values(Position)) |p| {
        const tag = @tagName(p);
        if (tag.len != name.len) continue;
        var same = true;
        for (tag, name) |x, y| {
            if ((if (x == '_') '-' else x) != y) same = false;
        }
        if (same) return p;
    }
    return null;
}

/// A window of `w` by `h` moved to `pos` inside `area`; its size is kept (clamped to the area).
pub fn put(area: Rect, w: i32, h: i32, pos: Position) Rect {
    const ww = @min(w, area.w);
    const hh = @min(h, area.h);
    const left = area.x;
    const right = area.x + area.w - ww;
    const mid_x = area.x + @divTrunc(area.w - ww, 2);
    const top = area.y;
    const bottom = area.y + area.h - hh;
    const mid_y = area.y + @divTrunc(area.h - hh, 2);
    const x = switch (pos) {
        .top_left, .left, .bottom_left => left,
        .top, .center, .bottom => mid_x,
        .top_right, .right, .bottom_right => right,
    };
    const y = switch (pos) {
        .top_left, .top, .top_right => top,
        .left, .center, .right => mid_y,
        .bottom_left, .bottom, .bottom_right => bottom,
    };
    return .{ .x = x, .y = y, .w = ww, .h = hh };
}

fn overlap(a: Rect, b: Rect) i64 {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return 0;
    return @as(i64, x1 - x0) * @as(i64, y1 - y0);
}

/// The top-left corner for a new `w` by `h` window in `area` that covers the other windows least.
/// Candidates are the corners of the area and of each window (just beyond it); the first wins a tie,
/// so with nothing in the way the window goes to the top left.
pub fn smart(area: Rect, w: i32, h: i32, others: []const Rect) struct { x: i32, y: i32 } {
    const ww = @min(w, area.w);
    const hh = @min(h, area.h);
    var best_x = area.x;
    var best_y = area.y;
    var best: i64 = std.math.maxInt(i64);

    const Candidate = struct { x: i32, y: i32 };
    var list: [1 + 4 * 64]Candidate = undefined;
    var n: usize = 0;
    list[n] = .{ .x = area.x, .y = area.y };
    n += 1;
    for (others[0..@min(others.len, 64)]) |o| {
        const xs = [_]i32{ o.x, o.x + o.w };
        const ys = [_]i32{ o.y, o.y + o.h };
        for (xs) |x| for (ys) |y| {
            list[n] = .{ .x = x, .y = y };
            n += 1;
        };
    }
    for (list[0..n]) |cand| {
        const x = std.math.clamp(cand.x, area.x, area.x + area.w - ww);
        const y = std.math.clamp(cand.y, area.y, area.y + area.h - hh);
        const trial = Rect{ .x = x, .y = y, .w = ww, .h = hh };
        var cost: i64 = 0;
        for (others) |o| cost += overlap(trial, o);
        if (cost < best) {
            best = cost;
            best_x = x;
            best_y = y;
            if (cost == 0) break;
        }
    }
    return .{ .x = best_x, .y = best_y };
}

/// Edge magnetism: `r` is where a dragged window would land; if one of its edges is within `threshold`
/// of the edge of the work area or of another window it moves so the two meet. Only the position changes.
pub fn magnet(r: Rect, area: Rect, others: []const Rect, threshold: i32) Rect {
    var out = r;
    var best_dx: i32 = threshold + 1;
    var best_dy: i32 = threshold + 1;
    var dx: i32 = 0;
    var dy: i32 = 0;

    const consider = struct {
        fn x(delta: i32, best: *i32, result: *i32) void {
            if (@abs(delta) < @abs(best.*)) {
                best.* = delta;
                result.* = delta;
            }
        }
    };

    // The work area's edges (the window's edge lines up with them).
    consider.x(area.x - r.x, &best_dx, &dx);
    consider.x(area.x + area.w - (r.x + r.w), &best_dx, &dx);
    consider.x(area.y - r.y, &best_dy, &dy);
    consider.x(area.y + area.h - (r.y + r.h), &best_dy, &dy);
    for (others) |o| {
        // Only windows that are alongside in the other direction can be a neighbour.
        const alongside_y = r.y < o.y + o.h and o.y < r.y + r.h;
        const alongside_x = r.x < o.x + o.w and o.x < r.x + r.w;
        if (alongside_y) {
            consider.x(o.x + o.w - r.x, &best_dx, &dx); // my left edge to their right edge
            consider.x(o.x - (r.x + r.w), &best_dx, &dx); // my right edge to their left edge
        }
        if (alongside_x) {
            consider.x(o.y + o.h - r.y, &best_dy, &dy);
            consider.x(o.y - (r.y + r.h), &best_dy, &dy);
        }
    }
    if (best_dx <= threshold) out.x += dx;
    if (best_dy <= threshold) out.y += dy;
    return out;
}

test "put puts a window in the nine places" {
    const area = Rect{ .x = 0, .y = 30, .w = 1000, .h = 700 };
    const c = put(area, 400, 300, .center);
    try std.testing.expectEqual(Rect{ .x = 300, .y = 230, .w = 400, .h = 300 }, c);
    const tl = put(area, 400, 300, .top_left);
    try std.testing.expectEqual(@as(i32, 0), tl.x);
    try std.testing.expectEqual(@as(i32, 30), tl.y);
    const br = put(area, 400, 300, .bottom_right);
    try std.testing.expectEqual(@as(i32, 600), br.x);
    try std.testing.expectEqual(@as(i32, 430), br.y);
    const big = put(area, 5000, 5000, .center);
    try std.testing.expectEqual(@as(i32, 1000), big.w);
    try std.testing.expectEqual(@as(i32, 700), big.h);
}

test "positions parse" {
    try std.testing.expectEqual(Position.top_left, parsePosition("top-left").?);
    try std.testing.expectEqual(Position.center, parsePosition("center").?);
    try std.testing.expect(parsePosition("middle") == null);
}

test "smart placement avoids other windows" {
    const area = Rect{ .x = 0, .y = 0, .w = 1000, .h = 700 };
    const none = smart(area, 300, 200, &.{});
    try std.testing.expectEqual(@as(i32, 0), none.x);
    try std.testing.expectEqual(@as(i32, 0), none.y);
    const left = Rect{ .x = 0, .y = 0, .w = 300, .h = 700 };
    const next = smart(area, 300, 200, &.{left});
    try std.testing.expectEqual(@as(i32, 300), next.x);
    const full = Rect{ .x = 0, .y = 0, .w = 1000, .h = 700 };
    // Nowhere is free: it still returns a place inside the area.
    const any = smart(area, 300, 200, &.{full});
    try std.testing.expect(any.x >= 0 and any.x + 300 <= 1000);
}

test "magnetism meets the screen edge and a neighbour" {
    const area = Rect{ .x = 0, .y = 0, .w = 1000, .h = 700 };
    const other = Rect{ .x = 500, .y = 100, .w = 300, .h = 300 };
    const near_edge = magnet(.{ .x = 12, .y = 300, .w = 200, .h = 150 }, area, &.{}, 20);
    try std.testing.expectEqual(@as(i32, 0), near_edge.x);
    try std.testing.expectEqual(@as(i32, 300), near_edge.y);
    // Its right edge (x + w = 490) is 10 from the neighbour's left edge (500).
    const beside = magnet(.{ .x = 290, .y = 150, .w = 200, .h = 150 }, area, &.{other}, 20);
    try std.testing.expectEqual(@as(i32, 300), beside.x);
    // Far from everything nothing moves.
    const far = magnet(.{ .x = 100, .y = 400, .w = 200, .h = 100 }, area, &.{other}, 20);
    try std.testing.expectEqual(@as(i32, 100), far.x);
    try std.testing.expectEqual(@as(i32, 400), far.y);
}
