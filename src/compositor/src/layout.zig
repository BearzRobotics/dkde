// SPDX-License-Identifier: GPL-2.0-or-later
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

/// Where a dragged window goes when the pointer is let go at the screen's edge (as in Windows): the left or
/// right edge snaps to that half, a corner to that quarter, the top edge maximizes. The bottom edge does nothing.
pub const EdgeZone = enum { maximize, left, right, top_left, top_right, bottom_left, bottom_right };

pub fn edgeZone(box: Rect, x: i32, y: i32, margin: i32, corner: i32) ?EdgeZone {
    const near_l = x < box.x + margin;
    const near_r = x >= box.x + box.w - margin;
    const near_t = y < box.y + margin;
    if (near_l or near_r) {
        if (y < box.y + corner) return if (near_l) .top_left else .top_right;
        if (y >= box.y + box.h - corner) return if (near_l) .bottom_left else .bottom_right;
        return if (near_l) .left else .right;
    }
    if (near_t) return .maximize;
    return null;
}

/// The snap region a zone stands for; null for the top edge, which maximizes.
pub fn zoneRegion(zone: EdgeZone) ?@import("keys.zig").Region {
    return switch (zone) {
        .maximize => null,
        .left => .left_half,
        .right => .right_half,
        .top_left => .top_left,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_right => .bottom_right,
    };
}

// ---- the layout overlay at the top of the screen (as in Windows 11) -------------------------------------------

const Region = @import("keys.zig").Region;

/// The arrangements offered while a window is dragged to the top of the screen (the same ones Super+Z offers).
pub const snap_layouts = [_][]const Region{
    &.{ .left_half, .right_half },
    &.{ .left_two_thirds, .right_third },
    &.{ .left_third, .right_two_thirds },
    &.{ .left_third, .middle_third, .right_third },
    &.{ .top_left, .top_right, .bottom_left, .bottom_right },
    &.{ .left_half, .top_right, .bottom_right },
    &.{ .top_left, .bottom_left, .right_half },
    &.{ .top_half, .bottom_half },
};

pub const overlay = struct {
    pub const cols: i32 = 4;
    pub const cell_w: i32 = 120;
    pub const cell_h: i32 = 76;
    pub const gap: i32 = 10;
    pub const pad: i32 = 12;
    /// The overlay appears when the pointer is this close to the top of the screen.
    pub const reveal: i32 = 48;
    /// The card sits this far below the top edge.
    pub const top: i32 = 10;
};

/// The card that holds the thumbnails, centred at the top of `box` (an output).
pub fn overlayCard(box: Rect) Rect {
    const rows: i32 = @intCast((snap_layouts.len + overlay.cols - 1) / overlay.cols);
    const w = overlay.cols * overlay.cell_w + (overlay.cols - 1) * overlay.gap + 2 * overlay.pad;
    const h = rows * overlay.cell_h + (rows - 1) * overlay.gap + 2 * overlay.pad;
    return .{ .x = box.x + @divFloor(box.w - w, 2), .y = box.y + overlay.top, .w = w, .h = h };
}

/// The thumbnail of layout `i` inside `card`.
pub fn overlayCell(card: Rect, i: usize) Rect {
    const col: i32 = @intCast(i % @as(usize, @intCast(overlay.cols)));
    const row: i32 = @intCast(i / @as(usize, @intCast(overlay.cols)));
    return .{
        .x = card.x + overlay.pad + col * (overlay.cell_w + overlay.gap),
        .y = card.y + overlay.pad + row * (overlay.cell_h + overlay.gap),
        .w = overlay.cell_w,
        .h = overlay.cell_h,
    };
}

/// Zone `j` of layout `i` as drawn inside its thumbnail (a little smaller, so neighbours do not touch).
pub fn overlayZone(card: Rect, i: usize, j: usize) Rect {
    const cell = overlayCell(card, i);
    const r = regionRect(cell, snap_layouts[i][j]);
    return .{ .x = r.x + 2, .y = r.y + 2, .w = @max(r.w - 4, 1), .h = @max(r.h - 4, 1) };
}

