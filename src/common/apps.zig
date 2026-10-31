//! Application lookup logic shared by the start menu and anything else that
//! lists or launches desktop entries (SPEC.md 5.2, 4.2).

const std = @import("std");

/// Search rank of one app against `query`; lower is better, null is no match.
/// Prefix matches rank above substring matches, and Name above GenericName
/// above Keywords. Comparison is ASCII case-insensitive.
pub fn rank(query: []const u8, name: []const u8, generic_name: ?[]const u8, keywords: []const []const u8) ?u8 {
    if (query.len == 0) return null;
    if (matchKind(query, name)) |k| return k;
    if (generic_name) |g| if (matchKind(query, g)) |k| return 2 + k;
    var best: ?u8 = null;
    for (keywords) |keyword| {
        if (matchKind(query, keyword)) |k| best = @min(best orelse 255, 4 + k);
    }
    return best;
}

/// 0 for a prefix match, 1 for a substring match.
fn matchKind(query: []const u8, haystack: []const u8) ?u8 {
    if (std.ascii.startsWithIgnoreCase(haystack, query)) return 0;
    if (std.ascii.findIgnoreCase(haystack, query) != null) return 1;
    return null;
}

/// The folders of the "All Programs" tree: the XDG menu spec's main
/// categories, in display order.
pub const Category = enum {
    accessories,
    development,
    education,
    games,
    graphics,
    internet,
    multimedia,
    office,
    settings,
    system,
    other,

    pub fn label(self: Category) [:0]const u8 {
        return switch (self) {
            .accessories => "Accessories",
            .development => "Development",
            .education => "Education",
            .games => "Games",
            .graphics => "Graphics",
            .internet => "Internet",
            .multimedia => "Multimedia",
            .office => "Office",
            .settings => "Settings",
            .system => "System",
            .other => "Other",
        };
    }
};

/// Picks the folder for a desktop entry from its `Categories=` value
/// (semicolon separated). The first recognised main category wins.
pub fn mainCategory(categories: ?[]const u8) Category {
    const list = categories orelse return .other;
    var it = std.mem.tokenizeScalar(u8, list, ';');
    while (it.next()) |c| {
        const map = [_]struct { []const u8, Category }{
            .{ "Utility", .accessories },
            .{ "Development", .development },
            .{ "Education", .education },
            .{ "Game", .games },
            .{ "Graphics", .graphics },
            .{ "Network", .internet },
            .{ "AudioVideo", .multimedia },
            .{ "Audio", .multimedia },
            .{ "Video", .multimedia },
            .{ "Office", .office },
            .{ "Settings", .settings },
            .{ "System", .system },
        };
        for (map) |entry| if (std.mem.eql(u8, c, entry[0])) return entry[1];
    }
    return .other;
}

/// Moves `id` to the front of `recent` (adding it if new), dropping
/// duplicates and anything beyond `max`. All strings are owned by `allocator`.
pub fn pushRecent(allocator: std.mem.Allocator, recent: *std.ArrayList([]u8), id: []const u8, max: usize) !void {
    const copy = try allocator.dupe(u8, id);
    errdefer allocator.free(copy);

    var i: usize = 0;
    while (i < recent.items.len) {
        if (std.mem.eql(u8, recent.items[i], id)) {
            allocator.free(recent.orderedRemove(i));
        } else i += 1;
    }
    try recent.insert(allocator, 0, copy);
    while (recent.items.len > max) allocator.free(recent.pop().?);
}

test "prefix beats substring, name beats generic name beats keywords" {
    const kw = [_][]const u8{ "browser", "web" };
    try std.testing.expectEqual(@as(?u8, 0), rank("fire", "Firefox", "Web Browser", &kw));
    try std.testing.expectEqual(@as(?u8, 1), rank("fox", "Firefox", "Web Browser", &kw));
    try std.testing.expectEqual(@as(?u8, 2), rank("web", "Firefox", "Web Browser", &.{}));
    try std.testing.expectEqual(@as(?u8, 3), rank("brow", "Firefox", "Web Browser", &.{}));
    try std.testing.expectEqual(@as(?u8, 4), rank("web", "Firefox", null, &kw));
    try std.testing.expectEqual(@as(?u8, null), rank("zzz", "Firefox", "Web Browser", &kw));
}

test "search is case-insensitive and empty queries match nothing" {
    try std.testing.expectEqual(@as(?u8, 0), rank("FIRE", "firefox", null, &.{}));
    try std.testing.expectEqual(@as(?u8, null), rank("", "firefox", null, &.{}));
}

test "main category from Categories" {
    try std.testing.expectEqual(Category.internet, mainCategory("Network;WebBrowser;"));
    try std.testing.expectEqual(Category.accessories, mainCategory("GTK;Utility;TextEditor;"));
    try std.testing.expectEqual(Category.multimedia, mainCategory("AudioVideo;Player;"));
    try std.testing.expectEqual(Category.other, mainCategory("GTK;Foo;"));
    try std.testing.expectEqual(Category.other, mainCategory(null));
}

test "recent list is most-recent-first, deduplicated and capped" {
    const a = std.testing.allocator;
    var recent: std.ArrayList([]u8) = .empty;
    defer {
        for (recent.items) |s| a.free(s);
        recent.deinit(a);
    }
    for ([_][]const u8{ "a", "b", "c", "a", "d" }) |id| try pushRecent(a, &recent, id, 3);
    try std.testing.expectEqual(@as(usize, 3), recent.items.len);
    try std.testing.expectEqualStrings("d", recent.items[0]);
    try std.testing.expectEqualStrings("a", recent.items[1]);
    try std.testing.expectEqualStrings("c", recent.items[2]);
}
