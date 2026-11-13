//! Archives through libarchive: unpacking and packing, run by a helper process
//! (`dkde-files --archive-extract` / `--archive-pack`) so a damaged archive
//! can never take the file manager down. libarchive's C interface is declared
//! by hand below (only what is used), and the library is linked by the build.
//!
//! Unpacking refuses what libarchive's secure flags refuse: names with `..`,
//! absolute names and symlinks that lead out of the destination. It also stops
//! at a size and an entry limit, against archives made to fill the disk.

const std = @import("std");

const Archive = opaque {};
const Entry = opaque {};

const ok = 0;
const eof = 1;
const warn = -20;

extern fn archive_read_new() ?*Archive;
extern fn archive_read_support_filter_all(*Archive) c_int;
extern fn archive_read_support_format_all(*Archive) c_int;
extern fn archive_read_open_filename(*Archive, [*:0]const u8, usize) c_int;
extern fn archive_read_next_header(*Archive, *?*Entry) c_int;
extern fn archive_read_next_header2(*Archive, *Entry) c_int;
extern fn archive_read_data_block(*Archive, *?*const anyopaque, *usize, *i64) c_int;
extern fn archive_read_free(*Archive) c_int;
extern fn archive_error_string(*Archive) ?[*:0]const u8;
extern fn archive_entry_pathname(*Entry) ?[*:0]const u8;
extern fn archive_entry_size(*Entry) i64;
extern fn archive_entry_filetype(*Entry) c_uint;
extern fn archive_entry_is_encrypted(*Entry) c_int;
extern fn archive_entry_new() ?*Entry;
extern fn archive_entry_free(*Entry) void;
extern fn archive_write_disk_new() ?*Archive;
extern fn archive_write_disk_set_options(*Archive, c_int) c_int;
extern fn archive_write_disk_set_standard_lookup(*Archive) c_int;
extern fn archive_write_header(*Archive, *Entry) c_int;
extern fn archive_write_data(*Archive, ?*const anyopaque, usize) isize;
extern fn archive_write_data_block(*Archive, ?*const anyopaque, usize, i64) isize;
extern fn archive_write_finish_entry(*Archive) c_int;
extern fn archive_write_close(*Archive) c_int;
extern fn archive_write_free(*Archive) c_int;
extern fn archive_write_new() ?*Archive;
extern fn archive_write_set_format_zip(*Archive) c_int;
extern fn archive_write_set_format_pax_restricted(*Archive) c_int;
extern fn archive_write_set_format_7zip(*Archive) c_int;
extern fn archive_write_add_filter_gzip(*Archive) c_int;
extern fn archive_write_add_filter_xz(*Archive) c_int;
extern fn archive_write_add_filter_zstd(*Archive) c_int;
extern fn archive_write_open_filename(*Archive, [*:0]const u8) c_int;
extern fn archive_read_disk_new() ?*Archive;
extern fn archive_read_disk_set_standard_lookup(*Archive) c_int;
extern fn archive_read_disk_open(*Archive, [*:0]const u8) c_int;
extern fn archive_read_disk_descend(*Archive) c_int;
extern fn archive_version_string() [*:0]const u8;

// archive.h: ARCHIVE_EXTRACT_PERM, _TIME, _SECURE_SYMLINKS, _SECURE_NODOTDOT, _SECURE_NOABSOLUTEPATHS.
const extract_flags: c_int = 0x0002 | 0x0004 | 0x0100 | 0x0200 | 0x10000;
const ae_ifmt = 0o170000;
const ae_ifreg = 0o100000;

pub const max_bytes: u64 = 16 * 1024 * 1024 * 1024;
pub const max_entries: u64 = 1_000_000;

pub const Error = error{
    OpenFailed,
    Damaged,
    PasswordNeeded,
    TooBig,
    WriteFailed,
    Unsupported,
    OutOfMemory,
};

