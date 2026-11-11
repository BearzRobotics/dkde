//! Where each document was left: its page, zoom and fit, so that opening it
//! again goes back there (as Evince and Okular do). Kept in
//! `$XDG_STATE_HOME/dkde/pdf-places`, one line per document, the most
//! recently closed first:
//!
//!     page<TAB>fit<TAB>zoom<TAB>path
//!
//! A path cannot hold a newline here; such a file is simply not remembered.

const std = @import("std");

pub const Fit = enum { custom, width, page };

pub const Place = struct {
    /// Zero-based page at the top of the view.
    page: usize = 0,
    fit: Fit = .width,
    zoom: f64 = 1.0,
};

/// The most documents remembered; older ones are forgotten.
pub const limit = 500;

/// The place stored for `path` in `text`, if any.
pub fn find(text: []const u8, path: []const u8) ?Place {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const entry = parseLine(line) orelse continue;
        if (std.mem.eql(u8, entry.path, path)) return entry.place;
    }
    return null;
}

const Entry = struct { place: Place, path: []const u8 };

fn parseLine(line: []const u8) ?Entry {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const page = std.fmt.parseInt(usize, fields.next() orelse return null, 10) catch return null;
    const fit = std.meta.stringToEnum(Fit, fields.next() orelse return null) orelse return null;
    const zoom = std.fmt.parseFloat(f64, fields.next() orelse return null) catch return null;
    // The path is the rest of the line: it may itself hold a tab.
    const path = fields.rest();
    if (path.len == 0 or !std.math.isFinite(zoom)) return null;
    return .{ .place = .{ .page = page, .fit = fit, .zoom = std.math.clamp(zoom, 0.1, 8.0) }, .path = path };
}

/// `text` with `path`'s line replaced by `place` and moved to the top, and
/// at most `limit` lines kept. The caller frees the result.
pub fn put(gpa: std.mem.Allocator, text: []const u8, path: []const u8, place: Place) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var kept: usize = 0;
    if (std.mem.indexOfScalar(u8, path, '\n') == null and path.len > 0) {
        try w.print("{d}\t{s}\t{d:.4}\t{s}\n", .{ place.page, @tagName(place.fit), place.zoom, path });
        kept = 1;
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (kept >= limit) break;
        const entry = parseLine(line) orelse continue;
        if (std.mem.eql(u8, entry.path, path)) continue;
        try w.print("{s}\n", .{line});
        kept += 1;
    }
    return out.toOwnedSlice();
}

test "a place is stored, found and moved to the top" {
    const gpa = std.testing.allocator;
    const one = try put(gpa, "", "/a.pdf", .{ .page = 3, .fit = .width, .zoom = 1.5 });
    defer gpa.free(one);
    const two = try put(gpa, one, "/b\tc.pdf", .{ .page = 7, .fit = .custom, .zoom = 2.25 });
    defer gpa.free(two);
    const three = try put(gpa, two, "/a.pdf", .{ .page = 9, .fit = .page, .zoom = 1 });
    defer gpa.free(three);

    try std.testing.expect(std.mem.startsWith(u8, three, "9\tpage\t"));
    const a = find(three, "/a.pdf").?;
    try std.testing.expectEqual(@as(usize, 9), a.page);
    try std.testing.expectEqual(Fit.page, a.fit);
    const b = find(three, "/b\tc.pdf").?;
    try std.testing.expectEqual(@as(usize, 7), b.page);
    try std.testing.expectApproxEqAbs(@as(f64, 2.25), b.zoom, 1e-9);
    try std.testing.expect(find(three, "/c.pdf") == null);
    // Exactly one line per document.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, three, "\n"));
}

test "damaged lines and odd paths are ignored" {
    const gpa = std.testing.allocator;
    const text = "x\twidth\t1\t/bad.pdf\n2\tsideways\t1\t/bad2.pdf\n4\twidth\tnan\t/bad3.pdf\n5\twidth\t99\t/big.pdf\n";
    try std.testing.expect(find(text, "/bad.pdf") == null);
    try std.testing.expect(find(text, "/bad2.pdf") == null);
    try std.testing.expect(find(text, "/bad3.pdf") == null);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), find(text, "/big.pdf").?.zoom, 1e-9);
    const out = try put(gpa, text, "/new\nline.pdf", .{});
    defer gpa.free(out);
    try std.testing.expect(find(out, "/new\nline.pdf") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
}

test "only the newest documents are kept" {
    const gpa = std.testing.allocator;
    var text: []u8 = try gpa.dupe(u8, "");
    defer gpa.free(text);
    var buf: [32]u8 = undefined;
    for (0..limit + 20) |i| {
        const next = try put(gpa, text, try std.fmt.bufPrint(&buf, "/{d}.pdf", .{i}), .{ .page = i });
        gpa.free(text);
        text = next;
    }
    try std.testing.expectEqual(@as(usize, limit), std.mem.count(u8, text, "\n"));
    try std.testing.expect(find(text, "/0.pdf") == null);
    try std.testing.expectEqual(@as(usize, limit + 19), find(text, try std.fmt.bufPrint(&buf, "/{d}.pdf", .{limit + 19})).?.page);
}
