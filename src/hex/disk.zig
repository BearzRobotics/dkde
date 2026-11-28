// SPDX-License-Identifier: GPL-2.0-or-later
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

/// Whether two device paths are the same disk or one is a partition of the
/// other (`/dev/sda` and `/dev/sda1`, `/dev/nvme0n1` and `/dev/nvme0n1p2`),
/// but not `/dev/sda1` and `/dev/sda10`, which are unrelated partitions.
pub fn sameDisk(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const short = if (a.len <= b.len) a else b;
    const long = if (a.len <= b.len) b else a;
    if (!std.mem.startsWith(u8, long, short)) return false;
    var rest = long[short.len..];
    // Partition suffix: digits, after a `p` when the disk name itself ends in a digit.
    if (rest.len > 0 and rest[0] == 'p' and short.len > 0 and std.ascii.isDigit(short[short.len - 1])) rest = rest[1..];
    if (rest.len == 0) return false;
    // `sda` vs `sda1`: the short name must be a whole disk, so it must not end in a digit unless `p` was used.
    const used_p = rest.len + 1 == long.len - short.len;
    if (!used_p and short.len > 0 and std.ascii.isDigit(short[short.len - 1])) return false;
    for (rest) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "disks and their partitions are told from unrelated devices" {
    try std.testing.expect(sameDisk("/dev/sda", "/dev/sda"));
    try std.testing.expect(sameDisk("/dev/sda", "/dev/sda1"));
    try std.testing.expect(sameDisk("/dev/sda12", "/dev/sda"));
    try std.testing.expect(sameDisk("/dev/nvme0n1", "/dev/nvme0n1p2"));
    try std.testing.expect(!sameDisk("/dev/sda1", "/dev/sda10"));
    try std.testing.expect(!sameDisk("/dev/sda", "/dev/sdb"));
    try std.testing.expect(!sameDisk("/dev/sda", "/dev/sdaa"));
    try std.testing.expect(!sameDisk("/dev/nvme0n1", "/dev/nvme0n10"));
    try std.testing.expect(!sameDisk("/dev/sda1", "/dev/sda2"));
}

// -- which storage is which ---------------------------------------------------------------

// A device has many names (`/dev/sda2`, `/dev/disk/by-id/...`, a mapper node),
// and what is mounted is often something built on it (encryption, LVM, RAID).
// So storage is compared by the kernel's own tree under `sys`.

const linux = std.os.linux;
const s_ifmt = 0o170000;
const s_ifblk = 0o060000;
const s_ifreg = 0o100000;

const DevNo = struct { major: u32, minor: u32 };

const Stat = struct {
    kind: u32,
    /// The filesystem the file is on, and its number there.
    on: DevNo,
    ino: u64,
    /// For a device node: the device it stands for.
    device: DevNo,
};

fn statAt(fd: c_int, path: [*:0]const u8, flags: u32) ?Stat {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, path, flags, .{ .TYPE = true, .INO = true }, &st)) != .SUCCESS) return null;
    return .{
        .kind = st.mode & s_ifmt,
        .on = .{ .major = st.dev_major, .minor = st.dev_minor },
        .ino = st.ino,
        .device = .{ .major = st.rdev_major, .minor = st.rdev_minor },
    };
}

fn statFd(fd: c_int) ?Stat {
    return statAt(fd, "", linux.AT.EMPTY_PATH);
}

fn statPath(path: [*:0]const u8) ?Stat {
    return statAt(std.c.AT.FDCWD, path, 0);
}

extern fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;
extern fn free(ptr: ?*anyopaque) void;

fn canonical(a: Allocator, path: []const u8) ?[]const u8 {
    const z = a.dupeSentinel(u8, path, 0) catch return null;
    const real = realpath(z.ptr, null) orelse return null;
    defer free(@ptrCast(real));
    return a.dupe(u8, std.mem.span(real)) catch null;
}

fn exists(a: Allocator, path: []const u8) bool {
    const z = a.dupeSentinel(u8, path, 0) catch return false;
    return glib.fileTest(z.ptr, .{ .exists = true }) != 0;
}