/// Words for a person, for each failure.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.OpenFailed => "The archive could not be opened (missing, unreadable or not an archive).",
        error.Damaged => "The archive is damaged or uses an unsupported method.",
        error.PasswordNeeded => "The archive is password protected; encrypted archives cannot be opened yet.",
        error.TooBig => "The archive would unpack to more than 16 GB or a million files; it was not unpacked.",
        error.WriteFailed => "The files could not be written (is the disk full or the folder read-only?).",
        error.Unsupported => "That archive type is not supported.",
        else => "The archive operation failed.",
    };
}

fn passwordMessage(a: *Archive) bool {
    const text = archive_error_string(a) orelse return false;
    const s = std.mem.span(text);
    return std.ascii.findIgnoreCase(s, "passphrase") != null or std.ascii.findIgnoreCase(s, "encrypted") != null or std.ascii.findIgnoreCase(s, "password") != null;
}

/// Unpacks `archive_path` into `dest` (created). The destination is built as
/// `dest.part` and renamed, so a failed unpack leaves nothing behind.
pub fn extractAll(gpa: std.mem.Allocator, archive_arg: []const u8, dest_arg: []const u8) !void {
    // The unpack runs inside the destination, so every path must be absolute first.
    const archive_path = try absolute(gpa, archive_arg);
    defer gpa.free(archive_path);
    const dest = try absolute(gpa, dest_arg);
    defer gpa.free(dest);
    const src_z = try gpa.dupeSentinel(u8, archive_path, 0);
    defer gpa.free(src_z);
    const part = try std.fmt.allocPrintSentinel(gpa, "{s}.part", .{dest}, 0);
    defer gpa.free(part);
    const dest_z = try gpa.dupeSentinel(u8, dest, 0);
    defer gpa.free(dest_z);

    removeTree(part);
    if (std.c.mkdir(part, 0o755) != 0 and std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return error.WriteFailed;
    errdefer removeTree(part);
    if (std.c.chdir(part) != 0) return error.WriteFailed;

    const reader = archive_read_new() orelse return error.OutOfMemory;
    defer _ = archive_read_free(reader);
    _ = archive_read_support_filter_all(reader);
    _ = archive_read_support_format_all(reader);
    if (archive_read_open_filename(reader, src_z, 64 * 1024) != ok) return error.OpenFailed;

    const writer = archive_write_disk_new() orelse return error.OutOfMemory;
    defer _ = archive_write_free(writer);
    _ = archive_write_disk_set_options(writer, extract_flags);
    _ = archive_write_disk_set_standard_lookup(writer);

    var total: u64 = 0;
    var count: u64 = 0;
    while (true) {
        var entry: ?*Entry = null;
        const r = archive_read_next_header(reader, &entry);
        if (r == eof) break;
        if (r < warn) return if (passwordMessage(reader)) error.PasswordNeeded else error.Damaged;
        const e = entry orelse break;
        count += 1;
        if (count > max_entries) return error.TooBig;
        if (archive_entry_is_encrypted(e) != 0) return error.PasswordNeeded;
        const size = archive_entry_size(e);
        if (size > 0) total +|= @intCast(size);
        if (total > max_bytes) return error.TooBig;

        if (archive_write_header(writer, e) < warn) {
            // A name the secure flags refuse is skipped, not fatal.
            continue;
        }
        if ((archive_entry_filetype(e) & ae_ifmt) == ae_ifreg) {
            while (true) {
                var buf: ?*const anyopaque = null;
                var len: usize = 0;
                var offset: i64 = 0;
                const rr = archive_read_data_block(reader, &buf, &len, &offset);
                if (rr == eof) break;
                if (rr < warn) return if (passwordMessage(reader)) error.PasswordNeeded else error.Damaged;
                if (archive_write_data_block(writer, buf, len, offset) < 0) return error.WriteFailed;
            }
        }
        _ = archive_write_finish_entry(writer);
    }
    _ = archive_write_close(writer);

    if (std.c.chdir("/") != 0) {}
    if (std.c.rename(part, dest_z) != 0) return error.WriteFailed;
}

fn absolute(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '/') return gpa.dupe(u8, path);
    var buf: [4096]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return error.OpenFailed;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd)), 0), path });
}

