//! Pure helpers for the image viewer.

const std = @import("std");

const extensions = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tif", ".tiff", ".svg", ".ico", ".avif", ".jxl" };

/// Whether a file name looks like an image gdk-pixbuf may be able to load.
pub fn isImageName(name: []const u8) bool {
    for (extensions) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

pub const zoom_min = 0.05;
pub const zoom_max = 16.0;

pub fn clampZoom(zoom: f64) f64 {
    return std.math.clamp(zoom, zoom_min, zoom_max);
}

/// The next zoom step up or down: ×1.25 / ÷1.25.
pub fn stepZoom(zoom: f64, in: bool) f64 {
    return clampZoom(if (in) zoom * 1.25 else zoom / 1.25);
}

/// Index of the neighbour of `current` in a list of `len`, wrapping.
pub fn neighbour(current: usize, len: usize, forward: bool) usize {
    if (len == 0) return 0;
    return if (forward) (current + 1) % len else (current + len - 1) % len;
}

test "image names" {
    try std.testing.expect(isImageName("a.PNG"));
    try std.testing.expect(isImageName("x.jpeg"));
    try std.testing.expect(!isImageName("x.txt"));
}

test "zoom stays in range and steps" {
    try std.testing.expectEqual(@as(f64, zoom_max), clampZoom(100));
    try std.testing.expectEqual(@as(f64, zoom_min), clampZoom(0));
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), stepZoom(1, true), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), stepZoom(1, false), 1e-9);
    try std.testing.expectEqual(@as(f64, zoom_max), stepZoom(zoom_max, true));
}

test "neighbour wraps" {
    try std.testing.expectEqual(@as(usize, 0), neighbour(2, 3, true));
    try std.testing.expectEqual(@as(usize, 2), neighbour(0, 3, false));
    try std.testing.expectEqual(@as(usize, 0), neighbour(0, 0, true));
}
