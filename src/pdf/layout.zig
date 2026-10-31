//! Where pages sit in the scrolling column of the PDF viewer, and zoom steps.
//! Pure, so it is unit tested.

const std = @import("std");

pub const Size = struct { w: f64, h: f64 };

pub const Layout = struct {
    /// Top edge of each page, in pixels from the top of the column.
    tops: []f64,
    /// Scaled page sizes.
    sizes: []Size,
    total_height: f64,
    max_width: f64,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.tops);
        allocator.free(self.sizes);
    }
};

/// Stacks pages top to bottom with `gap` between them and `margin` above the
/// first and below the last. `page_sizes` are in points; `scale` converts to pixels.
pub fn compute(allocator: std.mem.Allocator, page_sizes: []const Size, scale: f64, gap: f64, margin: f64) !Layout {
    const tops = try allocator.alloc(f64, page_sizes.len);
    errdefer allocator.free(tops);
    const sizes = try allocator.alloc(Size, page_sizes.len);
    errdefer allocator.free(sizes);
    var y = margin;
    var widest: f64 = 0;
    for (page_sizes, 0..) |p, i| {
        sizes[i] = .{ .w = @ceil(p.w * scale), .h = @ceil(p.h * scale) };
        tops[i] = y;
        y += sizes[i].h + gap;
        widest = @max(widest, sizes[i].w);
    }
    return .{ .tops = tops, .sizes = sizes, .total_height = y - gap + margin, .max_width = widest };
}

/// The page that contains the pixel row `y`, or the nearest one when `y` falls
/// in a gap or outside the column.
pub fn pageAt(l: Layout, y: f64) usize {
    if (l.tops.len == 0) return 0;
    var lo: usize = 0;
    var hi: usize = l.tops.len;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (l.tops[mid] <= y) lo = mid else hi = mid;
    }
    return lo;
}

/// Pages whose rows overlap [top, bottom], as an index range (inclusive start, exclusive end).
pub fn visibleRange(l: Layout, top: f64, bottom: f64) [2]usize {
    if (l.tops.len == 0) return .{ 0, 0 };
    const first = pageAt(l, top);
    var end = first;
    while (end < l.tops.len and l.tops[end] < bottom) end += 1;
    return .{ first, @max(end, first + 1) };
}

pub const zoom_steps = [_]f64{ 0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 6.0 };

/// The next preset above (`up`) or below the current zoom.
pub fn stepZoom(current: f64, up: bool) f64 {
    if (up) {
        for (zoom_steps) |z| if (z > current + 0.001) return z;
        return zoom_steps[zoom_steps.len - 1];
    }
    var i: usize = zoom_steps.len;
    while (i > 0) : (i -= 1) if (zoom_steps[i - 1] < current - 0.001) return zoom_steps[i - 1];
    return zoom_steps[0];
}

/// Zoom that makes a page `page_w` points wide fill `available` pixels at 96 dpi.
pub fn fitWidth(page_w: f64, available: f64) f64 {
    return std.math.clamp(available / (page_w * 96.0 / 72.0), 0.1, 8.0);
}

pub fn fitPage(page_w: f64, page_h: f64, avail_w: f64, avail_h: f64) f64 {
    return @min(fitWidth(page_w, avail_w), std.math.clamp(avail_h / (page_h * 96.0 / 72.0), 0.1, 8.0));
}

test "layout stacks pages" {
    const a = std.testing.allocator;
    var l = try compute(a, &.{ .{ .w = 100, .h = 200 }, .{ .w = 150, .h = 100 } }, 1.0, 10, 20);
    defer l.deinit(a);
    try std.testing.expectEqual(@as(f64, 20), l.tops[0]);
    try std.testing.expectEqual(@as(f64, 230), l.tops[1]);
    try std.testing.expectEqual(@as(f64, 150), l.max_width);
    try std.testing.expectEqual(@as(f64, 350), l.total_height);
}

test "which page is at a row" {
    const a = std.testing.allocator;
    var l = try compute(a, &.{ .{ .w = 100, .h = 200 }, .{ .w = 100, .h = 200 }, .{ .w = 100, .h = 200 } }, 1.0, 10, 0);
    defer l.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), pageAt(l, 0));
    try std.testing.expectEqual(@as(usize, 0), pageAt(l, 205)); // in the gap
    try std.testing.expectEqual(@as(usize, 1), pageAt(l, 210));
    try std.testing.expectEqual(@as(usize, 2), pageAt(l, 5000));
    const r = visibleRange(l, 150, 300);
    try std.testing.expectEqual([2]usize{ 0, 2 }, r);
}

test "zoom steps and fitting" {
    try std.testing.expectEqual(@as(f64, 1.25), stepZoom(1.0, true));
    try std.testing.expectEqual(@as(f64, 0.9), stepZoom(1.0, false));
    try std.testing.expectEqual(@as(f64, 6.0), stepZoom(6.0, true));
    try std.testing.expectEqual(@as(f64, 0.25), stepZoom(0.25, false));
    // A 612 pt (US Letter) page filling 816 px is 100%.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), fitWidth(612, 816), 0.001);
    try std.testing.expect(fitPage(612, 792, 2000, 400) < fitWidth(612, 2000));
}

test "empty document" {
    const a = std.testing.allocator;
    var l = try compute(a, &.{}, 1.0, 10, 20);
    defer l.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), pageAt(l, 100));
    try std.testing.expectEqual([2]usize{ 0, 0 }, visibleRange(l, 0, 100));
}
