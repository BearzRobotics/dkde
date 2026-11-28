// SPDX-License-Identifier: GPL-2.0-or-later
//! Archives through libarchive: unpacking and packing, run by a helper process
//! (`dkde-files --archive-extract` / `--archive-pack`) so a damaged archive
//! can never take the file manager down. libarchive's C interface is declared
//! by hand below (only what is used), and the library is linked by the build.
//!
//! Unpacking refuses what libarchive's secure flags refuse: names with `..`,
//! absolute names and symlinks that lead out of the destination. It also stops
//! at a size and an entry limit, against archives made to fill the disk.

const std = @import("std");
const gio = @import("gio2");
const gobject = @import("gobject2");
const ops = @import("ops.zig");

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

/// Unpacks `archive_path` into `dest` (created). It is built in a new folder of
/// its own beside `dest` and then renamed, so a failed unpack leaves nothing
/// behind, and nothing that was already there is touched.
pub fn extractAll(gpa: std.mem.Allocator, archive_arg: []const u8, dest_arg: []const u8) !void {
    // The unpack runs inside the destination, so every path must be absolute first.
    const archive_path = try absolute(gpa, archive_arg);
    defer gpa.free(archive_path);
    const dest = try absolute(gpa, dest_arg);
    defer gpa.free(dest);
    const src_z = try gpa.dupeSentinel(u8, archive_path, 0);
    defer gpa.free(src_z);
    const dest_z = try gpa.dupeSentinel(u8, dest, 0);
    defer gpa.free(dest_z);
    const part = try std.fmt.allocPrintSentinel(gpa, "{s}/.dkde-unpack-XXXXXX", .{std.fs.path.dirname(dest) orelse "/"}, 0);
    defer gpa.free(part);
    if (mkdtemp(part.ptr) == null) return error.WriteFailed;
    errdefer removeWork(part);
    // mkdtemp makes it private; give it what a new folder would have.
    if (std.c.chmod(part, 0o755 & ~currentUmask()) != 0) return error.WriteFailed;
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
    try publish(part, dest_z);
}

extern fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern fn mkstemp(template: [*:0]u8) c_int;
extern fn umask(mask: c_uint) c_uint;

fn currentUmask() c_uint {
    const mask = umask(0o022);
    _ = umask(mask);
    return mask;
}

/// Gives `from` the name `to`, which must still be free.
fn publish(from: [*:0]const u8, to: [*:0]const u8) !void {
    const linux = std.os.linux;
    const at = std.c.AT.FDCWD;
    switch (linux.errno(linux.renameat2(at, from, at, to, .{ .NOREPLACE = true }))) {
        .SUCCESS => return,
        // A filesystem without the flag: look first.
        .INVAL, .NOSYS, .OPNOTSUPP => {
            if (std.c.access(to, 0) == 0) return error.WriteFailed;
            if (std.c.rename(from, to) != 0) return error.WriteFailed;
        },
        else => return error.WriteFailed,
    }
}

/// Removes the work folder this process made. Links in it are removed, never
/// followed.
fn removeWork(path: [*:0]const u8) void {
    _ = std.c.chdir("/");
    const folder = gio.File.newForPath(path);
    defer folder.as(gobject.Object).unref();
    ops.deleteTree(folder);
}

fn absolute(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '/') return gpa.dupe(u8, path);
    var buf: [4096]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return error.OpenFailed;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd)), 0), path });
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

