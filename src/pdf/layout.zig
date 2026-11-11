//! Where pages sit in the scrolling column of the PDF viewer, and zoom steps.
//! Pure, so it is unit tested.

const std = @import("std");

pub const Size = struct { w: f64, h: f64 };

/// How pages are arranged: one column, or two pages side by side (with the
/// first page alone, as a book's cover, when `cover`).
pub const Mode = struct {
    dual: bool = false,
    cover: bool = false,
};

pub const Layout = struct {
    /// Top edge of each page, in pixels from the top of the column. Pages
    /// side by side share a top, so this never decreases.
    tops: []f64,
    /// Left edge of each page, in pixels from the left of the column (the
    /// column is `max_width` wide and centred in the view).
    xs: []f64,
    /// Scaled page sizes.
    sizes: []Size,
    total_height: f64,
    max_width: f64,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.tops);
        allocator.free(self.xs);
        allocator.free(self.sizes);
    }
};

/// Stacks pages top to bottom with `gap` between them and `margin` above the
/// first and below the last. `page_sizes` are in points; `scale` converts to pixels.
pub fn compute(allocator: std.mem.Allocator, page_sizes: []const Size, scale: f64, gap: f64, margin: f64) !Layout {
    return computeMode(allocator, page_sizes, scale, gap, margin, .{});
}

/// Whether page `i` starts a row in `mode`.
fn startsRow(mode: Mode, i: usize) bool {
    if (!mode.dual) return true;
    return if (mode.cover) (i == 0 or i % 2 == 1) else i % 2 == 0;
}

/// Like `compute`, with pages in one or two columns. Each row is centred in
/// the column; pages of a row share its top edge.
pub fn computeMode(allocator: std.mem.Allocator, page_sizes: []const Size, scale: f64, gap: f64, margin: f64, mode: Mode) !Layout {
    const n = page_sizes.len;
    const tops = try allocator.alloc(f64, n);
    errdefer allocator.free(tops);
    const xs = try allocator.alloc(f64, n);
    errdefer allocator.free(xs);
    const sizes = try allocator.alloc(Size, n);
    errdefer allocator.free(sizes);
    for (page_sizes, 0..) |p, i| sizes[i] = .{ .w = @ceil(p.w * scale), .h = @ceil(p.h * scale) };

    // Rows: their pages' tops, and the widest row.
    var y = margin;
    var widest: f64 = 0;
    var i: usize = 0;
    while (i < n) {
        const two = startsRow(mode, i) and i + 1 < n and !startsRow(mode, i + 1);
        const row_h = if (two) @max(sizes[i].h, sizes[i + 1].h) else sizes[i].h;
        const row_w = if (two) sizes[i].w + gap + sizes[i + 1].w else sizes[i].w;
        tops[i] = y;
        if (two) tops[i + 1] = y;
        widest = @max(widest, row_w);
        y += row_h + gap;
        i += if (two) 2 else 1;
    }
    // Each row centred in the column.
    i = 0;
    while (i < n) {
        const two = startsRow(mode, i) and i + 1 < n and !startsRow(mode, i + 1);
        const row_w = if (two) sizes[i].w + gap + sizes[i + 1].w else sizes[i].w;
        xs[i] = (widest - row_w) / 2;
        if (two) xs[i + 1] = xs[i] + sizes[i].w + gap;
        i += if (two) 2 else 1;
    }
    return .{ .tops = tops, .xs = xs, .sizes = sizes, .total_height = if (n == 0) 2 * margin else y - gap + margin, .max_width = widest };
}

/// The page under the point (`x` from the column's left edge, `y` from its
/// top): `pageAt` for the row, then the page of the row nearest to `x`.
pub fn pageAtPoint(l: Layout, x: f64, y: f64) usize {
    var i = pageAt(l, y);
    // Pages of a row share a top: step left while the point is left of this one.
    while (i > 0 and l.tops[i - 1] == l.tops[i] and x < l.xs[i]) i -= 1;
    return i;
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

test "two pages side by side, and a cover alone" {
    const a = std.testing.allocator;
    const pages = [_]Size{ .{ .w = 100, .h = 200 }, .{ .w = 100, .h = 200 }, .{ .w = 100, .h = 200 } };
    var l = try computeMode(a, &pages, 1.0, 10, 0, .{ .dual = true });
    defer l.deinit(a);
    // Pages 1 and 2 share a row; page 3 starts the next, centred.
    try std.testing.expectEqual(l.tops[0], l.tops[1]);
    try std.testing.expectEqual(@as(f64, 210), l.tops[2]);
    try std.testing.expectEqual(@as(f64, 210), l.max_width);
    try std.testing.expectEqual(@as(f64, 0), l.xs[0]);
    try std.testing.expectEqual(@as(f64, 110), l.xs[1]);
    try std.testing.expectEqual(@as(f64, 55), l.xs[2]);
    try std.testing.expectEqual(@as(usize, 0), pageAtPoint(l, 50, 100));
    try std.testing.expectEqual(@as(usize, 1), pageAtPoint(l, 150, 100));
    try std.testing.expectEqual(@as(usize, 2), pageAtPoint(l, 100, 300));

    var book = try computeMode(a, &pages, 1.0, 10, 0, .{ .dual = true, .cover = true });
    defer book.deinit(a);
    // The cover alone, then pages 2 and 3 together.
    try std.testing.expectEqual(@as(f64, 0), book.tops[0]);
    try std.testing.expectEqual(book.tops[1], book.tops[2]);
    try std.testing.expect(book.tops[1] > book.tops[0]);
    try std.testing.expectEqual(@as(usize, 2), pageAtPoint(book, 200, book.tops[1] + 10));
}

test "empty document" {
    const a = std.testing.allocator;
    var l = try compute(a, &.{}, 1.0, 10, 20);
    defer l.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), pageAt(l, 100));
    try std.testing.expectEqual([2]usize{ 0, 0 }, visibleRange(l, 0, 100));
}