fn inside(r: Rect, x: i32, y: i32) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}

/// Which overlay zone (layout, zone) is under (x, y), if any.
pub const ZoneIndex = struct { i: usize, j: usize };

pub fn overlayZoneAt(box: Rect, x: i32, y: i32) ?ZoneIndex {
    const card = overlayCard(box);
    for (snap_layouts, 0..) |l, i| {
        for (l, 0..) |_, j| {
            if (inside(overlayZone(card, i, j), x, y)) return .{ .i = i, .j = j };
        }
    }
    return null;
}

/// The snap region of the overlay zone under (x, y), if any.
pub fn overlayHit(box: Rect, x: i32, y: i32) ?Region {
    const hit = overlayZoneAt(box, x, y) orelse return null;
    return snap_layouts[hit.i][hit.j];
}

pub const Target = union(enum) { region: Region, maximize };

/// What dropping the dragged window at (x, y) would do, and whether the overlay shows. `overlay_was` keeps the
/// card up while the pointer moves down onto it from the top edge.
pub fn dropTarget(box: Rect, x: i32, y: i32, overlay_was: bool) struct { overlay: bool, target: ?Target } {
    const card = overlayCard(box);
    const held = Rect{ .x = card.x - 8, .y = box.y, .w = card.w + 16, .h = card.y + card.h + 8 - box.y };
    const show = y < box.y + overlay.reveal or (overlay_was and inside(held, x, y));
    if (show) if (overlayHit(box, x, y)) |region| return .{ .overlay = true, .target = .{ .region = region } };
    const edge = edgeZone(box, x, y, 8, 80) orelse return .{ .overlay = show, .target = null };
    return .{ .overlay = show, .target = if (zoneRegion(edge)) |r| .{ .region = r } else .maximize };
}

test "overlay hit testing" {
    const box = Rect{ .x = 0, .y = 0, .w = 1280, .h = 720 };
    const card = overlayCard(box);
    // The first layout's left zone.
    const z = overlayZone(card, 0, 0);
    try std.testing.expectEqual(Region.left_half, overlayHit(box, z.x + 3, z.y + 3).?);
    const second = overlayZone(card, 0, 1);
    try std.testing.expectEqual(Region.right_half, dropTarget(box, second.x + 3, second.y + 3, true).target.?.region);
    try std.testing.expect(dropTarget(box, second.x + 3, second.y + 3, true).overlay);
    // Far from the top: no overlay, no target.
    const away = dropTarget(box, 640, 400, false);
    try std.testing.expect(!away.overlay and away.target == null);
    // The very top, off the card: maximize.
    try std.testing.expect(dropTarget(box, 100, 2, false).target.? == .maximize);
}

test "edge zones" {
    const box = Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try std.testing.expectEqual(EdgeZone.left, edgeZone(box, 2, 300, 8, 80).?);
    try std.testing.expectEqual(EdgeZone.right, edgeZone(box, 999, 300, 8, 80).?);
    try std.testing.expectEqual(EdgeZone.maximize, edgeZone(box, 500, 3, 8, 80).?);
    try std.testing.expectEqual(EdgeZone.top_left, edgeZone(box, 1, 10, 8, 80).?);
    try std.testing.expectEqual(EdgeZone.bottom_right, edgeZone(box, 998, 590, 8, 80).?);
    try std.testing.expect(edgeZone(box, 500, 300, 8, 80) == null);
    try std.testing.expect(edgeZone(box, 500, 599, 8, 80) == null);
}

test "regions" {
    const area = Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    try std.testing.expectEqual(Rect{ .x = 500, .y = 0, .w = 500, .h = 600 }, regionRect(area, .right_half));
    try std.testing.expectEqual(Rect{ .x = 500, .y = 300, .w = 500, .h = 300 }, regionRect(area, .bottom_right));
    const mid = regionRect(area, .middle_third);
    try std.testing.expectEqual(@as(i32, 330), mid.x);
}