/// Packs `names` (relative to `dir`) into `out`, which must not exist. It is
/// written to a new file of its own beside `out` and then renamed.
pub fn packAll(gpa: std.mem.Allocator, format: Format, out_arg: []const u8, dir_arg: []const u8, names: []const []const u8) !void {
    const out = try absolute(gpa, out_arg);
    defer gpa.free(out);
    const dir = try absolute(gpa, dir_arg);
    defer gpa.free(dir);
    const dir_z = try gpa.dupeSentinel(u8, dir, 0);
    defer gpa.free(dir_z);
    if (std.c.chdir(dir_z) != 0) return error.OpenFailed;
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
    const part = try std.fmt.allocPrintSentinel(gpa, "{s}/.dkde-pack-XXXXXX", .{std.fs.path.dirname(out) orelse "/"}, 0);
    defer gpa.free(part);
    const part_fd = mkstemp(part.ptr);
    if (part_fd < 0) return error.WriteFailed;
    errdefer _ = std.c.unlink(part);
    if (std.c.fchmod(part_fd, 0o666 & ~currentUmask()) != 0 or std.c.close(part_fd) != 0) return error.WriteFailed;
    // Which file that is, so the archive is never packed into itself, whatever
    // folder the items come from and whatever they are called.
    const own = fileIdentity(part) orelse return error.WriteFailed;
    if (archive_write_open_filename(w, part) != ok) return error.WriteFailed;

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
            if (fileIdentity(path)) |id| if (id.eql(own)) {
                _ = archive_entry_clear(entry);
                continue;
            };
            if (archive_write_header(w, entry) < warn) return error.WriteFailed;
            if ((archive_entry_filetype(entry) & ae_ifmt) == ae_ifreg and archive_entry_size(entry) > 0) {
                // A sparse file's holes are not handed over: each block says
                // where it belongs, and an archive needs the zeros between.
                var at: u64 = 0;
                while (true) {
                    var buf: ?*const anyopaque = null;
                    var len: usize = 0;
                    var offset: i64 = 0;
                    const rr = archive_read_data_block(disk, &buf, &len, &offset);
                    if (rr == eof) break;
                    if (rr < warn) return error.Damaged;
                    // Less than was already written means the file changed under us.
                    if (offset < 0 or @as(u64, @intCast(offset)) < at) return error.Damaged;
                    try writeZeros(w, @as(u64, @intCast(offset)) - at);
                    try writeAll(w, @as([*]const u8, @ptrCast(buf orelse continue))[0..len]);
                    at = @as(u64, @intCast(offset)) + len;
                }
                // And the hole at the end, if there is one.
                const size: u64 = @intCast(archive_entry_size(entry));
                if (at < size) try writeZeros(w, size - at);
            }
            if (archive_write_finish_entry(w) < warn) return error.WriteFailed;
            // Fresh entry for the next header.
            _ = archive_entry_clear(entry);
        }
    }
    if (archive_write_close(w) != ok) return error.WriteFailed;
    try publish(part, out_z);
}

fn writeAll(w: *Archive, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = archive_write_data(w, rest.ptr, rest.len);
        // Taking nothing means the entry is full: the file grew meanwhile.
        if (n <= 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
}

const zeros: [64 * 1024]u8 = @splat(0);

fn writeZeros(w: *Archive, count: u64) !void {
    var left = count;
    while (left > 0) {
        const n: usize = @intCast(@min(left, zeros.len));
        try writeAll(w, zeros[0..n]);
        left -= n;
    }
}

const Identity = struct {
    device: u64,
    inode: u64,

    fn eql(a: Identity, b: Identity) bool {
        return a.device == b.device and a.inode == b.inode;
    }
};

fn fileIdentity(path: [*:0]const u8) ?Identity {
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(std.c.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .INO = true }, &st)) != .SUCCESS) return null;
    return .{ .device = (@as(u64, st.dev_major) << 32) | st.dev_minor, .inode = st.ino };
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

