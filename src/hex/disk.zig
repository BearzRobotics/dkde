//! Block devices for dkde-hex's disk mode (SPEC.md 5.6): finding them under
//! `/sys/block`, which of them are mounted, and reading and writing sectors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib2");

pub const Info = struct {
    /// `/dev/sda`, `/dev/nvme0n1p2`.
    path: []u8,
    /// `sda`, `nvme0n1p2`.
    name: []u8,
    model: []u8,
    size_bytes: u64,
    sector_size: u32,
    /// A partition rather than a whole disk.
    is_partition: bool,
    mounted: bool,
    removable: bool,
};

pub fn freeInfos(a: Allocator, infos: []Info) void {
    for (infos) |i| {
        a.free(i.path);
        a.free(i.name);
        a.free(i.model);
    }
    a.free(infos);
}

fn readSmall(a: Allocator, path: []const u8) ?[]u8 {
    const z = a.dupeSentinel(u8, path, 0) catch return null;
    defer a.free(z);
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(z, &contents, &length, null) == 0) return null;
    defer glib.free(contents);
    return a.dupe(u8, std.mem.trim(u8, contents[0..length], " \t\r\n")) catch null;
}

fn readNumberF(a: Allocator, comptime fmt: []const u8, args: anytype) ?u64 {
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, fmt, args) catch return null;
    return readNumber(a, path);
}

fn readSmallF(a: Allocator, comptime fmt: []const u8, args: anytype) ?[]u8 {
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, fmt, args) catch return null;
    return readSmall(a, path);
}

fn readNumber(a: Allocator, path: []const u8) ?u64 {
    const text = readSmall(a, path) orelse return null;
    defer a.free(text);
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// Device nodes that appear in `mounts` (the text of /proc/self/mounts).
pub fn mountedDevices(a: Allocator, mounts: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| a.free(s);
        out.deinit(a);
    }
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const dev = parts.next() orelse continue;
        if (!std.mem.startsWith(u8, dev, "/dev/")) continue;
        try out.append(a, try a.dupe(u8, dev));
    }
    return out.toOwnedSlice(a);
}

