//! Window layout policy, with no wlroots in it so it is easy to test, and so
//! the X11 window manager can use the same code later.
//!
//! Floating: windows keep the place and size the user gave them; new ones
//! are cascaded. Tiling: the windows share the work area, one master on the
//! left and the rest stacked on the right (a layout the user can tune with
//! the ratio and the gap).

const std = @import("std");

pub const Policy = enum {
    floating,
    tiling,

    pub fn toggled(self: Policy) Policy {
        return if (self == .floating) .tiling else .floating;
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Options = struct {
    /// Space between windows and around the edge, in pixels.
    gap: i32 = 6,
    /// The master window's share of the width (0.1 … 0.9).
    master_ratio: f32 = 0.55,
};

/// Fills `out[0..n]` with the cells for `n` tiled windows in `area`: window 0
/// is the master (left); the others share the right column from the top.
pub fn tile(area: Rect, n: usize, options: Options, out: []Rect) void {
    std.debug.assert(out.len >= n);
    if (n == 0) return;
    const gap = options.gap;
    const inner = Rect{ .x = area.x + gap, .y = area.y + gap, .w = @max(1, area.w - 2 * gap), .h = @max(1, area.h - 2 * gap) };
    if (n == 1) {
        out[0] = inner;
        return;
    }
    const ratio = std.math.clamp(options.master_ratio, 0.1, 0.9);
    const master_w: i32 = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(inner.w - gap)) * ratio)));
    out[0] = .{ .x = inner.x, .y = inner.y, .w = master_w, .h = inner.h };
    const stack_x = inner.x + master_w + gap;
    const stack_w = @max(1, inner.x + inner.w - stack_x);
    const rows: i32 = @intCast(n - 1);
    const row_h = @max(1, @divFloor(inner.h - gap * (rows - 1), rows));
    for (1..n) |i| {
        const row: i32 = @intCast(i - 1);
        out[i] = .{ .x = stack_x, .y = inner.y + row * (row_h + gap), .w = stack_w, .h = row_h };
        // The last row takes what rounding left over.
        if (i == n - 1) out[i].h = inner.y + inner.h - out[i].y;
    }
}

/// Where the `index`th new floating window goes: down and to the right of
/// the previous one, wrapping before it leaves the area.
pub fn cascade(area: Rect, index: usize) struct { x: i32, y: i32 } {
    const step: i32 = 32;
    const room: i32 = @max(1, @divFloor(@divFloor(@min(area.w, area.h), 2), step));
    const k: i32 = @intCast(index % @as(usize, @intCast(room)));
    return .{ .x = area.x + 48 + k * step, .y = area.y + 48 + k * step };
}

test "one window fills the area, less the gap" {
    var out: [1]Rect = undefined;
    tile(.{ .x = 0, .y = 0, .w = 1000, .h = 600 }, 1, .{ .gap = 10 }, &out);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 980, .h = 580 }, out[0]);
}

test "two windows: master left, one on the right" {
    var out: [2]Rect = undefined;
    tile(.{ .x = 0, .y = 0, .w = 1000, .h = 600 }, 2, .{ .gap = 10, .master_ratio = 0.5 }, &out);
    try std.testing.expectEqual(@as(i32, 10), out[0].x);
    try std.testing.expectEqual(@as(i32, 580), out[0].h);
    try std.testing.expect(out[1].x > out[0].x + out[0].w);
    try std.testing.expectEqual(@as(i32, 990), out[1].x + out[1].w);
    try std.testing.expectEqual(@as(i32, 580), out[1].h);
}

test "stacked windows do not overlap and fill the column" {
    var out: [5]Rect = undefined;
    tile(.{ .x = 0, .y = 0, .w = 1280, .h = 720 }, 5, .{}, &out);
    for (2..5) |i| try std.testing.expect(out[i].y >= out[i - 1].y + out[i - 1].h);
    try std.testing.expectEqual(@as(i32, 720 - 6), out[4].y + out[4].h);
}

test "cascade steps and wraps" {
    const area = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const first = cascade(area, 0);
    const second = cascade(area, 1);
    try std.testing.expect(second.x > first.x and second.y > first.y);
    try std.testing.expectEqual(first, cascade(area, 9));
}

test "policy toggles" {
    try std.testing.expectEqual(Policy.tiling, Policy.floating.toggled());
    try std.testing.expectEqual(Policy.floating, Policy.tiling.toggled());
}

/// The part of `area` a snap region covers (the same fractions labwc's regions use, thirds rounded to whole percents).
pub fn regionRect(area: Rect, region: @import("keys.zig").Region) Rect {
    const pct: [4]i32 = switch (region) {
        .left_half => .{ 0, 0, 50, 100 },
        .right_half => .{ 50, 0, 50, 100 },
        .top_half => .{ 0, 0, 100, 50 },
        .bottom_half => .{ 0, 50, 100, 50 },
        .left_third => .{ 0, 0, 33, 100 },
        .middle_third => .{ 33, 0, 34, 100 },
        .right_third => .{ 67, 0, 33, 100 },
        .left_two_thirds => .{ 0, 0, 67, 100 },
        .right_two_thirds => .{ 33, 0, 67, 100 },
        .top_left => .{ 0, 0, 50, 50 },
        .top_right => .{ 50, 0, 50, 50 },
        .bottom_left => .{ 0, 50, 50, 50 },
        .bottom_right => .{ 50, 50, 50, 50 },
    };
    return .{
        .x = area.x + @divFloor(area.w * pct[0], 100),
        .y = area.y + @divFloor(area.h * pct[1], 100),
        .w = @divFloor(area.w * pct[2], 100),
        .h = @divFloor(area.h * pct[3], 100),
    };
}

test "regions" {
    const area = Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try std.testing.expectEqual(Rect{ .x = 500, .y = 0, .w = 500, .h = 600 }, regionRect(area, .right_half));
    try std.testing.expectEqual(Rect{ .x = 500, .y = 300, .w = 500, .h = 300 }, regionRect(area, .bottom_right));
    const mid = regionRect(area, .middle_third);
    try std.testing.expectEqual(@as(i32, 330), mid.x);
}