test "sparse files come out of every format byte for byte" {
    const root = glib.Dir.makeTmp("dkde-arc-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const src = try std.fmt.allocPrintSentinel(alloc, "{s}/src", .{base}, 0);
    defer alloc.free(src);
    _ = glib.mkdirWithParents(src, 0o755);

    // Holes in the middle and at the end, as in a disk image.
    const size = 8 << 20;
    const path = try std.fmt.allocPrint(alloc, "{s}/disk.img", .{src});
    defer alloc.free(path);
    {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "start", 0);
        try file.writePositionalAll(io, "middle", 4 << 20);
        try file.setLength(io, size);
    }
    const want = try alloc.alloc(u8, size);
    defer alloc.free(want);
    @memset(want, 0);
    @memcpy(want[0..5], "start");
    @memcpy(want[4 << 20 ..][0..6], "middle");

    for ([_]Format{ .zip, .tar_gz, .tar_xz, .tar_zst, .sevenz }) |format| {
        const out = try std.fmt.allocPrint(alloc, "{s}/s{s}", .{ base, extension(format) });
        defer alloc.free(out);
        const dest = try std.fmt.allocPrint(alloc, "{s}/y-{s}", .{ base, @tagName(format) });
        defer alloc.free(dest);
        try packAll(alloc, format, out, src, &.{"disk.img"});
        try extractAll(alloc, out, dest);
        const got = try readTestFile(dest, "disk.img");
        defer alloc.free(got);
        try std.testing.expectEqual(want.len, got.len);
        try std.testing.expect(std.mem.eql(u8, want, got));
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
    // Neither the destination nor a work folder is left: only the file itself.
    try std.testing.expectEqual(@as(usize, 1), try countIn(base));
}

fn countIn(dir: []const u8) !usize {
    const z = try std.testing.allocator.dupeSentinel(u8, dir, 0);
    defer std.testing.allocator.free(z);
    const d = glib.Dir.open(z, 0, null) orelse return error.OpenFailed;
    defer d.close();
    var n: usize = 0;
    while (@as(?[*:0]const u8, d.readName()) != null) n += 1;
    return n;
}

test "files that happen to be named like work files are left alone" {
    const root = glib.Dir.makeTmp("dkde-arc-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);
    const alloc = std.testing.allocator;
    const src = try std.fmt.allocPrintSentinel(alloc, "{s}/bob's", .{base}, 0);
    defer alloc.free(src);
    const theirs = try std.fmt.allocPrintSentinel(alloc, "{s}/project.part", .{base}, 0);
    defer alloc.free(theirs);
    _ = glib.mkdirWithParents(src, 0o755);
    _ = glib.mkdirWithParents(theirs, 0o755);
    try writeTestFile(src, "a.txt", "alpha");
    try writeTestFile(theirs, "notes.txt", "mine");
    try writeTestFile(base, "docs.zip.part", "an unfinished download");

    const zip = try std.fmt.allocPrint(alloc, "{s}/docs.zip", .{base});
    defer alloc.free(zip);
    try packAll(alloc, .zip, zip, src, &.{"a.txt"});
    const dest = try std.fmt.allocPrint(alloc, "{s}/project", .{base});
    defer alloc.free(dest);
    try extractAll(alloc, zip, dest);

    const kept = try readTestFile(base, "docs.zip.part");
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("an unfinished download", kept);
    const mine = try readTestFile(theirs, "notes.txt");
    defer alloc.free(mine);
    try std.testing.expectEqualStrings("mine", mine);
    // A destination that appeared meanwhile is not replaced.
    try std.testing.expectError(error.WriteFailed, extractAll(alloc, zip, dest));
    try std.testing.expectError(error.WriteFailed, packAll(alloc, .zip, zip, src, &.{"a.txt"}));
    // bob's, project.part, docs.zip.part, docs.zip, project
    try std.testing.expectEqual(@as(usize, 5), try countIn(base));
}

test "an item named like the archive is packed, and the archive never is" {
    const root = glib.Dir.makeTmp("dkde-arc-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(root);
    const base = std.mem.span(root);
    const alloc = std.testing.allocator;
    const src = try std.fmt.allocPrintSentinel(alloc, "{s}/sub", .{base}, 0);
    defer alloc.free(src);
    _ = glib.mkdirWithParents(src, 0o755);
    try writeTestFile(src, "Archive.zip", "not really a zip");
    try writeTestFile(src, "notes.txt", "notes");

    // Written beside the folder the items are in, as search results are.
    const out = try std.fmt.allocPrint(alloc, "{s}/Archive.zip", .{base});
    defer alloc.free(out);
    try packAll(alloc, .zip, out, src, &.{ "Archive.zip", "notes.txt" });
    const first = try std.fmt.allocPrint(alloc, "{s}/first", .{base});
    defer alloc.free(first);
    try extractAll(alloc, out, first);
    try std.testing.expectEqual(@as(usize, 2), try countIn(first));

    // Packing the folder the archive is written into leaves the archive out.
    const whole = try std.fmt.allocPrint(alloc, "{s}/all.tar.gz", .{src});
    defer alloc.free(whole);
    try packAll(alloc, .tar_gz, whole, base, &.{"sub"});
    const second = try std.fmt.allocPrint(alloc, "{s}/second", .{base});
    defer alloc.free(second);
    try extractAll(alloc, whole, second);
    const inside = try std.fmt.allocPrint(alloc, "{s}/sub", .{second});
    defer alloc.free(inside);
    try std.testing.expectEqual(@as(usize, 2), try countIn(inside));
}
