//! Finds the font files a console can use (SPEC.md 5.11, *Fonts*): PSF files
//! in the usual console-font directories, and monospace TrueType files under
//! the system font directories. Used by `dkde-console config fonts` and by the
//! Settings page.

const std = @import("std");
const ttf = @import("ttf.zig");
const psf = @import("psf.zig");

pub const psf_dirs = [_][:0]const u8{ "/usr/share/consolefonts", "/usr/share/kbd/consolefonts", "/lib/kbd/consolefonts", "/usr/lib/kbd/consolefonts" };
pub const ttf_dirs = [_][:0]const u8{ "/usr/share/fonts", "/usr/local/share/fonts" };

pub fn readFile(allocator: std.mem.Allocator, path: [:0]const u8, max: usize) ?[]u8 {
    const f = std.c.fopen(path, "rb") orelse return null;
    defer _ = std.c.fclose(f);
    var list: std.ArrayList(u8) = .empty;
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        if (list.items.len + n > max) {
            list.deinit(allocator);
            return null;
        }
        list.appendSlice(allocator, buf[0..n]) catch {
            list.deinit(allocator);
            return null;
        };
    }
    return list.toOwnedSlice(allocator) catch null;
}

/// Absolute paths, sorted. The caller frees each and the list.
pub fn scan(allocator: std.mem.Allocator) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    for (psf_dirs) |dir| try walk(allocator, dir, 0, false, &out);
    for (ttf_dirs) |dir| try walk(allocator, dir, 0, true, &out);
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(allocator);
}

fn walk(allocator: std.mem.Allocator, dir: [:0]const u8, depth: u32, want_ttf: bool, out: *std.ArrayList([]u8)) !void {
    const d = std.c.opendir(dir.ptr) orelse return;
    defer _ = std.c.closedir(d);
    while (std.c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (name.len == 0 or name[0] == '.') continue;
        var pbuf: [1024:0]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pbuf, "{s}/{s}", .{ dir, name }, 0) catch continue;
        if (ent.type == std.c.DT.DIR) {
            if (want_ttf and depth < 3) try walk(allocator, path, depth + 1, want_ttf, out);
            continue;
        }
        if (want_ttf) {
            if (!std.ascii.endsWithIgnoreCase(name, ".ttf") and !std.ascii.endsWithIgnoreCase(name, ".otf")) continue;
            const data = readFile(allocator, path, 32 << 20) orelse continue;
            defer allocator.free(data);
            if (!ttf.looksLikeTrueType(data) or !ttf.isMonospace(data)) continue;
            // CFF outlines are not read.
            var face = ttf.Face.init(allocator, data, 16) catch continue;
            face.deinit();
        } else if (!std.mem.endsWith(u8, name, ".psf") and !std.mem.endsWith(u8, name, ".psfu")) continue;
        try out.append(allocator, try allocator.dupe(u8, path));
    }
}

test "scan does not fail on missing directories" {
    const list = try scan(std.testing.allocator);
    for (list) |p| std.testing.allocator.free(p);
    std.testing.allocator.free(list);
}
