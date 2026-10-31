//! Pixel and geometry helpers for the screenshot tool. No Wayland or GTK.

const std = @import("std");

/// Channel order of a 32-bit shm buffer, as bytes in memory.
pub const Layout = enum {
    /// wl_shm argb8888 / xrgb8888 on little-endian: B, G, R, A|X.
    bgra,
    /// abgr8888 / xbgr8888 on little-endian: R, G, B, A|X.
    rgba,
};

/// Converts a shm buffer to tightly packed opaque RGBA. `flip` mirrors it
/// vertically for compositors that report `y_invert`.
pub fn toRgba(dst: []u8, src: []const u8, width: usize, height: usize, stride: usize, layout: Layout, flip: bool) void {
    for (0..height) |y| {
        const src_row = src[(if (flip) height - 1 - y else y) * stride ..][0 .. width * 4];
        const dst_row = dst[y * width * 4 ..][0 .. width * 4];
        for (0..width) |x| {
            const s = src_row[x * 4 ..][0..4];
            const d = dst_row[x * 4 ..][0..4];
            switch (layout) {
                .bgra => {
                    d[0] = s[2];
                    d[1] = s[1];
                    d[2] = s[0];
                },
                .rgba => {
                    d[0] = s[0];
                    d[1] = s[1];
                    d[2] = s[2];
                },
            }
            d[3] = 255; // screenshots are opaque
        }
    }
}

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// The rectangle between two drag points, whichever way it was dragged.
pub fn normalize(x0: f64, y0: f64, x1: f64, y1: f64) Rect {
    const left = @min(x0, x1);
    const top = @min(y0, y1);
    return .{
        .x = @intFromFloat(@floor(left)),
        .y = @intFromFloat(@floor(top)),
        .w = @intFromFloat(@ceil(@abs(x1 - x0))),
        .h = @intFromFloat(@ceil(@abs(y1 - y0))),
    };
}

/// Maps a rectangle in widget coordinates to image pixels and clamps it
/// to the image. Returns null when nothing is left.
pub fn toImage(r: Rect, widget_w: f64, widget_h: f64, image_w: i32, image_h: i32) ?Rect {
    if (widget_w <= 0 or widget_h <= 0) return null;
    const sx = @as(f64, @floatFromInt(image_w)) / widget_w;
    const sy = @as(f64, @floatFromInt(image_h)) / widget_h;
    var x: i32 = @intFromFloat(@as(f64, @floatFromInt(r.x)) * sx);
    var y: i32 = @intFromFloat(@as(f64, @floatFromInt(r.y)) * sy);
    var w: i32 = @intFromFloat(@as(f64, @floatFromInt(r.w)) * sx);
    var h: i32 = @intFromFloat(@as(f64, @floatFromInt(r.h)) * sy);
    if (x < 0) {
        w += x;
        x = 0;
    }
    if (y < 0) {
        h += y;
        y = 0;
    }
    w = @min(w, image_w - x);
    h = @min(h, image_h - y);
    if (w < 1 or h < 1) return null;
    return .{ .x = x, .y = y, .w = w, .h = h };
}

/// "Screenshot-2026-10-30-14-05-09.png" from broken-down local time.
pub fn fileName(buf: []u8, year: i32, month: i32, day: i32, hour: i32, minute: i32, second: i32) []const u8 {
    // Unsigned, or {d} prints a leading "+" when padding.
    return std.fmt.bufPrint(buf, "Screenshot-{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}.png", .{
        @as(u32, @intCast(@max(0, year))),
        @as(u32, @intCast(@max(0, month))),
        @as(u32, @intCast(@max(0, day))),
        @as(u32, @intCast(@max(0, hour))),
        @as(u32, @intCast(@max(0, minute))),
        @as(u32, @intCast(@max(0, second))),
    }) catch "Screenshot.png";
}

/// How a new frame relates to the previous one when scrolling down.
pub const Scroll = union(enum) {
    /// The frames are identical: the page has stopped moving (the end).
    same,
    /// The content moved up by this many rows.
    moved: usize,
    /// No overlap was found (it scrolled too far, or the content changed).
    unknown,
};

fn rowHash(row: []const u8) u64 {
    return std.hash.Wyhash.hash(0, row);
}

/// Finds how far `next` has scrolled relative to `prev`. Both are tightly
/// packed RGBA frames of `width` x `height`. Only the middle band of rows is
/// compared, so a fixed header or footer does not stop a match.
pub fn findScroll(allocator: std.mem.Allocator, prev: []const u8, next: []const u8, width: usize, height: usize) !Scroll {
    const row_bytes = width * 4;
    if (height < 8 or prev.len != row_bytes * height or next.len != prev.len) return .unknown;
    if (std.mem.eql(u8, prev, next)) return .same;

    const hp = try allocator.alloc(u64, height);
    defer allocator.free(hp);
    const hn = try allocator.alloc(u64, height);
    defer allocator.free(hn);
    for (0..height) |i| {
        hp[i] = rowHash(prev[i * row_bytes ..][0..row_bytes]);
        hn[i] = rowHash(next[i * row_bytes ..][0..row_bytes]);
    }

    const band_start = height / 10;
    const band_end = height - height / 10;
    // Try every shift and keep the one where the most rows agree. Rows need
    // not all match: a browser's scroll animation can leave a few different.
    var best_d: usize = 0;
    var best_matches: usize = 0;
    var best_total: usize = 1;
    var d: usize = 1;
    while (d < band_end - band_start) : (d += 1) {
        // next row i shows what was at prev row i + d.
        const total = band_end - d - band_start;
        var matches: usize = 0;
        var i = band_start;
        while (i + d < band_end) : (i += 1) {
            if (hn[i] == hp[i + d]) matches += 1;
        }
        // Compare fractions without division: matches/total > best.
        if (matches * best_total > best_matches * total) {
            best_d = d;
            best_matches = matches;
            best_total = total;
        }
    }
    // Accept only a strong agreement (97% of the compared rows).
    if (best_d > 0 and best_matches * 100 >= best_total * 97) return .{ .moved = best_d };
    return .unknown;
}

