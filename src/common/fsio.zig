//! File access through `std.Io`, so the programs do not need GLib to read or
//! write a file. DKDE programs are single-threaded at this level (GTK's main
//! loop does the waiting), so the global single-threaded `Io` is the right one.

const std = @import("std");

pub const Io = std.Io;

pub fn io() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// True when `path` exists (any kind of file, following symlinks).
pub fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}

/// Opens `path` for reading; the caller closes it. A missing file gives null.
pub fn openRead(path: []const u8) !?std.Io.File {
    return std.Io.Dir.cwd().openFile(io(), path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
}

/// Reads all of `path` into memory (caller frees). A missing file gives null;
/// a file over `limit` bytes gives `error.StreamTooLong`.
pub fn readFile(gpa: std.mem.Allocator, path: []const u8, limit: usize) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), path, gpa, .limited(limit)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
}

/// Replaces `path` with `data` in one step: a temporary file is written and
/// renamed over the target, so a reader sees the old or the new content, never
/// half of it.
pub fn writeFileAtomic(path: []const u8, data: []const u8) !void {
    const i = io();
    // A file that is replaced keeps its permissions (an executable script
    // stays executable, a private file stays private): the new copy would
    // otherwise get the defaults.
    const old: ?std.Io.File.Permissions = if (std.Io.Dir.cwd().statFile(i, path, .{})) |st| st.permissions else |_| null;
    var atomic = try std.Io.Dir.cwd().createFileAtomic(i, path, .{ .replace = true, .permissions = old orelse .default_file });
    defer atomic.deinit(i);
    try atomic.file.writeStreamingAll(i, data);
    // Set again: the umask may have taken bits off at creation.
    if (old) |p| atomic.file.setPermissions(i, p) catch {};
    try atomic.replace(i);
}

/// Creates `path` and any missing parents.
pub fn makePath(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io(), path);
}

test "write, read and replace" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io(), ".", gpa);
    defer gpa.free(dir);
    const sub = try std.fmt.allocPrint(gpa, "{s}/a/b", .{dir});
    defer gpa.free(sub);
    try makePath(sub);
    const file = try std.fmt.allocPrint(gpa, "{s}/f.txt", .{sub});
    defer gpa.free(file);
    try std.testing.expect((try readFile(gpa, file, 100)) == null);
    try writeFileAtomic(file, "one");
    try writeFileAtomic(file, "two");
    const got = (try readFile(gpa, file, 100)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("two", got);

    // Replacing keeps the file's permissions.
    const f = try std.Io.Dir.cwd().openFile(io(), file, .{});
    try f.setPermissions(io(), .fromMode(0o750));
    f.close(io());
    try writeFileAtomic(file, "three");
    const st = try std.Io.Dir.cwd().statFile(io(), file, .{});
    try std.testing.expectEqual(@as(u32, 0o750), st.permissions.toMode() & 0o777);
    try std.testing.expect(exists(file));
}