fn namesIn(a: Allocator, path: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const z = a.dupeSentinel(u8, path, 0) catch return &.{};
    const dir = glib.Dir.open(z.ptr, 0, null) orelse return &.{};
    defer dir.close();
    while (@as(?[*:0]const u8, @ptrCast(dir.readName()))) |n| {
        out.append(a, a.dupe(u8, std.mem.span(n)) catch break) catch break;
    }
    return out.items;
}

/// The plain disks and partitions that the device in sysfs folder `node` is
/// stored on: itself, or what it is built from, however deep.
fn storageOf(a: Allocator, node: []const u8, out: *std.ArrayList([]const u8), depth: usize) Allocator.Error!void {
    if (depth > 8) return;
    var from = node;
    // A partition of an array is built from what the array is built from.
    if (exists(a, try std.fmt.allocPrint(a, "{s}/partition", .{node}))) {
        const parent = std.fs.path.dirname(node) orelse node;
        if (namesIn(a, try std.fmt.allocPrint(a, "{s}/slaves", .{parent})).len > 0) from = parent;
    }
    const below = namesIn(a, try std.fmt.allocPrint(a, "{s}/slaves", .{from}));
    if (below.len == 0) return out.append(a, node);
    for (below) |name| {
        const next = canonical(a, try std.fmt.allocPrint(a, "{s}/slaves/{s}", .{ from, name })) orelse continue;
        try storageOf(a, next, out, depth + 1);
    }
}

/// The storage behind device number `dev`, using the sysfs mounted at `sys`.
fn storageOfNumber(a: Allocator, sys: []const u8, dev: DevNo) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const link = try std.fmt.allocPrint(a, "{s}/dev/block/{d}:{d}", .{ sys, dev.major, dev.minor });
    if (canonical(a, link)) |node| try storageOf(a, node, &out, 0);
    return out.items;
}

/// Whether two sets of storage share bytes: the same node, or a whole disk and
/// one of its partitions. Two partitions of one disk do not.
fn shares(x: []const []const u8, y: []const []const u8) bool {
    for (x) |p| for (y) |q| {
        const short = if (p.len <= q.len) p else q;
        const long = if (p.len <= q.len) q else p;
        if (std.mem.startsWith(u8, long, short) and (long.len == short.len or long[short.len] == '/')) return true;
    };
    return false;
}

/// The device a path leads to: the device itself, or the one holding the file.
fn deviceBehind(path: [*:0]const u8) ?DevNo {
    const st = statPath(path) orelse return null;
    return if (st.kind == s_ifblk) st.device else st.on;
}

/// Whether the two device nodes overlap, whatever they are called.
pub fn sameStorage(gpa: Allocator, a_path: [:0]const u8, b_path: [:0]const u8) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const x = statPath(a_path.ptr) orelse return false;
    const y = statPath(b_path.ptr) orelse return false;
    if (x.kind != s_ifblk or y.kind != s_ifblk) return false;
    const left = storageOfNumber(a, "/sys", x.device) catch return true;
    const right = storageOfNumber(a, "/sys", y.device) catch return true;
    return shares(left, right);
}

/// The devices named by `/proc/self/mountinfo` and `/proc/swaps`: each as a
/// path to look at, or as the number mountinfo gives.
const Used = union(enum) { path: [:0]const u8, number: DevNo };

fn usedDevices(a: Allocator, mountinfo: []const u8, swaps: []const u8) Allocator.Error![]const Used {
    var out: std.ArrayList(Used) = .empty;
    var lines = std.mem.splitScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next();
        _ = fields.next();
        const numbers = fields.next() orelse continue;
        const colon = std.mem.indexOfScalar(u8, numbers, ':') orelse continue;
        const major = std.fmt.parseInt(u32, numbers[0..colon], 10) catch continue;
        const minor = std.fmt.parseInt(u32, numbers[colon + 1 ..], 10) catch continue;
        // Major 0 is a filesystem without one device of its own, such as btrfs.
        if (major != 0) try out.append(a, .{ .number = .{ .major = major, .minor = minor } });
        const dash = std.mem.find(u8, line, " - ") orelse continue;
        var tail = std.mem.tokenizeScalar(u8, line[dash + 3 ..], ' ');
        _ = tail.next();
        const source = tail.next() orelse continue;
        if (std.mem.startsWith(u8, source, "/")) try out.append(a, .{ .path = try a.dupeSentinel(u8, source, 0) });
    }
    var rows = std.mem.splitScalar(u8, swaps, '\n');
    while (rows.next()) |row| {
        var fields = std.mem.tokenizeAny(u8, row, " \t");
        const first = fields.next() orelse continue;
        if (std.mem.startsWith(u8, first, "/")) try out.append(a, .{ .path = try a.dupeSentinel(u8, first, 0) });
    }
    return out.items;
}

