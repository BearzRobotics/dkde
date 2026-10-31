//! The context menu's configuration (SPEC.md 5.4): which entries, in what
//! order, and the commands the user added.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const default_quick = "cut;copy;paste;rename;trash";
pub const default_item = "open;open-tab;open-window;open-with;run;run-admin;exec;--;extract;compress-zip;compress-targz;restore;delete-permanent;--;properties";
pub const default_folder = "new-folder;open-window;terminal-here;open-admin;toggle-hidden;bookmark;empty-trash;--;properties";

pub const separator = "--";
pub const command_prefix = "cmd:";

/// Splits `a;b;--;c` into its ids. The slices point into `text`.
pub fn parseList(allocator: Allocator, text: []const u8) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, ';');
    while (it.next()) |part| {
        const id = std.mem.trim(u8, part, " \t");
        if (id.len > 0) try out.append(allocator, id);
    }
    return out.toOwnedSlice(allocator);
}

/// The emoji on the quick row's button.
pub fn emoji(id: []const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "cut", "\u{2702}\u{FE0F}" },
        .{ "copy", "\u{1F4C4}" },
        .{ "paste", "\u{1F4CB}" },
        .{ "rename", "\u{270F}\u{FE0F}" },
        .{ "trash", "\u{1F5D1}\u{FE0F}" },
        .{ "delete-permanent", "\u{274C}" },
        .{ "restore", "\u{21A9}\u{FE0F}" },
        .{ "open", "\u{1F4C2}" },
        .{ "open-tab", "\u{1F5C2}\u{FE0F}" },
        .{ "open-window", "\u{1FA9F}" },
        .{ "properties", "\u{2139}\u{FE0F}" },
        .{ "new-folder", "\u{1F4C1}" },
        .{ "run", "\u{25B6}\u{FE0F}" },
        .{ "run-admin", "\u{1F6E1}\u{FE0F}" },
        .{ "exec", "\u{2699}\u{FE0F}" },
        .{ "terminal-here", "\u{1F5A5}\u{FE0F}" },
        .{ "bookmark", "\u{2B50}" },
        .{ "toggle-hidden", "\u{1F441}\u{FE0F}" },
        .{ "extract", "\u{1F4E4}" },
        .{ "compress-zip", "\u{1F5DC}\u{FE0F}" },
        .{ "compress-targz", "\u{1F4E6}" },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], id)) return row[1];
    return "\u{2022}";
}

/// `'text'` for a POSIX shell, whatever `text` holds.
pub fn shellQuote(allocator: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(allocator, '\'');
    for (text) |c| {
        if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
}

/// Fills in `%f` (the first file), `%F` (all of them), `%d` (the folder) and
/// `%%`; paths are quoted for the shell.
pub fn expand(allocator: Allocator, template: []const u8, files: []const []const u8, dir: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        const c = template[i];
        if (c != '%' or i + 1 >= template.len) {
            try out.append(allocator, c);
            continue;
        }
        i += 1;
        switch (template[i]) {
            'f' => if (files.len > 0) try shellQuote(allocator, &out, files[0]),
            'F' => for (files, 0..) |f, n| {
                if (n > 0) try out.append(allocator, ' ');
                try shellQuote(allocator, &out, f);
            },
            'd' => try shellQuote(allocator, &out, dir),
            '%' => try out.append(allocator, '%'),
            else => {
                try out.append(allocator, '%');
                try out.append(allocator, template[i]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

test "lists" {
    const a = std.testing.allocator;
    const ids = try parseList(a, "open; --;cut;;cmd:Hash");
    defer a.free(ids);
    try std.testing.expectEqual(@as(usize, 4), ids.len);
    try std.testing.expectEqualStrings(separator, ids[1]);
    try std.testing.expectEqualStrings("cmd:Hash", ids[3]);
}

test "placeholders are quoted" {
    const a = std.testing.allocator;
    const s = try expand(a, "sha256sum %F in %d 100%%", &.{ "/tmp/it's here", "/b" }, "/tmp");
    defer a.free(s);
    try std.testing.expectEqualStrings("sha256sum '/tmp/it'\\''s here' '/b' in '/tmp' 100%", s);
}
