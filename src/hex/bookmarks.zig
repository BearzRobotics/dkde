//! Bookmarks and comments on ranges of a file (SPEC.md 5.6). They are kept in
//! the state folder, one small JSON file per opened path, and written only
//! when the user adds, changes or removes one.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Bookmark = struct {
    start: u64,
    len: u64,
    name: []const u8,
    comment: []const u8 = "",
};

pub const List = struct {
    items: std.ArrayList(Bookmark) = .empty,

    pub fn deinit(self: *List, a: Allocator) void {
        for (self.items.items) |b| {
            a.free(b.name);
            a.free(b.comment);
        }
        self.items.deinit(a);
    }

    /// Keeps the list ordered by start.
    pub fn add(self: *List, a: Allocator, start: u64, len: u64, name: []const u8, comment: []const u8) Allocator.Error!void {
        const b: Bookmark = .{ .start = start, .len = len, .name = try a.dupe(u8, name), .comment = try a.dupe(u8, comment) };
        errdefer {
            a.free(b.name);
            a.free(b.comment);
        }
        var index: usize = self.items.items.len;
        for (self.items.items, 0..) |x, i| if (x.start > start) {
            index = i;
            break;
        };
        try self.items.insert(a, index, b);
    }

    pub fn remove(self: *List, a: Allocator, index: usize) void {
        const b = self.items.orderedRemove(index);
        a.free(b.name);
        a.free(b.comment);
    }

    /// Replaces the text of one bookmark.
    pub fn edit(self: *List, a: Allocator, index: usize, name: []const u8, comment: []const u8) Allocator.Error!void {
        const n = try a.dupe(u8, name);
        errdefer a.free(n);
        const c = try a.dupe(u8, comment);
        a.free(self.items.items[index].name);
        a.free(self.items.items[index].comment);
        self.items.items[index].name = n;
        self.items.items[index].comment = c;
    }

    /// The first bookmark that covers `offset`.
    pub fn at(self: *const List, offset: u64) ?usize {
        for (self.items.items, 0..) |b, i| if (offset >= b.start and offset < b.start + @max(b.len, 1)) return i;
        return null;
    }
};

const Stored = struct { start: u64, len: u64, name: []const u8, comment: []const u8 = "" };

pub fn toJson(a: Allocator, list: *const List) ![]u8 {
    const stored = try a.alloc(Stored, list.items.items.len);
    defer a.free(stored);
    for (list.items.items, stored) |b, *s| s.* = .{ .start = b.start, .len = b.len, .name = b.name, .comment = b.comment };
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try std.json.Stringify.value(.{ .bookmarks = stored }, .{ .whitespace = .indent_2 }, &out.writer);
    return out.toOwnedSlice();
}

pub fn fromJson(a: Allocator, text: []const u8) !List {
    const Doc = struct { bookmarks: []const Stored = &.{} };
    const parsed = try std.json.parseFromSlice(Doc, a, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var list: List = .{};
    errdefer list.deinit(a);
    for (parsed.value.bookmarks) |s| try list.add(a, s.start, s.len, s.name, s.comment);
    return list;
}

/// A short stable name for the state file of `path`.
pub fn fileKey(buf: *[32]u8, path: []const u8) []const u8 {
    const h = std.hash.Wyhash.hash(0, path);
    return std.fmt.bufPrint(buf, "{x:0>16}.json", .{h}) catch "bookmarks.json";
}

test "bookmarks stay ordered and round trip through json" {
    const a = std.testing.allocator;
    var l: List = .{};
    defer l.deinit(a);
    try l.add(a, 100, 4, "magic", "file signature");
    try l.add(a, 10, 2, "version", "");
    try l.add(a, 50, 1, "flag \"x\"", "quote");
    try std.testing.expectEqual(@as(u64, 10), l.items.items[0].start);
    try std.testing.expectEqual(@as(?usize, 1), l.at(50));
    try std.testing.expectEqual(@as(?usize, null), l.at(60));

    const json = try toJson(a, &l);
    defer a.free(json);
    var back = try fromJson(a, json);
    defer back.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), back.items.items.len);
    try std.testing.expectEqualStrings("flag \"x\"", back.items.items[1].name);
    try std.testing.expectEqualStrings("file signature", back.items.items[2].comment);

    try l.edit(a, 0, "renamed", "note");
    try std.testing.expectEqualStrings("renamed", l.items.items[0].name);
    l.remove(a, 0);
    try std.testing.expectEqual(@as(usize, 2), l.items.items.len);
}

test "the file key is stable and differs by path" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    const k1 = fileKey(&a, "/x/y");
    const k2 = fileKey(&b, "/x/z");
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
    var c: [32]u8 = undefined;
    try std.testing.expectEqualStrings(k1, fileKey(&c, "/x/y"));
}
