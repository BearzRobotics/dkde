// SPDX-License-Identifier: GPL-2.0-or-later
//! Small persistent state (recent apps, window sizes) kept in
//! `$XDG_STATE_HOME/dkde/`, apart from configuration (SPEC.md 6.1).

const std = @import("std");
const glib = @import("glib2");

const paths = @import("paths.zig");
const fsio = @import("fsio.zig");

const log = std.log.scoped(.state);

/// Reads the list at `[group] key` of state file `file`. Missing or unreadable
/// state is an empty list. Free with `Config.freeStringList`-style cleanup.
pub fn loadList(allocator: std.mem.Allocator, file: []const u8, group: [:0]const u8, key: [:0]const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(allocator, &out);

    const path = try paths.userStateFile(allocator, file);
    defer allocator.free(path);

    const keyfile = glib.KeyFile.new();
    defer keyfile.free();
    if (keyfile.loadFromFile(path, .{}, null) == 0) return out;

    var len: usize = 0;
    const list = keyfile.getStringList(group, key, &len, null) orelse return out;
    defer glib.strfreev(list);
    for (list[0..len]) |item| try out.append(allocator, try allocator.dupe(u8, std.mem.span(item.?)));
    return out;
}

pub fn saveList(allocator: std.mem.Allocator, file: []const u8, group: [:0]const u8, key: [:0]const u8, items: []const []u8) !void {
    const path = try paths.userStateFile(allocator, file);
    defer allocator.free(path);

    const dir = glib.pathGetDirname(path);
    defer glib.free(dir);
    _ = glib.mkdirWithParents(dir, 0o755);

    const z = try allocator.alloc(?[*:0]const u8, items.len + 1);
    defer allocator.free(z);
    var owned: usize = 0;
    defer for (z[0..owned]) |p| allocator.free(std.mem.span(p.?));
    for (items, 0..) |item, i| {
        z[i] = (try allocator.dupeSentinel(u8, item, 0)).ptr;
        owned += 1;
    }
    z[items.len] = null;

    const keyfile = glib.KeyFile.new();
    defer keyfile.free();
    keyfile.setStringList(group, key, @ptrCast(z.ptr), items.len);
    // Not saveToFile: GLib flushes the file to the disk (fsync) before it renames it, and on a slow
    // or busy disk that stalls the program for seconds, once for each of the several saves a window makes
    // as it opens. This is only what the window remembers; a power cut costing the last change is fine.
    var length: usize = 0;
    const data = keyfile.toData(&length, null) orelse return;
    defer glib.free(data);
    fsio.writeFileAtomic(path, data[0..length]) catch |e| log.warn("cannot save {s}: {s}", .{ path, @errorName(e) });
}

pub fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}