test "bgra to rgba swaps red and blue and forces opaque" {
    const src = [_]u8{ 1, 2, 3, 0, 10, 20, 30, 0 }; // two pixels, B G R X
    var dst: [8]u8 = undefined;
    toRgba(&dst, &src, 2, 1, 8, .bgra, false);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255, 30, 20, 10, 255 }, &dst);
}

test "rgba layout keeps channel order" {
    const src = [_]u8{ 1, 2, 3, 0 };
    var dst: [4]u8 = undefined;
    toRgba(&dst, &src, 1, 1, 4, .rgba, false);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, &dst);
}

test "stride padding is skipped and flip mirrors rows" {
    // 1 pixel wide, 2 rows, stride 8 (4 bytes padding per row).
    const src = [_]u8{ 1, 1, 1, 0, 9, 9, 9, 9, 2, 2, 2, 0, 9, 9, 9, 9 };
    var dst: [8]u8 = undefined;
    toRgba(&dst, &src, 1, 2, 8, .bgra, true);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 255, 1, 1, 1, 255 }, &dst);
}

test "drag rectangles normalise in any direction" {
    const a = normalize(10, 20, 50, 80);
    const b = normalize(50, 80, 10, 20);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 40, .h = 60 }, a);
}

test "widget rectangle maps and clamps to the image" {
    // Widget is half the image size.
    const r = toImage(.{ .x = 10, .y = 10, .w = 20, .h = 20 }, 100, 50, 200, 100).?;
    try std.testing.expectEqual(Rect{ .x = 20, .y = 20, .w = 40, .h = 40 }, r);
    // Off the edge is clipped.
    const edge = toImage(.{ .x = 90, .y = 0, .w = 50, .h = 10 }, 100, 50, 200, 100).?;
    try std.testing.expectEqual(@as(i32, 20), edge.w);
    try std.testing.expect(toImage(.{ .x = 0, .y = 0, .w = 0, .h = 5 }, 100, 50, 200, 100) == null);
}

test "file name" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Screenshot-2026-10-30-04-05-09.png", fileName(&buf, 2026, 10, 30, 4, 5, 9));
}

/// A frame whose row r is filled with the byte (offset + r) % 251 + 1.
fn testFrame(allocator: std.mem.Allocator, width: usize, height: usize, offset: usize) ![]u8 {
    const frame = try allocator.alloc(u8, width * height * 4);
    for (0..height) |r| @memset(frame[r * width * 4 ..][0 .. width * 4], @intCast((offset + r) % 251 + 1));
    return frame;
}

test "a scrolled frame is matched to the right shift" {
    const a = std.testing.allocator;
    const prev = try testFrame(a, 4, 100, 0);
    defer a.free(prev);
    const next = try testFrame(a, 4, 100, 30); // content moved up 30 rows
    defer a.free(next);
    const result = try findScroll(a, prev, next, 4, 100);
    try std.testing.expectEqual(Scroll{ .moved = 30 }, result);
}

test "identical frames mean the page stopped" {
    const a = std.testing.allocator;
    const frame = try testFrame(a, 4, 64, 7);
    defer a.free(frame);
    try std.testing.expectEqual(Scroll.same, try findScroll(a, frame, frame, 4, 64));
}

test "a jump with no overlap is unknown" {
    const a = std.testing.allocator;
    const prev = try testFrame(a, 4, 100, 0);
    defer a.free(prev);
    const next = try testFrame(a, 4, 100, 120); // scrolled past everything
    defer a.free(next);
    try std.testing.expectEqual(Scroll.unknown, try findScroll(a, prev, next, 4, 100));
}

test "a fixed header and footer do not prevent a match" {
    const a = std.testing.allocator;
    const prev = try testFrame(a, 4, 100, 0);
    defer a.free(prev);
    const next = try testFrame(a, 4, 100, 25);
    defer a.free(next);
    // Both frames keep the same 5-row header and 5-row footer.
    for (0..5) |r| {
        @memset(prev[r * 16 ..][0..16], 250);
        @memset(next[r * 16 ..][0..16], 250);
        @memset(prev[(95 + r) * 16 ..][0..16], 251);
        @memset(next[(95 + r) * 16 ..][0..16], 251);
    }
    try std.testing.expectEqual(Scroll{ .moved = 25 }, try findScroll(a, prev, next, 4, 100));
}

test "a few animation artefacts do not break the match" {
    const a = std.testing.allocator;
    const prev = try testFrame(a, 4, 200, 0);
    defer a.free(prev);
    const next = try testFrame(a, 4, 200, 40);
    defer a.free(next);
    // Smear two rows in the middle of the new frame.
    @memset(next[100 * 16 ..][0..16], 77);
    @memset(next[101 * 16 ..][0..16], 78);
    try std.testing.expectEqual(Scroll{ .moved = 40 }, try findScroll(a, prev, next, 4, 200));
}