extern "c" fn system(command: [*:0]const u8) c_int;
const c_system = system;

fn removeTree(path: [*:0]const u8) void {
    // Only ever called on our own ".part" folder.
    var buf: [4200]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&buf, "rm -rf -- '{s}'", .{std.mem.span(path)}, 0) catch return;
    if (std.mem.indexOfScalar(u8, std.mem.span(path), '\'') != null) return;
    _ = c_system(cmd);
}

pub const Format = enum { zip, tar_gz, tar_xz, tar_zst, sevenz };

pub fn formatOf(name: []const u8) ?Format {
    const map = [_]struct { []const u8, Format }{
        .{ "zip", .zip }, .{ "tar.gz", .tar_gz }, .{ "tar.xz", .tar_xz }, .{ "tar.zst", .tar_zst }, .{ "7z", .sevenz },
    };
    for (map) |m| if (std.mem.eql(u8, name, m[0])) return m[1];
    return null;
}

pub fn extension(f: Format) []const u8 {
    return switch (f) {
        .zip => ".zip",
        .tar_gz => ".tar.gz",
        .tar_xz => ".tar.xz",
        .tar_zst => ".tar.zst",
        .sevenz => ".7z",
    };
}

/// Packs `names` (relative to `dir`) into `out`, written as `out.part` and renamed.
pub fn packAll(gpa: std.mem.Allocator, format: Format, out_arg: []const u8, dir_arg: []const u8, names: []const []const u8) !void {
    const out = try absolute(gpa, out_arg);
    defer gpa.free(out);
    const dir = try absolute(gpa, dir_arg);
    defer gpa.free(dir);
    const dir_z = try gpa.dupeSentinel(u8, dir, 0);
    defer gpa.free(dir_z);
    if (std.c.chdir(dir_z) != 0) return error.OpenFailed;
    const part = try std.fmt.allocPrintSentinel(gpa, "{s}.part", .{out}, 0);
    defer gpa.free(part);
    const out_z = try gpa.dupeSentinel(u8, out, 0);
    defer gpa.free(out_z);

    const w = archive_write_new() orelse return error.OutOfMemory;
    defer _ = archive_write_free(w);
    const set_ok = switch (format) {
        .zip => archive_write_set_format_zip(w),
        .sevenz => archive_write_set_format_7zip(w),
        else => archive_write_set_format_pax_restricted(w),
    };
    if (set_ok != ok) return error.Unsupported;
    const filter_ok = switch (format) {
        .tar_gz => archive_write_add_filter_gzip(w),
        .tar_xz => archive_write_add_filter_xz(w),
        .tar_zst => archive_write_add_filter_zstd(w),
        else => ok,
    };
    if (filter_ok != ok) return error.Unsupported;
    if (archive_write_open_filename(w, part) != ok) return error.WriteFailed;
    errdefer _ = std.c.unlink(part);

    for (names) |name| {
        const name_z = try gpa.dupeSentinel(u8, name, 0);
        defer gpa.free(name_z);
        const disk = archive_read_disk_new() orelse return error.OutOfMemory;
        defer _ = archive_read_free(disk);
        _ = archive_read_disk_set_standard_lookup(disk);
        if (archive_read_disk_open(disk, name_z) != ok) return error.OpenFailed;
        const entry = archive_entry_new() orelse return error.OutOfMemory;
        defer archive_entry_free(entry);
        while (true) {
            const r = archive_read_next_header2(disk, entry);
            if (r == eof) break;
            if (r < warn) return error.Damaged;
            _ = archive_read_disk_descend(disk);
            const path = archive_entry_pathname(entry) orelse continue;
            // Never pack the archive into itself.
            if (std.mem.eql(u8, std.mem.span(path), std.fs.path.basename(out))) continue;
            if (archive_write_header(w, entry) < warn) return error.WriteFailed;
            if ((archive_entry_filetype(entry) & ae_ifmt) == ae_ifreg and archive_entry_size(entry) > 0) {
                while (true) {
                    var buf: ?*const anyopaque = null;
                    var len: usize = 0;
                    var offset: i64 = 0;
                    const rr = archive_read_data_block(disk, &buf, &len, &offset);
                    if (rr == eof) break;
                    if (rr < warn) return error.Damaged;
                    if (archive_write_data(w, buf, len) < 0) return error.WriteFailed;
                }
            }
            _ = archive_write_finish_entry(w);
            // Fresh entry for the next header.
            _ = archive_entry_clear(entry);
        }
    }
    if (archive_write_close(w) != ok) return error.WriteFailed;
    if (std.c.rename(part, out_z) != 0) return error.WriteFailed;
}
extern fn archive_entry_clear(*Entry) ?*Entry;

