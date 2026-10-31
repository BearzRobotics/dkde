//! The file clipboard (SPEC.md 5.4): what is put on the system clipboard when
//! files are cut or copied, and how it is read back. Other file managers use
//! the same two formats, so files move between them and dkde-files.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// GNOME's (and so most file managers') format: `copy` or `cut`, then one URI
/// per line.
pub const gnome_mime = "x-special/gnome-copied-files";
pub const uri_list_mime = "text/uri-list";

pub fn gnomeText(allocator: Allocator, cut: bool, uris: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, if (cut) "cut" else "copy");
    for (uris) |u| {
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, u);
    }
    return out.toOwnedSlice(allocator);
}

pub fn uriListText(allocator: Allocator, uris: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (uris) |u| {
        try out.appendSlice(allocator, u);
        try out.appendSlice(allocator, "\r\n");
    }
    return out.toOwnedSlice(allocator);
}

pub const Parsed = struct {
    cut: bool,
    /// Slices of the text that was parsed.
    uris: [][]const u8,

    pub fn deinit(self: Parsed, allocator: Allocator) void {
        allocator.free(self.uris);
    }
};

/// Reads either format. A plain URI list means copy.
pub fn parse(allocator: Allocator, text: []const u8) Allocator.Error!Parsed {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var cut = false;
    var first = true;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| {
        if (first) {
            first = false;
            if (std.mem.eql(u8, line, "cut")) {
                cut = true;
                continue;
            }
            if (std.mem.eql(u8, line, "copy")) continue;
        }
        if (line[0] == '#') continue;
        try out.append(allocator, line);
    }
    return .{ .cut = cut, .uris = try out.toOwnedSlice(allocator) };
}

test "gnome format round trip" {
    const a = std.testing.allocator;
    const text = try gnomeText(a, true, &.{ "file:///a%20b", "file:///c" });
    defer a.free(text);
    try std.testing.expectEqualStrings("cut\nfile:///a%20b\nfile:///c", text);
    const p = try parse(a, text);
    defer p.deinit(a);
    try std.testing.expect(p.cut);
    try std.testing.expectEqual(@as(usize, 2), p.uris.len);
    try std.testing.expectEqualStrings("file:///c", p.uris[1]);
}

test "uri lists are copies and skip comments" {
    const a = std.testing.allocator;
    const p = try parse(a, "# note\r\nfile:///x\r\nfile:///y\r\n");
    defer p.deinit(a);
    try std.testing.expect(!p.cut);
    try std.testing.expectEqual(@as(usize, 2), p.uris.len);
    const out = try uriListText(a, p.uris);
    defer a.free(out);
    try std.testing.expectEqualStrings("file:///x\r\nfile:///y\r\n", out);
}
