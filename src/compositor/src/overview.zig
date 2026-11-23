//! Layouts for the two overviews, with no wlroots in them so they can be tested.
//!
//! Scale shows every window of the workspace at once in a grid, each shrunk to fit its cell; Expo shows
//! every workspace as a tile of the screen with its windows on it. A window is drawn scaled about its own
//! top-left corner and shifted: `Place` says by how much.

const std = @import("std");
const layout = @import("layout.zig");
const Rect = layout.Rect;

pub const Size = struct { w: i32, h: i32 };

/// Where a window goes in an overview: its new top-left corner, and the scale about it.
pub const Place = struct { x: i32, y: i32, scale: f32 };

/// `n` windows in a grid inside `area`, each fitted to its cell (never enlarged); a short last row is centred.
pub fn scaleCells(area: Rect, sizes: []const Size, gap: i32, out: []Place) void {
    const n = sizes.len;
    std.debug.assert(out.len >= n);
    if (n == 0) return;
    const aspect: f32 = @as(f32, @floatFromInt(@max(area.w, 1))) / @as(f32, @floatFromInt(@max(area.h, 1)));
    var cols: usize = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(n)) * aspect)));
    cols = std.math.clamp(cols, 1, n);
    const rows = (n + cols - 1) / cols;
    const cw = @max(1, @divTrunc(area.w - gap * @as(i32, @intCast(cols + 1)), @as(i32, @intCast(cols))));
    const ch = @max(1, @divTrunc(area.h - gap * @as(i32, @intCast(rows + 1)), @as(i32, @intCast(rows))));
    for (sizes, 0..) |size, i| {
        const row = i / cols;
        const col = i % cols;
        const in_row = @min(cols, n - row * cols);
        const shift = @divTrunc(@as(i32, @intCast(cols - in_row)) * (cw + gap), 2);
        const cx = area.x + gap + shift + @as(i32, @intCast(col)) * (cw + gap);
        const cy = area.y + gap + @as(i32, @intCast(row)) * (ch + gap);
        const w: f32 = @floatFromInt(@max(size.w, 1));
        const h: f32 = @floatFromInt(@max(size.h, 1));
        const s = @min(1.0, @min(@as(f32, @floatFromInt(cw)) / w, @as(f32, @floatFromInt(ch)) / h));
        const nw: i32 = @intFromFloat(w * s);
        const nh: i32 = @intFromFloat(h * s);
        out[i] = .{ .x = cx + @divTrunc(cw - nw, 2), .y = cy + @divTrunc(ch - nh, 2), .scale = s };
    }
}

/// The window that a point is over, front to back (`sizes` and `places` in the same order, the last is on top).
pub fn windowAt(places: []const Place, sizes: []const Size, px: i32, py: i32) ?usize {
    var i = places.len;
    while (i > 0) : (i -= 1) {
        const p = places[i - 1];
        const w: i32 = @intFromFloat(@as(f32, @floatFromInt(sizes[i - 1].w)) * p.scale);
        const h: i32 = @intFromFloat(@as(f32, @floatFromInt(sizes[i - 1].h)) * p.scale);
        if (px >= p.x and px < p.x + w and py >= p.y and py < p.y + h) return i - 1;
    }
    return null;
}

/// The workspaces of Expo as a grid of screen-shaped tiles.
pub const Tiles = struct {
    cols: usize,
    rows: usize,
    w: i32,
    h: i32,
    x0: i32,
    y0: i32,
    gap: i32,

    pub fn rect(self: Tiles, index: usize) Rect {
        const row: i32 = @intCast(index / self.cols);
        const col: i32 = @intCast(index % self.cols);
        return .{ .x = self.x0 + col * (self.w + self.gap), .y = self.y0 + row * (self.h + self.gap), .w = self.w, .h = self.h };
    }

    pub fn at(self: Tiles, count: usize, px: i32, py: i32) ?usize {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const r = self.rect(i);
            if (px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h) return i;
        }
        return null;
    }

    /// Scale of a screen drawn as a tile.
    pub fn scale(self: Tiles, screen: Rect) f32 {
        return @as(f32, @floatFromInt(self.w)) / @as(f32, @floatFromInt(@max(screen.w, 1)));
    }

    /// Where a window whose top-left is (x, y) on a screen goes on tile `index`.
    pub fn place(self: Tiles, screen: Rect, index: usize, x: i32, y: i32) Place {
        const s = self.scale(screen);
        const r = self.rect(index);
        return .{
            .x = r.x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(x - screen.x)) * s)),
            .y = r.y + @as(i32, @intFromFloat(@as(f32, @floatFromInt(y - screen.y)) * s)),
            .scale = s,
        };
    }
};

