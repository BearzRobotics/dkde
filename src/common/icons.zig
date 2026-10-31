//! Icon themes installed on the system (SPEC.md 5.5), for the Settings picker.

const std = @import("std");
const glib = @import("glib2");

/// True when the text of an `index.theme` describes a theme with icons
/// (cursor themes and the like have no `Directories`).
pub fn isIconTheme(index: []const u8) bool {
    var in_theme = false;
    var lines = std.mem.splitScalar(u8, index, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') in_theme = std.mem.eql(u8, line, "[Icon Theme]");
        if (in_theme and std.mem.startsWith(u8, line, "Directories=") and line.len > "Directories=".len) return true;
    }
    return false;
}

/// True when the theme is marked `Hidden=true` (it is a helper, not for choosing).
fn isHidden(index: []const u8) bool {
    var lines = std.mem.splitScalar(u8, index, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "Hidden=true")) return true;
    }
    return false;
}

fn readText(a: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(path, &contents, &length, null) == 0) return null;
    defer glib.free(contents);
    return a.dupe(u8, contents[0..@min(length, 1 << 20)]) catch null;
}

fn scanDir(a: std.mem.Allocator, base: []const u8, out: *std.ArrayList([]u8)) std.mem.Allocator.Error!void {
    const z = try a.dupeSentinel(u8, base, 0);
    defer a.free(z);
    const dir = glib.Dir.open(z, 0, null) orelse return;
    defer dir.close();
    while (@as(?[*:0]const u8, @ptrCast(dir.readName()))) |n| {
        const name = std.mem.span(n);
        if (name.len == 0 or name[0] == '.') continue;
        for (out.items) |have| if (std.mem.eql(u8, have, name)) break else {} else {
            const index_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}/index.theme", .{ base, name }, 0);
            defer a.free(index_path);
            const text = readText(a, index_path) orelse continue;
            defer a.free(text);
            if (!isIconTheme(text) or isHidden(text)) continue;
            try out.append(a, try a.dupe(u8, name));
        }
    }
}

/// Names of the installed icon themes, sorted. Free with `free`.
pub fn list(a: std.mem.Allocator) std.mem.Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer free(a, out.items);
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}/icons", .{std.mem.span(glib.getUserDataDir())})) |p| try scanDir(a, p, &out) else |_| {}
    if (std.fmt.bufPrint(&buf, "{s}/.icons", .{std.mem.span(glib.getHomeDir())})) |p| try scanDir(a, p, &out) else |_| {}
    const dirs: [*:null]const ?[*:0]const u8 = @ptrCast(glib.getSystemDataDirs());
    var i: usize = 0;
    while (dirs[i]) |d| : (i += 1) {
        if (std.fmt.bufPrint(&buf, "{s}/icons", .{std.mem.span(d)})) |p| try scanDir(a, p, &out) else |_| {}
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn less(_: void, x: []u8, y: []u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.less);
    return out.toOwnedSlice(a);
}

pub fn free(a: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| a.free(n);
    a.free(names);
}

test "a theme needs directories" {
    try std.testing.expect(isIconTheme("[Icon Theme]\nName=X\nDirectories=16x16/apps,32x32/apps\n"));
    try std.testing.expect(!isIconTheme("[Icon Theme]\nName=Cursors\n"));
    try std.testing.expect(!isIconTheme("[Other]\nDirectories=a\n"));
    try std.testing.expect(isHidden("[Icon Theme]\nHidden=true\n"));
}