/// Whether the block device `path` or anything on it is in use: mounted, in use
/// as swap, or part of encryption, LVM, RAID or btrfs. This is for warnings and
/// early refusals; opening it exclusively is what actually protects it.
pub fn inUse(gpa: Allocator, path: [:0]const u8) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = statPath(path.ptr) orelse return false;
    if (st.kind != s_ifblk) return false;
    const target = storageOfNumber(a, "/sys", st.device) catch return true;

    const used = usedDevices(a, readSmall(a, "/proc/self/mountinfo") orelse "", readSmall(a, "/proc/swaps") orelse "") catch return true;
    for (used) |u| {
        const dev = switch (u) {
            .number => |n| n,
            .path => |p| deviceBehind(p.ptr) orelse continue,
        };
        if (shares(target, storageOfNumber(a, "/sys", dev) catch return true)) return true;
    }
    // Held, whether or not anything is mounted: this device and its partitions.
    const node = canonical(a, std.fmt.allocPrint(a, "/sys/dev/block/{d}:{d}", .{ st.device.major, st.device.minor }) catch return true) orelse return false;
    if (held(a, node)) return true;
    for (namesIn(a, node)) |name| {
        const part = std.fmt.allocPrint(a, "{s}/{s}", .{ node, name }) catch return true;
        if (exists(a, std.fmt.allocPrint(a, "{s}/partition", .{part}) catch return true) and held(a, part)) return true;
    }
    return false;
}

/// Whether the filesystem on device `on` is stored within `device`.
fn onDevice(on: DevNo, device: DevNo) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = storageOfNumber(a, "/sys", on) catch return true;
    const y = storageOfNumber(a, "/sys", device) catch return true;
    return shares(x, y);
}

fn held(a: Allocator, node: []const u8) bool {
    return namesIn(a, std.fmt.allocPrint(a, "{s}/holders", .{node}) catch return true).len > 0;
}

// -- raw access ---------------------------------------------------------------------------

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn pread(fd: c_int, buf: [*]u8, count: usize, offset: i64) isize;
extern fn pwrite(fd: c_int, buf: [*]const u8, count: usize, offset: i64) isize;
extern fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern fn fsync(fd: c_int) c_int;
extern fn ftruncate(fd: c_int, length: i64) c_int;

const O_RDONLY: c_int = 0;
const O_RDWR: c_int = 2;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_EXCL: c_int = 0o200;
const O_CLOEXEC: c_int = 0o2000000;