/// `count` workspaces as tiles with the shape of `screen`, centred in it with a margin.
pub fn expoTiles(screen: Rect, count: usize, gap: i32) Tiles {
    const n = @max(count, 1);
    const cols: usize = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(n)))));
    const rows = (n + cols - 1) / cols;
    const margin = @divTrunc(screen.w, 12);
    const avail_w = screen.w - 2 * margin - gap * @as(i32, @intCast(cols - 1));
    const avail_h = screen.h - 2 * margin - gap * @as(i32, @intCast(rows - 1));
    var w = @divTrunc(avail_w, @as(i32, @intCast(cols)));
    var h = @divTrunc(w * screen.h, @max(screen.w, 1));
    const max_h = @divTrunc(avail_h, @as(i32, @intCast(rows)));
    if (h > max_h) {
        h = max_h;
        w = @divTrunc(h * screen.w, @max(screen.h, 1));
    }
    const total_w = @as(i32, @intCast(cols)) * w + gap * @as(i32, @intCast(cols - 1));
    const total_h = @as(i32, @intCast(rows)) * h + gap * @as(i32, @intCast(rows - 1));
    return .{
        .cols = cols,
        .rows = rows,
        .w = w,
        .h = h,
        .x0 = screen.x + @divTrunc(screen.w - total_w, 2),
        .y0 = screen.y + @divTrunc(screen.h - total_h, 2),
        .gap = gap,
    };
}

test "scale fits windows in a grid and never enlarges" {
    const area = Rect{ .x = 0, .y = 0, .w = 1200, .h = 800 };
    const sizes = [_]Size{ .{ .w = 600, .h = 400 }, .{ .w = 300, .h = 200 }, .{ .w = 1000, .h = 700 } };
    var out: [3]Place = undefined;
    scaleCells(area, &sizes, 20, &out);
    try std.testing.expectEqual(@as(f32, 1), out[1].scale); // small: kept at full size
    try std.testing.expect(out[2].scale < 1);
    for (out, sizes) |p, s| {
        const w: i32 = @intFromFloat(@as(f32, @floatFromInt(s.w)) * p.scale);
        const h: i32 = @intFromFloat(@as(f32, @floatFromInt(s.h)) * p.scale);
        try std.testing.expect(p.x >= 0 and p.y >= 0 and p.x + w <= area.w and p.y + h <= area.h);
    }
    // No two thumbnails overlap.
    for (0..3) |i| for (i + 1..3) |j| {
        const a = out[i];
        const b = out[j];
        const aw: i32 = @intFromFloat(@as(f32, @floatFromInt(sizes[i].w)) * a.scale);
        const ah: i32 = @intFromFloat(@as(f32, @floatFromInt(sizes[i].h)) * a.scale);
        const apart = a.x + aw <= b.x or b.x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(sizes[j].w)) * b.scale)) <= a.x or
            a.y + ah <= b.y or b.y + @as(i32, @intFromFloat(@as(f32, @floatFromInt(sizes[j].h)) * b.scale)) <= a.y;
        try std.testing.expect(apart);
    };
}

test "one window and none" {
    var out: [1]Place = undefined;
    scaleCells(.{ .x = 0, .y = 0, .w = 1000, .h = 600 }, &.{}, 10, &out);
    scaleCells(.{ .x = 0, .y = 0, .w = 1000, .h = 600 }, &.{.{ .w = 400, .h = 300 }}, 10, &out);
    try std.testing.expectEqual(@as(f32, 1), out[0].scale);
    try std.testing.expectEqual(@as(i32, 300), out[0].x);
}

test "a point finds the window over it, the front one first" {
    const places = [_]Place{ .{ .x = 0, .y = 0, .scale = 1 }, .{ .x = 50, .y = 50, .scale = 0.5 } };
    const sizes = [_]Size{ .{ .w = 200, .h = 200 }, .{ .w = 200, .h = 200 } };
    try std.testing.expectEqual(@as(?usize, 1), windowAt(&places, &sizes, 60, 60));
    try std.testing.expectEqual(@as(?usize, 0), windowAt(&places, &sizes, 10, 10));
    try std.testing.expect(windowAt(&places, &sizes, 500, 500) == null);
}

test "expo tiles have the screen's shape and hold their windows" {
    const screen = Rect{ .x = 0, .y = 0, .w = 1600, .h = 900 };
    const t = expoTiles(screen, 4, 24);
    try std.testing.expectEqual(@as(usize, 2), t.cols);
    try std.testing.expectEqual(@as(usize, 2), t.rows);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), @as(f32, @floatFromInt(t.w)) / @as(f32, @floatFromInt(t.h)), 0.02);
    for (0..4) |i| {
        const r = t.rect(i);
        try std.testing.expect(r.x >= 0 and r.y >= 0 and r.x + r.w <= screen.w and r.y + r.h <= screen.h);
    }
    try std.testing.expectEqual(@as(?usize, 3), t.at(4, t.rect(3).x + 5, t.rect(3).y + 5));
    try std.testing.expect(t.at(4, 1, 1) == null);
    const p = t.place(screen, 2, 800, 450);
    const r = t.rect(2);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(r.x + @divTrunc(r.w, 2))), @as(f32, @floatFromInt(p.x)), 2);
    try std.testing.expectEqual(t.scale(screen), p.scale);
}

test "an odd number of workspaces" {
    const t = expoTiles(.{ .x = 0, .y = 0, .w = 1280, .h = 720 }, 5, 20);
    try std.testing.expectEqual(@as(usize, 3), t.cols);
    try std.testing.expectEqual(@as(usize, 2), t.rows);
    const last = t.rect(4);
    try std.testing.expect(last.x + last.w <= 1280 and last.y + last.h <= 720);
}