pub fn version() []const u8 {
    return std.mem.span(archive_version_string());
}

const glib = @import("glib2");

fn writeTestFile(dir: []const u8, name: []const u8, text: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ dir, name }, 0);
    defer std.testing.allocator.free(path);
    if (glib.fileSetContents(path, text.ptr, @intCast(text.len), null) == 0) return error.WriteFailed;
}

fn readTestFile(dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ dir, name }, 0);
    defer std.testing.allocator.free(path);
    var data: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(path, &data, &len, null) == 0) return error.ReadFailed;
    defer glib.free(data);
    return std.testing.allocator.dupe(u8, data[0..len]);
}

test "every format packs and unpacks again, keeping folders and file contents" {
    const root = glib.Dir.makeTmp("dkde-arc-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);
    const src = try std.fmt.allocPrint(std.testing.allocator, "{s}/src", .{base});
    defer std.testing.allocator.free(src);
    const nested = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/src/sub", .{base}, 0);
    defer std.testing.allocator.free(nested);
    _ = glib.mkdirWithParents(nested, 0o755);
    try writeTestFile(src, "a file.txt", "hello");
    try writeTestFile(nested, "b.txt", "deep");

    for ([_]Format{ .zip, .tar_gz, .tar_xz, .tar_zst, .sevenz }) |format| {
        const out = try std.fmt.allocPrint(std.testing.allocator, "{s}/out{s}", .{ base, extension(format) });
        defer std.testing.allocator.free(out);
        const dest = try std.fmt.allocPrint(std.testing.allocator, "{s}/x{s}", .{ base, extension(format) });
        defer std.testing.allocator.free(dest);
        try packAll(std.testing.allocator, format, out, src, &.{ "a file.txt", "sub" });
        try extractAll(std.testing.allocator, out, dest);
        const a = try readTestFile(dest, "a file.txt");
        defer std.testing.allocator.free(a);
        try std.testing.expectEqualStrings("hello", a);
        const sub = try std.fmt.allocPrint(std.testing.allocator, "{s}/sub", .{dest});
        defer std.testing.allocator.free(sub);
        const b = try readTestFile(sub, "b.txt");
        defer std.testing.allocator.free(b);
        try std.testing.expectEqualStrings("deep", b);
    }
}

test "a missing or damaged archive fails and leaves nothing behind" {
    const root = glib.Dir.makeTmp("dkde-arc-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);
    const bad = try std.fmt.allocPrint(std.testing.allocator, "{s}/bad.zip", .{base});
    defer std.testing.allocator.free(bad);
    try writeTestFile(base, "bad.zip", "this is not an archive at all");
    const dest = try std.fmt.allocPrint(std.testing.allocator, "{s}/out", .{base});
    defer std.testing.allocator.free(dest);
    try std.testing.expectError(error.OpenFailed, extractAll(std.testing.allocator, bad, dest));
    const part = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}.part", .{dest}, 0);
    defer std.testing.allocator.free(part);
    try std.testing.expect(glib.fileTest(part, .{ .exists = true }) == 0);
}