pub const Handle = struct {
    fd: c_int,
    writable: bool,
    size: u64,

    pub const OpenError = error{ AccessDenied, NotFound, Busy, Failed };

    /// Opens a device for writing over all of it. The kernel refuses one it is
    /// using itself (mounted, swap, encryption, LVM, RAID, or any partition of
    /// it), and keeps others from claiming it while it is open.
    pub fn openTarget(path: [:0]const u8) OpenError!Handle {
        const st = statPath(path.ptr) orelse return error.NotFound;
        return openFlags(path, true, if (st.kind == s_ifblk) O_EXCL else 0);
    }

    pub fn openPath(path: [:0]const u8, writable: bool) OpenError!Handle {
        return openFlags(path, writable, 0);
    }

    fn openFlags(path: [:0]const u8, writable: bool, extra: c_int) OpenError!Handle {
        const fd = open(path.ptr, (if (writable) O_RDWR else O_RDONLY) | O_CLOEXEC | extra);
        if (fd < 0) {
            return switch (std.c._errno().*) {
                13, 1 => error.AccessDenied, // EACCES, EPERM
                16 => error.Busy, // EBUSY
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

    /// Opens `/proc/PID/mem` read-only. It cannot be sized with `lseek`, so the
    /// caller gives the size (the length of the region to show).
    pub fn openMem(path: [:0]const u8, size: u64) OpenError!Handle {
        const fd = open(path.ptr, O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            return switch (std.c._errno().*) {
                13, 1 => error.AccessDenied,
                2, 3 => error.NotFound, // ENOENT, ESRCH
                else => error.Failed,
            };
        }
        return .{ .fd = fd, .writable = false, .size = size };
    }

    pub const CreateError = error{ AccessDenied, SameFile, NotAFile, Failed };

    /// Creates (or empties) a regular file to write an image into. Refuses the
    /// file `source` is reading and anything that is not a regular file, such
    /// as a device, so imaging can never write over a disk.
    pub fn createFile(path: [:0]const u8, source: Handle) CreateError!Handle {
        // No truncation yet: the file might be the source.
        const fd = open(path.ptr, O_WRONLY | O_CREAT | O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return if (std.c._errno().* == 13 or std.c._errno().* == 1) error.AccessDenied else error.Failed;
        // By identity, not by name: a hard link or a second mount is the same file.
        const out = statFd(fd);
        const in = statFd(source.fd);
        if (out == null or in == null) {
            _ = close(fd);
            return error.Failed;
        }
        if (out.?.kind != s_ifreg) {
            _ = close(fd);
            return error.NotAFile;
        }
        if (std.meta.eql(out.?.on, in.?.on) and out.?.ino == in.?.ino) {
            _ = close(fd);
            return error.SameFile;
        }
        // A file on the very disk being copied would be copied into itself.
        if (in.?.kind == s_ifblk and onDevice(out.?.on, in.?.device)) {
            _ = close(fd);
            return error.SameFile;
        }
        if (ftruncate(fd, 0) != 0) {
            _ = close(fd);
            return error.Failed;
        }
        return .{ .fd = fd, .writable = true, .size = 0 };
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

// ---- process memory ----------------------------------------------------------------------

pub const Process = struct {
    pid: u32,
    name: []u8,
};

pub fn freeProcesses(a: Allocator, list_: []Process) void {
    for (list_) |p| a.free(p.name);
    a.free(list_);
}

/// Running processes, by pid, from `/proc`.
pub fn listProcesses(a: Allocator) Allocator.Error![]Process {
    var out: std.ArrayList(Process) = .empty;
    errdefer freeProcesses(a, out.items);
    var err: ?*glib.Error = null;
    const dir = glib.Dir.open("/proc", 0, &err) orelse {
        if (err) |e| e.free();
        return out.toOwnedSlice(a);
    };
    defer dir.close();
    while (@as(?[*:0]const u8, @ptrCast(dir.readName()))) |n| {
        const pid = std.fmt.parseInt(u32, std.mem.span(n), 10) catch continue;
        const name = readSmallF(a, "/proc/{d}/comm", .{pid}) orelse continue;
        out.append(a, .{ .pid = pid, .name = name }) catch |e| {
            a.free(name);
            return e;
        };
    }
    std.mem.sort(Process, out.items, {}, struct {
        fn less(_: void, x: Process, y: Process) bool {
            return x.pid < y.pid;
        }
    }.less);
    return out.toOwnedSlice(a);
}

pub const Region = struct {
    start: u64,
    end: u64,
    /// `rwxp`.
    perms: [4]u8,
    /// The mapped file, `[heap]`, `[stack]` or empty.
    name: []u8,
};

pub fn freeRegions(a: Allocator, regions: []Region) void {
    for (regions) |r| a.free(r.name);
    a.free(regions);
}

/// The readable regions in the text of `/proc/PID/maps`. Regions above the
/// signed 64-bit range (the vsyscall page) cannot be read with `pread` and are left out.
pub fn parseMaps(a: Allocator, text: []const u8) Allocator.Error![]Region {
    var out: std.ArrayList(Region) = .empty;
    errdefer freeRegions(a, out.items);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const range = parts.next() orelse continue;
        const perms = parts.next() orelse continue;
        if (perms.len != 4 or perms[0] != 'r') continue;
        _ = parts.next(); // offset
        _ = parts.next(); // device
        _ = parts.next(); // inode
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start = std.fmt.parseInt(u64, range[0..dash], 16) catch continue;
        const end = std.fmt.parseInt(u64, range[dash + 1 ..], 16) catch continue;
        if (end <= start or end > std.math.maxInt(i64)) continue;
        const rest = std.mem.trim(u8, parts.rest(), " ");
        try out.append(a, .{ .start = start, .end = end, .perms = perms[0..4].*, .name = try a.dupe(u8, rest) });
    }
    return out.toOwnedSlice(a);
}

/// The readable regions of process `pid`.
pub fn regionsOf(a: Allocator, pid: u32) Allocator.Error![]Region {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "/proc/{d}/maps", .{pid}, 0) catch return a.alloc(Region, 0);
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    if (glib.fileGetContents(path, &contents, &length, null) == 0) return a.alloc(Region, 0);
    defer glib.free(contents);
    return parseMaps(a, contents[0..length]);
}

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

test "readable regions are read from a maps file" {
    const a = std.testing.allocator;
    const text =
        "55d0c8a00000-55d0c8a21000 r--p 00000000 08:01 1234 /usr/bin/cat\n" ++
        "55d0c8a21000-55d0c8a26000 rw-p 00000000 00:00 0 [heap]\n" ++
        "7ffd1c3a0000-7ffd1c3c1000 ---p 00000000 00:00 0\n" ++
        "ffffffffff600000-ffffffffff601000 --xp 00000000 00:00 0 [vsyscall]\n";
    const regions = try parseMaps(a, text);
    defer freeRegions(a, regions);
    try std.testing.expectEqual(@as(usize, 2), regions.len);
    try std.testing.expectEqual(@as(u64, 0x55d0c8a00000), regions[0].start);
    try std.testing.expectEqualStrings("[heap]", regions[1].name);
}

test "this process's own memory can be read" {
    const a = std.testing.allocator;
    const regions = try regionsOf(a, @intCast(std.c.getpid()));
    defer freeRegions(a, regions);
    try std.testing.expect(regions.len > 0);
}

test "bytes of this process can be read through /proc/PID/mem" {
    const marker: [8]u8 = .{ 'D', 'K', 'D', 'E', 'm', 'a', 'r', 'k' };
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/mem", .{std.c.getpid()}, 0);
    const mem = try Handle.openMem(path, 8);
    defer @constCast(&mem).closeHandle();
    var got: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try mem.readAt(@intFromPtr(&marker), &got));
    try std.testing.expectEqualSlices(u8, &marker, &got);
}

/// What to tell someone about to write to a disk holding a filesystem that
/// checksums its own metadata: the checksum is not recomputed by this editor,
/// so the filesystem will call the change damage until its own tool is run.
/// Null for other contents (FAT, NTFS, unknown, ...).
pub fn checksumAdvice(h: *const Handle, origin: u64) ?[]const u8 {
    var buf: [0x10048]u8 = undefined;
    const got = h.readAt(origin, &buf) catch return null;
    return checksumAdviceOf(buf[0..got]);
}

pub fn checksumAdviceOf(b: []const u8) ?[]const u8 {
    if (b.len >= 0x438 and b[0x438] == 0x53 and b[0x439] == 0xEF) {
        return "This is an ext2/3/4 filesystem. With metadata checksums on, an edited superblock or group descriptor fails its checksum; use tune2fs, e2label or debugfs -w to change it (they update the checksums), or repair afterwards with e2fsck -f.";
    }
    if (b.len >= 4 and std.mem.eql(u8, b[0..4], "XFSB")) {
        return "This is an XFS filesystem, which checksums its metadata. Use xfs_admin to change it; after a raw edit run xfs_repair.";
    }
    if (b.len >= 0x10048 and std.mem.eql(u8, b[0x10040..0x10048], "_BHRfS_M")) {
        return "This is a btrfs filesystem, which checksums its metadata. Use btrfs property or btrfstune; a raw edit will fail the checksum and btrfs check may not repair it.";
    }
    if (b.len >= 11 and std.mem.eql(u8, b[3..11], "EXFAT   ")) {
        return "This is an exFAT filesystem, which checksums its boot area. After a raw edit the checksum sector must be rewritten; fsck.exfat reports and can repair it.";
    }
    if (b.len >= 0x404 and b[0x400] == 0x10 and b[0x401] == 0x20 and b[0x402] == 0xF5 and b[0x403] == 0xF2) {
        return "This is an F2FS filesystem, which checksums its superblock. After a raw edit run fsck.f2fs.";
    }
    return null;
}

test "filesystems that checksum are recognised" {
    var b = std.mem.zeroes([0x10048]u8);
    try std.testing.expect(checksumAdviceOf(&b) == null);
    b[0x438] = 0x53;
    b[0x439] = 0xEF;
    try std.testing.expect(checksumAdviceOf(&b) != null);
    @memset(&b, 0);
    @memcpy(b[0..4], "XFSB");
    try std.testing.expect(checksumAdviceOf(&b) != null);
    @memset(&b, 0);
    @memcpy(b[3..11], "EXFAT   ");
    try std.testing.expect(checksumAdviceOf(&b) != null);
}

extern fn symlink(target: [*:0]const u8, path: [*:0]const u8) c_int;

test "storage built on a partition overlaps it and its disk, and nothing else" {
    const tmp = glib.Dir.makeTmp("dkde-sys-XXXXXX", null) orelse return error.NoTmp;
    defer glib.free(tmp);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = canonical(a, std.mem.span(tmp)).?;
    // A disk with two partitions, and an encrypted volume on the second.
    for ([_][]const u8{ "devices/sda/sda1", "devices/sda/sda2", "devices/dm-0/slaves", "dev/block" }) |d| {
        const z = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, d }, 0);
        _ = glib.mkdirWithParents(z.ptr, 0o755);
    }
    for ([_][]const u8{ "devices/sda/sda1/partition", "devices/sda/sda2/partition" }) |f| {
        const z = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, f }, 0);
        _ = glib.fileSetContents(z.ptr, "1", 1, null);
    }
    for ([_][2][]const u8{
        .{ "devices/sda", "dev/block/8:0" },
        .{ "devices/sda/sda1", "dev/block/8:1" },
        .{ "devices/sda/sda2", "dev/block/8:2" },
        .{ "devices/dm-0", "dev/block/253:0" },
        .{ "devices/sda/sda2", "devices/dm-0/slaves/sda2" },
    }) |l| {
        const to = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, l[0] }, 0);
        const at = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, l[1] }, 0);
        try std.testing.expectEqual(@as(c_int, 0), symlink(to.ptr, at.ptr));
    }
    const disk = try storageOfNumber(a, root, .{ .major = 8, .minor = 0 });
    const first = try storageOfNumber(a, root, .{ .major = 8, .minor = 1 });
    const second = try storageOfNumber(a, root, .{ .major = 8, .minor = 2 });
    const crypt = try storageOfNumber(a, root, .{ .major = 253, .minor = 0 });
    try std.testing.expectEqual(@as(usize, 1), crypt.len);
    try std.testing.expect(shares(crypt, second));
    try std.testing.expect(shares(crypt, disk));
    try std.testing.expect(!shares(crypt, first));
    try std.testing.expect(!shares(first, second));
    try std.testing.expect(shares(first, disk));
}

test "mounts and swap name the devices they use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const used = try usedDevices(arena.allocator(),
        \\36 25 253:0 / / rw,relatime shared:1 - ext4 /dev/mapper/root rw
        \\50 36 0:44 / /data rw - btrfs /dev/sdc1 rw
        \\51 36 0:5 / /proc rw - proc proc rw
    ,
        \\Filename Type Size Used Priority
        \\/dev/sda3 partition 8388604 0 -2
    );
    try std.testing.expectEqual(@as(usize, 4), used.len);
    try std.testing.expectEqual(@as(u32, 253), used[0].number.major);
    try std.testing.expectEqualStrings("/dev/mapper/root", used[1].path);
    try std.testing.expectEqualStrings("/dev/sdc1", used[2].path);
    try std.testing.expectEqualStrings("/dev/sda3", used[3].path);
}