/// Whole disks and their partitions. Loop, RAM and empty devices are skipped.
pub fn list(a: Allocator) Allocator.Error![]Info {
    var out: std.ArrayList(Info) = .empty;
    errdefer freeInfos(a, out.items);

    const mounts_text = readSmall(a, "/proc/self/mounts") orelse try a.dupe(u8, "");
    defer a.free(mounts_text);
    const mounted = try mountedDevices(a, mounts_text);
    defer {
        for (mounted) |m| a.free(m);
        a.free(mounted);
    }

    var err: ?*glib.Error = null;
    const dir = glib.Dir.open("/sys/block", 0, &err) orelse {
        if (err) |e| e.free();
        return out.toOwnedSlice(a);
    };
    defer dir.close();
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    while (@as(?[*:0]const u8, @ptrCast(dir.readName()))) |n| {
        const name = std.mem.span(n);
        if (std.mem.startsWith(u8, name, "loop") or std.mem.startsWith(u8, name, "ram") or std.mem.startsWith(u8, name, "zram")) continue;
        try names.append(a, try a.dupe(u8, name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    for (names.items) |disk| {
        const base = try std.fmt.allocPrint(a, "/sys/block/{s}", .{disk});
        defer a.free(base);
        const sectors = readNumberF(a, "{s}/size", .{base}) orelse 0;
        if (sectors == 0) continue;
        const sector_size: u32 = @intCast(readNumberF(a, "{s}/queue/logical_block_size", .{base}) orelse 512);
        const model = readSmallF(a, "{s}/device/model", .{base}) orelse try a.dupe(u8, "");
        errdefer a.free(model);
        const removable = (readNumberF(a, "{s}/removable", .{base}) orelse 0) != 0;
        const path = try std.fmt.allocPrint(a, "/dev/{s}", .{disk});
        errdefer a.free(path);
        var disk_mounted = false;
        for (mounted) |m| if (std.mem.eql(u8, m, path)) {
            disk_mounted = true;
        };
        try out.append(a, .{
            .path = path,
            .name = try a.dupe(u8, disk),
            .model = model,
            // /sys reports 512-byte units whatever the device's sector size.
            .size_bytes = sectors * 512,
            .sector_size = sector_size,
            .is_partition = false,
            .mounted = disk_mounted,
            .removable = removable,
        });

        // Its partitions: subdirectories that have a `partition` file.
        const bz = try a.dupeSentinel(u8, base, 0);
        defer a.free(bz);
        const sub = glib.Dir.open(bz, 0, null) orelse continue;
        defer sub.close();
        var parts: std.ArrayList([]u8) = .empty;
        defer {
            for (parts.items) |p| a.free(p);
            parts.deinit(a);
        }
        while (@as(?[*:0]const u8, @ptrCast(sub.readName()))) |pn| {
            const pname = std.mem.span(pn);
            if (!std.mem.startsWith(u8, pname, disk)) continue;
            const marker = try std.fmt.allocPrint(a, "{s}/{s}/partition", .{ base, pname });
            defer a.free(marker);
            const mz = try a.dupeSentinel(u8, marker, 0);
            defer a.free(mz);
            if (glib.fileTest(mz, .{ .exists = true }) == 0) continue;
            try parts.append(a, try a.dupe(u8, pname));
        }
        std.mem.sort([]u8, parts.items, {}, struct {
            fn less(_: void, x: []u8, y: []u8) bool {
                // sda2 before sda10.
                if (x.len != y.len) return x.len < y.len;
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        for (parts.items) |pname| {
            const psectors = readNumberF(a, "{s}/{s}/size", .{ base, pname }) orelse 0;
            const ppath = try std.fmt.allocPrint(a, "/dev/{s}", .{pname});
            errdefer a.free(ppath);
            var pm = false;
            for (mounted) |m| if (std.mem.eql(u8, m, ppath)) {
                pm = true;
            };
            const pmodel = try a.dupe(u8, "");
            errdefer a.free(pmodel);
            try out.append(a, .{
                .path = ppath,
                .name = try a.dupe(u8, pname),
                .model = pmodel,
                .size_bytes = psectors * 512,
                .sector_size = sector_size,
                .is_partition = true,
                .mounted = pm,
                .removable = removable,
            });
        }
    }
    return out.toOwnedSlice(a);
}

/// Whether `path` or any partition of it is mounted.
pub fn anyMounted(infos: []const Info, path: []const u8) bool {
    for (infos) |i| {
        if (!i.mounted) continue;
        if (std.mem.eql(u8, i.path, path)) return true;
        // A partition of this disk: its path starts with the disk's.
        if (std.mem.startsWith(u8, i.path, path)) return true;
    }
    return false;
}

// -- raw access ---------------------------------------------------------------------------

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn pread(fd: c_int, buf: [*]u8, count: usize, offset: i64) isize;
extern fn pwrite(fd: c_int, buf: [*]const u8, count: usize, offset: i64) isize;
extern fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern fn fsync(fd: c_int) c_int;

const O_RDONLY: c_int = 0;
const O_RDWR: c_int = 2;
const O_CLOEXEC: c_int = 0o2000000;

pub const Handle = struct {
    fd: c_int,
    writable: bool,
    size: u64,

    pub const OpenError = error{ AccessDenied, NotFound, Failed };

    pub fn openPath(path: [:0]const u8, writable: bool) OpenError!Handle {
        const fd = open(path.ptr, (if (writable) O_RDWR else O_RDONLY) | O_CLOEXEC);
        if (fd < 0) {
            return switch (std.c._errno().*) {
                13, 1 => error.AccessDenied, // EACCES, EPERM
                2 => error.NotFound,
                else => error.Failed,
            };
        }
        const end = lseek(fd, 0, 2);
        if (end < 0) {
            _ = close(fd);
            return error.Failed;
        }
        return .{ .fd = fd, .writable = writable, .size = @intCast(end) };
    }

    pub fn closeHandle(self: *Handle) void {
        _ = close(self.fd);
    }

    /// Reads up to `buf.len` bytes at `offset`; returns how many.
    pub fn readAt(self: *const Handle, offset: u64, buf: []u8) !usize {
        var done: usize = 0;
        while (done < buf.len) {
            const n = pread(self.fd, buf.ptr + done, buf.len - done, @intCast(offset + done));
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            done += @intCast(n);
        }
        return done;
    }

    pub fn writeAt(self: *const Handle, offset: u64, data: []const u8) !void {
        var done: usize = 0;
        while (done < data.len) {
            const n = pwrite(self.fd, data.ptr + done, data.len - done, @intCast(offset + done));
            if (n <= 0) return error.WriteFailed;
            done += @intCast(n);
        }
    }

    pub fn flush(self: *const Handle) void {
        _ = fsync(self.fd);
    }
};

/// The sectors (by index in `window`) whose bytes differ between `now` and
/// `original`, for `sector_size`-byte sectors. Caller frees.
pub fn changedSectors(a: Allocator, original: []const u8, now: []const u8, sector_size: usize) Allocator.Error![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(a);
    const n = @min(original.len, now.len);
    var s: usize = 0;
    while (s * sector_size < n) : (s += 1) {
        const lo = s * sector_size;
        const hi = @min(n, lo + sector_size);
        if (!std.mem.eql(u8, original[lo..hi], now[lo..hi])) try out.append(a, s);
    }
    return out.toOwnedSlice(a);
}

test "mounted device nodes are read from /proc/self/mounts" {
    const a = std.testing.allocator;
    const text = "proc /proc proc rw 0 0\n/dev/sda1 / ext4 rw 0 0\n/dev/nvme0n1p2 /home ext4 rw 0 0\ntmpfs /tmp tmpfs rw 0 0\n";
    const m = try mountedDevices(a, text);
    defer {
        for (m) |x| a.free(x);
        a.free(m);
    }
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqualStrings("/dev/nvme0n1p2", m[1]);
}

test "changed sectors" {
    const a = std.testing.allocator;
    var orig: [2048]u8 = @splat(0);
    var now = orig;
    now[5] = 1; // sector 0
    now[1030] = 9; // sector 2
    const s = try changedSectors(a, &orig, &now, 512);
    defer a.free(s);
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqual(@as(usize, 2), s[1]);
}

test "any mounted partition makes the disk mounted" {
    var infos = [_]Info{
        .{ .path = @constCast("/dev/sda"), .name = @constCast("sda"), .model = @constCast(""), .size_bytes = 1, .sector_size = 512, .is_partition = false, .mounted = false, .removable = false },
        .{ .path = @constCast("/dev/sda1"), .name = @constCast("sda1"), .model = @constCast(""), .size_bytes = 1, .sector_size = 512, .is_partition = true, .mounted = true, .removable = false },
    };
    try std.testing.expect(anyMounted(&infos, "/dev/sda"));
    try std.testing.expect(!anyMounted(&infos, "/dev/sdb"));
}

test "reading and writing sectors of an image file" {
    const a = std.testing.allocator;
    const dir = glib.Dir.makeTmp("dkde-disk-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/disk.img", .{std.mem.span(dir)}, 0);
    defer a.free(path);
    var image: [4096]u8 = @splat(0);
    image[510] = 0x55;
    image[511] = 0xAA;
    _ = glib.fileSetContents(path, &image, image.len, null);
    defer _ = std.c.unlink(path);

    var ro = try Handle.openPath(path, false);
    defer ro.closeHandle();
    try std.testing.expectEqual(@as(u64, 4096), ro.size);
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 512), try ro.readAt(0, &buf));
    try std.testing.expectEqual(@as(u8, 0xAA), buf[511]);
    try std.testing.expectError(error.WriteFailed, ro.writeAt(0, "x"));

    var rw = try Handle.openPath(path, true);
    defer rw.closeHandle();
    try rw.writeAt(1024, "HELLO");
    var again: [5]u8 = undefined;
    _ = try ro.readAt(1024, &again);
    try std.testing.expectEqualStrings("HELLO", &again);
}
