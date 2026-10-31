//! Wallpaper slideshow helpers: which files count as images, and how the
//! `fit` setting maps to a GTK content fit.

const std = @import("std");
const gtk = @import("gtk4");

const extensions = [_][]const u8{ ".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".svg" };

pub fn isImageName(name: []const u8) bool {
    for (extensions) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

pub fn fitFromName(name: []const u8) gtk.ContentFit {
    if (std.mem.eql(u8, name, "fill")) return .fill;
    if (std.mem.eql(u8, name, "contain")) return .contain;
    if (std.mem.eql(u8, name, "center")) return .scale_down;
    return .cover;
}

test "image file names" {
    try std.testing.expect(isImageName("sunset.JPG"));
    try std.testing.expect(isImageName("a.webp"));
    try std.testing.expect(!isImageName("notes.txt"));
    try std.testing.expect(!isImageName("png"));
}

test "fit names" {
    try std.testing.expectEqual(gtk.ContentFit.fill, fitFromName("fill"));
    try std.testing.expectEqual(gtk.ContentFit.scale_down, fitFromName("center"));
    try std.testing.expectEqual(gtk.ContentFit.cover, fitFromName("anything-else"));
}
